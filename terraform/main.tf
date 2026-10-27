terraform {
  required_version = ">= 1.4"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.53"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
}

############################
# APP DEFAULTS
############################

locals {
  app_name = "kubernetes-app"

  # Student image from the Packer build (must match packer/variables.pkr.hcl).
  lab_image = "kubernetes-app/student:1"

  # NodePort range for the student pods (must match FIRST_PORT/LAST_PORT in labctl).
  first_node_port = 30001
  last_node_port  = 32767

  # DHBW campus and VPN. Only these networks reach SSH, the NodePorts and the
  # Kubernetes API (security_group.tf). Student pods can never reach them, so
  # they cannot attack other VMs or the NodePorts of other teams.
  campus_cidr_v4 = "141.72.0.0/16"
  campus_cidr_v6 = "2001:7c0::/32"

  # Kept free for the OS, k3s and the system pods. Half goes to
  # kube-reserved, half to system-reserved (k3s config in user-data.yaml.tpl),
  # so the kubelet never hands it out to student pods.
  reserved = {
    cpu       = 0.5
    memory_mb = 1536
    disk_gb   = 10
  }

  # The fixed IPs of DHBWv4/DHBWV6 are publicly routed, no floating IP needed.
}

# Load the Packer image from Glance
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# vCPU, RAM and disk of the chosen flavor, for the capacity check below.
data "openstack_compute_flavor_v2" "vm" {
  name = var.flavor_name
}

############################
# USER MANAGEMENT (CONTRACT)
############################

locals {
  # E-mail -> Linux user name. The name is also part of Kubernetes object
  # names and must therefore be a DNS label: lowercase letters, digits and
  # "-", starts with a letter, does not end with "-", max. 30 characters.
  raw_users = flatten([
    for team, members in var.users : [
      for member in members : {
        team  = team
        email = member.email
        slug  = trim(lower(replace(split("@", member.email)[0], "/[^a-zA-Z0-9]+/", "-")), "-")
      }
    ]
  ])

  all_users = [
    for user in local.raw_users : {
      team     = user.team
      email    = user.email
      username = trim(substr(can(regex("^[a-z]", user.slug)) ? user.slug : "s${user.slug}", 0, 30), "-")
    }
  ]

  # Two e-mail addresses with the same user name in the same team
  # intentionally fail with a "Duplicate object key" error.
  users_map  = { for user in local.all_users : "${user.team}-${user.username}" => user }
  teams_list = distinct([for user in local.all_users : user.team])

  team_user_ids = {
    for team in local.teams_list : team => sort([
      for uid, user in local.users_map : uid if user.team == team
    ])
  }
}

# Remembers the order in which the students of a team were first seen. The
# input is never rewritten, so existing students keep their NodePort when the
# roster changes; new students are appended, removed ones leave a gap.
resource "terraform_data" "port_registry" {
  for_each = toset(local.teams_list)

  input = local.team_user_ids[each.key]

  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  port_order = {
    for team in local.teams_list : team => concat(
      terraform_data.port_registry[team].output,
      sort([
        for uid in local.team_user_ids[team] : uid
        if !contains(terraform_data.port_registry[team].output, uid)
      ])
    )
  }

  user_ports = {
    for uid, user in local.users_map : uid => local.first_node_port + index(local.port_order[user.team], uid)
  }
}

