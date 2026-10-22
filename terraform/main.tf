terraform {
  required_version = ">= 1.0"

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
# APP-DEFAULTS
############################

locals {
  app_name = "kubernetes-app"

  # Student-Image im Packer-Build (muss zu packer/variables.pkr.hcl passen).
  lab_image = "kubernetes-app/student:1"

  # Erster NodePort. Der n-te Student (alphabetisch) bekommt first + n - 1.
  first_node_port = 30001

  # Die Fixed-IPs von DHBWv4/DHBWV6 sind oeffentlich geroutet, eine Floating IP
  # ist nicht noetig.
}

# Packer-Image aus Glance laden
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

############################
# USER MANAGEMENT (CONTRACT)
############################

locals {
  # E-Mail -> Linux-Benutzername. Der Name wird auch Teil von Kubernetes-
  # Objektnamen und muss deshalb ein DNS-Label sein: Kleinbuchstaben, Ziffern
  # und "-", beginnt mit einem Buchstaben, endet nicht mit "-", max. 30 Zeichen.
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

  # Zwei E-Mail-Adressen mit demselben Benutzernamen im selben Team fuehren
  # absichtlich zu einem "Duplicate object key"-Fehler.
  users_map  = { for user in local.all_users : "${user.team}-${user.username}" => user }
  teams_list = distinct([for user in local.all_users : user.team])

  team_user_ids = {
    for team in local.teams_list : team => sort([
      for uid, user in local.users_map : uid if user.team == team
    ])
  }

  user_ports = {
    for uid, user in local.users_map : uid => local.first_node_port + index(local.team_user_ids[user.team], uid)
  }
}

# Ein Passwort pro Student. Nur Buchstaben und Ziffern, damit es sich in der
# Shell, in YAML und im Terminal ohne Quoting verwenden laesst.
resource "random_password" "user_passwords" {
  for_each    = local.users_map
  length      = 16
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

############################
# ZUGANG ZUM CLUSTER (je Team)
############################

# Eigene CA fuer das API-Serverzertifikat. Damit kennt Terraform die CA schon
# beim Apply und kann eine vollstaendige Kubeconfig erzeugen, ohne dass jemand
# eine Datei von der VM holen muss.
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

# Admin-Token (Gruppe system:masters = cluster-admin) fuer die Dozenten-Kubeconfig.
resource "random_password" "admin_token" {
  for_each = toset(local.teams_list)
  length   = 40
  special  = false
}

############################
# TEAM-BASED VMs
############################

# Pro Team ein Port (mit shared und eigener Security Group)
resource "openstack_networking_port_v2" "team_port" {
  for_each           = toset(local.teams_list)
  network_id         = var.network_uuid
  security_group_ids = [var.shared_secgroup_id, openstack_networking_secgroup_v2.lab.id]
}

# DHBWV6 ist dual-stack: ``all_fixed_ips`` enthaelt pro Team sowohl die
# v4- als auch die v6-Adresse, Reihenfolge nicht garantiert. Wir trennen
# per Doppelpunkt-Check (IPv6-Literale enthalten immer ":", IPv4 nie).
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

  # Hauptadresse fuer Studenten und Dozent: IPv6, falls vorhanden.
  primary_ip = {
    for team in local.teams_list : team => local.fixed_ip_v6[team] != null ? local.fixed_ip_v6[team] : local.fixed_ip_v4[team]
  }
  api_endpoint = {
    for team in local.teams_list : team => "https://${local.fixed_ip_v6[team] != null ? "[${local.fixed_ip_v6[team]}]" : local.fixed_ip_v4[team]}:6443"
  }
}

# Pro Team eine VM mit einem k3s-Cluster
resource "openstack_compute_instance_v2" "team_vm" {
  for_each = toset(local.teams_list)

  name        = "${local.app_name}-${each.key}"
  image_id    = var.root_disk_gb > 0 ? null : data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name
  key_pair    = var.key_pair_name != "" ? var.key_pair_name : null

  # Optional: groessere Root-Platte als Volume. Dort liegen die Home-
  # Verzeichnisse (local-path unter /var/lib/rancher/k3s/storage).
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
    team               = each.key
    node_ipv4          = local.fixed_ip_v4[each.key]
    node_ipv6          = local.fixed_ip_v6[each.key] != null ? local.fixed_ip_v6[each.key] : ""
    admin_token        = random_password.admin_token[each.key].result
    ca_cert_pem        = tls_self_signed_cert.ca[each.key].cert_pem
    ca_key_pem         = tls_private_key.ca[each.key].private_key_pem
    lab_image          = local.lab_image
    pod_cpu_limit      = var.pod_cpu_limit
    pod_memory_limit   = var.pod_memory_limit
    pod_memory_request = var.pod_memory_request
    pod_disk           = var.pod_disk
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

  # Neue Studenten kommen spaeter per `labctl add-student`. Eine geaenderte
  # Studentenliste darf die VM (und damit alle Home-Verzeichnisse) nicht ersetzen.
  lifecycle {
    ignore_changes = [user_data]
  }
}

############################
# KUBECONFIG (Dozent, cluster-admin)
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
