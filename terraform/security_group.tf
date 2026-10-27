# Security group for SSH, the Kubernetes API and the student pods.
#
# The platform's shared group (``shared_secgroup_id``) only opens 22, 80 and
# 443. The NodePorts of the student pods (30000-32767) and the API (6443)
# belong to this app and therefore live in their own group.
#
# Security group rules apply per ethertype. Every rule therefore needs an
# IPv4 and an IPv6 variant, otherwise the VM would be unreachable over IPv6.

locals {
  sg_ports = {
    ssh  = { min = 22, max = 22, description = "SSH to the VM" }
    api  = { min = 6443, max = 6443, description = "Kubernetes API" }
    pods = { min = 30000, max = 32767, description = "SSH of the student pods (NodePort)" }
  }

  sg_families = {
    v4 = { ethertype = "IPv4", cidr = local.campus_cidr_v4 }
    v6 = { ethertype = "IPv6", cidr = local.campus_cidr_v6 }
  }

  sg_rules = merge([
    for family_key, family in local.sg_families : {
      for port_key, port in local.sg_ports : "${port_key}-${family_key}" => {
        ethertype   = family.ethertype
        cidr        = family.cidr
        min         = port.min
        max         = port.max
        description = "${port.description} (${family.ethertype})"
      }
    }
  ]...)
}

resource "random_id" "secgroup" {
  byte_length = 4
}

resource "openstack_networking_secgroup_v2" "lab" {
  # Neutron does not require unique names. The suffix keeps several
  # deployments of this app apart in the dashboard.
  name        = "${local.app_name}-${random_id.secgroup.hex}"
  description = "SSH, Kubernetes API and student pods"
}

# The source networks are the campus/VPN constants from main.tf
# (local.campus_cidr_v4/v6), never 0.0.0.0/0 or ::/0. tfsec cannot resolve
# them and would report "public ingress".
#tfsec:ignore:openstack-networking-no-public-ingress
resource "openstack_networking_secgroup_rule_v2" "lab" {
  for_each = local.sg_rules

  security_group_id = openstack_networking_secgroup_v2.lab.id
  direction         = "ingress"
  ethertype         = each.value.ethertype
  protocol          = "tcp"
  port_range_min    = each.value.min
  port_range_max    = each.value.max
  remote_ip_prefix  = each.value.cidr
  description       = each.value.description
}
