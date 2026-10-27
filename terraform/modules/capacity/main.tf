# How many student pods fit on one VM. Pure computation (no resources), kept
# in a module so it can be tested without OpenStack.

terraform {
  required_version = ">= 1.4"
}

variable "flavor_vcpus" {
  description = "vCPUs of the flavor"
  type        = number
}

variable "flavor_ram_mb" {
  description = "RAM of the flavor in MB"
  type        = number
}

variable "flavor_disk_gb" {
  description = "Disk of the flavor in GB (used when root_disk_gb is 0)"
  type        = number
}

variable "root_disk_gb" {
  description = "Boot volume size in GB, 0 = flavor disk"
  type        = number
}

variable "reserved" {
  description = "Share kept free for the OS, k3s and the system pods"
  type = object({
    cpu       = number
    memory_mb = number
    disk_gb   = number
  })
}

variable "pod" {
  description = "Resources per student pod (request = limit)"
  type = object({
    cpu       = number
    memory_mb = number
    disk_gb   = number
  })
}

locals {
  disk_gb = var.root_disk_gb > 0 ? var.root_disk_gb : var.flavor_disk_gb

  max_students = max(0, min(
    floor((var.flavor_vcpus - var.reserved.cpu) / var.pod.cpu),
    floor((var.flavor_ram_mb - var.reserved.memory_mb) / var.pod.memory_mb),
    floor((local.disk_gb - var.reserved.disk_gb) / var.pod.disk_gb),
  ))
}

output "disk_gb" {
  description = "Disk of the VM in GB"
  value       = local.disk_gb
}

output "max_students" {
  description = "Number of student pods that fit on one VM"
  value       = local.max_students
}
