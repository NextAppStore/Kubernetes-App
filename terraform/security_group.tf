# Security group fuer SSH, Kubernetes-API und die Student-Pods.
#
# Die gemeinsame Gruppe der Plattform (``shared_secgroup_id``) oeffnet nur 22,
# 80 und 443. Die NodePorts der Student-Pods (30000-32767) und die API (6443)
# gehoeren zu dieser App und stehen deshalb in einer eigenen Gruppe.
#
# Security-Group-Regeln gelten je Ethertype. Jede Freigabe braucht deshalb eine
# IPv4- und eine IPv6-Regel, sonst waere die VM ueber IPv6 unerreichbar.

locals {
  sg_ports = {
    ssh  = { min = 22, max = 22, description = "SSH auf der VM" }
    api  = { min = 6443, max = 6443, description = "Kubernetes-API" }
    pods = { min = 30000, max = 32767, description = "SSH der Student-Pods (NodePort)" }
  }

  sg_families = {
    v4 = { ethertype = "IPv4", cidr = var.allowed_cidr_v4 }
    v6 = { ethertype = "IPv6", cidr = var.allowed_cidr_v6 }
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
  # Neutron verlangt keine eindeutigen Namen. Das Suffix haelt mehrere
  # Deployments dieser App im Dashboard auseinander.
  name        = "${local.app_name}-${random_id.secgroup.hex}"
  description = "SSH, Kubernetes-API und Student-Pods"
}

# tfsec kann die Quell-Netze aus den Variablen nicht aufloesen und meldet
# deshalb "public ingress". Die Netze sind auf das Campus-/VPN-Netz beschraenkt
# und die Variablen verbieten 0.0.0.0/0 und ::/0 (siehe variables.tf).
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