# One password per student. Letters and digits only, so it can be used in the
# shell, in YAML and in the terminal without quoting.
resource "random_password" "user_passwords" {
  for_each    = local.users_map
  length      = 16
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

############################
# CLUSTER ACCESS (per team)
############################

# Own CA for the API server certificate. Terraform knows the CA at apply time
# and can build a complete kubeconfig without fetching a file from the VM.
resource "tls_private_key" "ca" {
  for_each    = toset(local.teams_list)
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  for_each = toset(local.teams_list)

  private_key_pem       = tls_private_key.ca[each.key].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature", "key_encipherment"]

  subject {
    common_name = "${local.app_name}-${each.key}-server-ca"
  }
}

# Admin token (group system:masters = cluster-admin) for the teacher kubeconfig.
resource "random_password" "admin_token" {
  for_each = toset(local.teams_list)
  length   = 40
  special  = false
}

############################
# TEAM-BASED VMs
############################

# One port per team (with the shared and the app security group)
resource "openstack_networking_port_v2" "team_port" {
  for_each           = toset(local.teams_list)
  network_id         = var.network_uuid
  security_group_ids = [var.shared_secgroup_id, openstack_networking_secgroup_v2.lab.id]
}

# DHBWV6 is dual-stack: ``all_fixed_ips`` holds both the v4 and the v6
# address per team, order not guaranteed. We split them with a colon check
# (IPv6 literals always contain ":", IPv4 never does).
locals {
  fixed_ip_v4 = {
    for team in local.teams_list : team => try([
      for fa in openstack_networking_port_v2.team_port[team].all_fixed_ips :
      fa if !can(regex(":", fa))
    ][0], null)
  }
  fixed_ip_v6 = {
    for team in local.teams_list : team => try([
      for fa in openstack_networking_port_v2.team_port[team].all_fixed_ips :
      fa if can(regex(":", fa))
    ][0], null)
  }

  # Main address for students and teacher: IPv6 if available.
  primary_ip = {
    for team in local.teams_list : team => local.fixed_ip_v6[team] != null ? local.fixed_ip_v6[team] : local.fixed_ip_v4[team]
  }
  api_endpoint = {
    for team in local.teams_list : team => "https://${local.fixed_ip_v6[team] != null ? "[${local.fixed_ip_v6[team]}]" : local.fixed_ip_v4[team]}:6443"
  }
}

# Capacity of one VM for student pods (flavor minus the reserved share).
module "capacity" {
  source = "./modules/capacity"

  flavor_vcpus   = data.openstack_compute_flavor_v2.vm.vcpus
  flavor_ram_mb  = data.openstack_compute_flavor_v2.vm.ram
  flavor_disk_gb = data.openstack_compute_flavor_v2.vm.disk
  root_disk_gb   = var.root_disk_gb
  reserved       = local.reserved
  pod = {
    cpu       = var.pod_cpu
    memory_mb = var.pod_memory_mb
    disk_gb   = var.pod_disk_gb
  }
}

# One VM per team with a k3s cluster
resource "openstack_compute_instance_v2" "team_vm" {
  for_each = toset(local.teams_list)

  name        = "${local.app_name}-${each.key}"
  image_id    = var.root_disk_gb > 0 ? null : data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name
  key_pair    = var.key_pair_name != "" ? var.key_pair_name : null

  # Optional: larger root disk as a volume. The home directories live there
  # (local-path under /var/lib/rancher/k3s/storage).
  dynamic "block_device" {
    for_each = var.root_disk_gb > 0 ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.root_disk_gb
      boot_index            = 0
      delete_on_termination = true
    }
  }

  timeouts {
    create = "15m"
    delete = "15m"
  }

  network {
    port = openstack_networking_port_v2.team_port[each.key].id
  }

  user_data = templatefile("${path.module}/user-data.yaml.tpl", {
    team            = each.key
    node_ipv4       = local.fixed_ip_v4[each.key]
    node_ipv6       = local.fixed_ip_v6[each.key] != null ? local.fixed_ip_v6[each.key] : ""
    admin_token     = random_password.admin_token[each.key].result
    ca_cert_pem     = tls_self_signed_cert.ca[each.key].cert_pem
    ca_key_pem      = tls_private_key.ca[each.key].private_key_pem
    lab_image       = local.lab_image
    pod_cpu         = var.pod_cpu
    pod_memory_mb   = var.pod_memory_mb
    pod_disk_gb     = var.pod_disk_gb
    pod_to_pod      = var.allow_pod_communication
    pod_internet    = var.allow_internet
    campus_cidr_v4  = local.campus_cidr_v4
    campus_cidr_v6  = local.campus_cidr_v6
    reserved_cpu_m  = local.reserved.cpu * 1000 / 2
    reserved_mem_mi = local.reserved.memory_mb / 2
    students = [
      for uid in local.team_user_ids[each.key] : {
        username = local.users_map[uid].username
        password = random_password.user_passwords[uid].result
        port     = local.user_ports[uid]
      }
    ]
  })

  metadata = {
    team = each.key
    app  = local.app_name
  }

  lifecycle {
    # New students are added later with `labctl add-student`. A changed
    # roster must not replace the VM (and with it all home directories).
    ignore_changes = [user_data]

    precondition {
      condition     = length(local.team_user_ids[each.key]) <= module.capacity.max_students
      error_message = "Team ${each.key}: ${length(local.team_user_ids[each.key])} students do not fit on flavor ${var.flavor_name} (${coalesce(tostring(data.openstack_compute_flavor_v2.vm.vcpus), "?")} vCPU, ${coalesce(tostring(data.openstack_compute_flavor_v2.vm.ram), "?")} MB RAM, ${module.capacity.disk_gb} GB disk; ${local.reserved.cpu} vCPU, ${local.reserved.memory_mb} MB and ${local.reserved.disk_gb} GB are reserved for the system). With ${var.pod_cpu} vCPU, ${var.pod_memory_mb} MB RAM and ${var.pod_disk_gb} GB disk per pod at most ${module.capacity.max_students} students fit. Choose a larger flavor/disk or smaller pods."
    }

    precondition {
      condition     = length(local.port_order[each.key]) <= local.last_node_port - local.first_node_port + 1
      error_message = "Team ${each.key}: no free NodePort left between ${local.first_node_port} and ${local.last_node_port}."
    }
  }
}

############################
# KUBECONFIG (teacher, cluster-admin)
############################

locals {
  kubeconfigs = {
    for team in local.teams_list : team => yamlencode({
      apiVersion        = "v1"
      kind              = "Config"
      "current-context" = "${local.app_name}-${team}"
      clusters = [{
        name = "${local.app_name}-${team}"
        cluster = {
          server                       = local.api_endpoint[team]
          "certificate-authority-data" = base64encode(tls_self_signed_cert.ca[team].cert_pem)
        }
      }]
      users = [{
        name = "lab-admin"
        user = {
          token = random_password.admin_token[team].result
        }
      }]
      contexts = [{
        name = "${local.app_name}-${team}"
        context = {
          cluster = "${local.app_name}-${team}"
          user    = "lab-admin"
        }
      }]
    })
  }
}

############################
# OUTPUT CONTRACT
############################

locals {
  user_accounts = {
    for uid, user in local.users_map : uid => {
      type        = "password"
      ip          = local.fixed_ip_v4[user.team]
      ip_v6       = local.fixed_ip_v6[user.team]
      port        = local.user_ports[uid]
      username    = user.username
      auth        = random_password.user_passwords[uid].result
      ssh_command = "ssh -p ${local.user_ports[uid]} ${user.username}@${local.primary_ip[user.team]}"
    }
  }
}
