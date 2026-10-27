############################
# Platform-injected variables (not shown in the wizard)
############################

variable "users" {
  description = "Per-team roster, injected by the worker. @platform:internal"
  type = map(list(object({
    email = string
  })))
  default = {}
}

variable "image_name" {
  description = "Glance image name, set by the worker at apply time. @platform:internal"
  type        = string
  default     = "kubernetes-app-vX"
}

############################
# Wizard variables (configured by the deployer in the AppStore)
############################

variable "network_uuid" {
  description = "UUID of the internal network @openstack:network:id"
  type        = string
  # DHBWV6: dual-stack (v4+v6 on the same subnet pair), every VM gets both
  # fixed IPs from Neutron automatically.
  default = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "shared_secgroup_id" {
  description = "ID of the shared security group @openstack:security_group:id"
  type        = string
  default     = "5c0e96fb-bd1f-41b3-b400-deccf7712a80"
}

variable "key_pair_name" {
  description = "Optional key pair for SSH admin access to the VM (user ubuntu). Empty = no admin access. @openstack:keypair:name"
  type        = string
  default     = ""
}

############################
# Resources of the whole VM
############################

variable "flavor_name" {
  description = "Size of the VM (vCPU and RAM for all student pods together). The deploy is rejected if the students do not fit. @openstack:flavor:name"
  type        = string
  default     = "gp1.large"
}

variable "root_disk_gb" {
  description = "Disk of the VM in GB (boot from volume). 0 = disk of the flavor, usually too small (gp1.large: 10 GB). The home directories of all students live here."
  type        = number
  # 40 GB on gp1.large: 10 GB system + 6 homes of 5 GB, matching the 6 pods
  # that fit into its RAM with the pod defaults.
  default = 40

  validation {
    condition     = var.root_disk_gb >= 0 && floor(var.root_disk_gb) == var.root_disk_gb
    error_message = "root_disk_gb must be a whole number >= 0."
  }
}

############################
# Resources per student pod (request = limit, guaranteed)
############################

variable "pod_cpu" {
  description = "vCPUs per student pod, e.g. 0.5 or 1. Reserved for the pod, so the VM must have enough for all students."
  type        = number
  default     = 0.5

  validation {
    condition     = var.pod_cpu >= 0.1
    error_message = "pod_cpu must be at least 0.1."
  }
}

variable "pod_memory_mb" {
  description = "RAM per student pod in MB. Reserved for the pod, so the VM must have enough for all students."
  type        = number
  default     = 1024

  validation {
    condition     = var.pod_memory_mb >= 256 && floor(var.pod_memory_mb) == var.pod_memory_mb
    error_message = "pod_memory_mb must be a whole number >= 256."
  }
}

variable "pod_disk_gb" {
  description = "Size of the home directory per student in GB. Counted against the VM disk; local-path does not enforce it inside the pod."
  type        = number
  default     = 5

  validation {
    condition     = var.pod_disk_gb >= 1 && floor(var.pod_disk_gb) == var.pod_disk_gb
    error_message = "pod_disk_gb must be a whole number >= 1."
  }
}

############################
# Network of the student pods
############################

variable "allow_pod_communication" {
  description = "Student pods of a team reach each other on all ports (e.g. for pentesting). Can be switched later with `labctl network peers on|off`."
  type        = bool
  default     = false
}

variable "allow_internet" {
  description = "Student pods reach the internet (apt, pip, git). The campus/OpenStack network, the VM, the Kubernetes API and the metadata service stay blocked in any case. Can be switched later with `labctl network internet on|off`."
  type        = bool
  default     = true
}
