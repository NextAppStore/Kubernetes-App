############################
# User Accounts Output
############################

# Schema user_accounts:
# "<team>-<username>": {
#   type        = "password"
#   ip          = "141.72.x.y"        # IPv4
#   ip_v6       = "2001:7c0:..."      # IPv6 (Hauptadresse)
#   port        = 30001               # NodePort des Student-Pods
#   username    = "anna"
#   auth        = "<passwort>"
#   ssh_command = "ssh -p 30001 anna@2001:7c0:..."
# }

output "user_accounts" {
  description = "User accounts mit Zugangsdaten fuer jeden Studenten"
  value       = local.user_accounts
  sensitive   = true
}

############################
# Team-VM Details
############################

output "team_vms" {
  description = "Details aller Team-VMs (je Team ein k3s-Cluster)"
  value = {
    for team in local.teams_list : team => {
      instance_id   = openstack_compute_instance_v2.team_vm[team].id
      instance_name = openstack_compute_instance_v2.team_vm[team].name
      fixed_ip      = local.fixed_ip_v4[team]
      fixed_ip_v6   = local.fixed_ip_v6[team]
      floating_ip   = null
      # Die API-Adresse dient als Link; die SSH-Befehle stehen je Student in
      # user_accounts.
      url          = local.api_endpoint[team]
      api_endpoint = local.api_endpoint[team]
      ssh_command  = var.key_pair_name != "" ? "ssh ubuntu@${local.primary_ip[team]}" : null
    }
  }
}

output "teams_summary" {
  description = "Uebersicht: Teams und Anzahl Studenten"
  value = {
    for team in local.teams_list : team => length(local.team_user_ids[team])
  }
}

############################
# Kubeconfig fuer Dozenten
############################

# Admin-Zugang (cluster-admin) je Team. Speichern mit:
#   terraform output -json kubeconfigs | jq -r '.["<team>"]' > kurs.kubeconfig
output "kubeconfigs" {
  description = "Kubeconfig mit Admin-Rechten je Team (nur fuer Dozenten)"
  value       = local.kubeconfigs
  sensitive   = true
}
