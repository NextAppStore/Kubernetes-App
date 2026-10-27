############################
# User Accounts Output
############################

# Schema user_accounts:
# "<team>-<username>": {
#   type        = "password"
#   authtype    = "ssh"               # frontend shows an SSH command, not a URL
#   ip          = "141.72.x.y"        # IPv4
#   ip_v6       = "2001:7c0:..."      # IPv6 (main address)
#   port        = 30001               # NodePort of the student pod, stable
#   username    = "anna"
#   auth        = "<password>"
#   ssh_command = "ssh -p 30001 anna@2001:7c0:..."
# }

output "user_accounts" {
  description = "User accounts with credentials for every student"
  value       = local.user_accounts
  sensitive   = true
}

############################
# Team VM details
############################

output "team_vms" {
  description = "Details of all team VMs (one k3s cluster per team)"
  value = {
    for team in local.teams_list : team => {
      instance_id   = openstack_compute_instance_v2.team_vm[team].id
      instance_name = openstack_compute_instance_v2.team_vm[team].name
      fixed_ip      = local.fixed_ip_v4[team]
      fixed_ip_v6   = local.fixed_ip_v6[team]
      floating_ip   = null
      # No `url`: the frontend would show it instead of the per-student SSH
      # command from user_accounts. The API is only for the teacher, who
      # gets it via the kubeconfigs output.
      api_endpoint = local.api_endpoint[team]
      ssh_command  = var.key_pair_name != "" ? "ssh ubuntu@${local.primary_ip[team]}" : null
    }
  }
}

output "teams_summary" {
  description = "Overview: teams and number of students"
  value = {
    for team in local.teams_list : team => length(local.team_user_ids[team])
  }
}

############################
# Readiness (evaluated by the worker after apply)
############################

# The first-boot script writes "APPSTORE-READY" or "APPSTORE-FAILED: <reason>"
# to the serial console once all student pods run (or fail). The worker polls
# the console log of every instance and fails the deploy on FAILED/timeout.
# The timeout covers the boot, the IPv6 wait (up to 4 min), the k3s start
# (up to 8 min) and the pods (7 min, PODS_TIMEOUT in the first-boot script),
# with some margin so the VM reports its own reason first.
output "readiness_checks" {
  description = "Instances the worker waits for after apply (APPSTORE-READY marker on the serial console)"
  value = [
    for team in local.teams_list : {
      instance_id     = openstack_compute_instance_v2.team_vm[team].id
      name            = team
      timeout_seconds = 1500
    }
  ]
}

############################
# Kubeconfig for teachers
############################

# Admin access (cluster-admin) per team. Save with:
#   terraform output -json kubeconfigs | jq -r '.["<team>"]' > kurs.kubeconfig
output "kubeconfigs" {
  description = "Kubeconfig with admin rights per team (teachers only)"
  value       = local.kubeconfigs
  sensitive   = true
}
