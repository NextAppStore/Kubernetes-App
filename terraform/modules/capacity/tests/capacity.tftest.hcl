#   terraform -chdir=terraform/modules/capacity test

variables {
  reserved = { cpu = 0.5, memory_mb = 1536, disk_gb = 10 }
  pod      = { cpu = 0.5, memory_mb = 1024, disk_gb = 5 }
}

run "limited_by_cpu" {
  command = plan

  variables {
    flavor_vcpus   = 4
    flavor_ram_mb  = 16384
    flavor_disk_gb = 100
    root_disk_gb   = 0
  }

  assert {
    condition     = output.max_students == 7
    error_message = "4 vCPU - 0.5 reserved = 3.5 / 0.5 = 7, got ${output.max_students}"
  }
}

run "limited_by_memory" {
  command = plan

  variables {
    flavor_vcpus   = 8
    flavor_ram_mb  = 4096
    flavor_disk_gb = 100
    root_disk_gb   = 0
  }

  assert {
    condition     = output.max_students == 2
    error_message = "(4096 - 1536) / 1024 = 2, got ${output.max_students}"
  }
}

run "root_disk_overrides_flavor_disk" {
  command = plan

  variables {
    flavor_vcpus   = 8
    flavor_ram_mb  = 16384
    flavor_disk_gb = 20
    root_disk_gb   = 30
  }

  assert {
    condition     = output.disk_gb == 30 && output.max_students == 4
    error_message = "(30 - 10) / 5 = 4, got ${output.max_students} (disk ${output.disk_gb})"
  }
}

run "flavor_without_disk" {
  command = plan

  variables {
    flavor_vcpus   = 8
    flavor_ram_mb  = 16384
    flavor_disk_gb = 0
    root_disk_gb   = 0
  }

  assert {
    condition     = output.max_students == 0
    error_message = "A flavor without disk and no root volume fits no pods, got ${output.max_students}"
  }
}
