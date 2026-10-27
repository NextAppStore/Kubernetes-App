# Offline tests with a mocked OpenStack provider:
#   terraform -chdir=terraform test
# Runs share one state, so later runs see the port registry of earlier ones.

mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "00000000-0000-0000-0000-000000000001"
    }
  }

  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["141.72.1.2", "2001:7c0:1b20:c913:1::2e3"]
    }
  }
}

# vcpus/ram/disk are optional (not computed) attributes of the flavor data
# source, so a mock cannot fill them. The capacity math is tested on its own
# in modules/capacity/tests; here only its result is overridden.
override_module {
  target = module.capacity
  outputs = {
    disk_gb      = 40
    max_students = 6
  }
}

variables {
  users = {
    kurs = [
      { email = "ben@example.com" },
      { email = "carla@example.com" },
    ]
  }
}

run "initial_ports" {
  assert {
    condition     = local.user_ports["kurs-ben"] == 30001 && local.user_ports["kurs-carla"] == 30002
    error_message = "Initial ports must follow the sorted roster: ${jsonencode(local.user_ports)}"
  }

  assert {
    condition     = length(output.readiness_checks) == 1 && output.readiness_checks[0].name == "kurs"
    error_message = "readiness_checks must list one instance per team."
  }

  # The frontend shows the SSH command only for authtype "ssh" and only
  # when the team VM has no url.
  assert {
    condition     = local.user_accounts["kurs-ben"].authtype == "ssh" && !contains(keys(output.team_vms["kurs"]), "url")
    error_message = "user_accounts must set authtype = \"ssh\" and team_vms must not set url."
  }
}

run "new_student_is_appended" {
  variables {
    users = {
      kurs = [
        { email = "aaron@example.com" },
        { email = "ben@example.com" },
        { email = "carla@example.com" },
      ]
    }
  }

  assert {
    condition     = local.user_ports["kurs-ben"] == 30001 && local.user_ports["kurs-carla"] == 30002
    error_message = "Existing students must keep their ports: ${jsonencode(local.user_ports)}"
  }

  assert {
    condition     = local.user_ports["kurs-aaron"] == 30003
    error_message = "A new student must get the next port: ${jsonencode(local.user_ports)}"
  }
}

run "removed_student_keeps_gap" {
  variables {
    users = {
      kurs = [
        { email = "aaron@example.com" },
        { email = "carla@example.com" },
      ]
    }
  }

  assert {
    condition     = local.user_ports["kurs-carla"] == 30002 && local.user_ports["kurs-aaron"] == 30003
    error_message = "Removing a student must not shift the others: ${jsonencode(local.user_ports)}"
  }
}

run "too_many_students_for_flavor" {
  command = plan

  override_module {
    target = module.capacity
    outputs = {
      disk_gb      = 20
      max_students = 2
    }
  }

  variables {
    users = {
      kurs2 = [
        { email = "a@example.com" },
        { email = "b@example.com" },
        { email = "c@example.com" },
      ]
    }
  }

  expect_failures = [openstack_compute_instance_v2.team_vm]
}

run "students_fit_flavor" {
  command = plan

  override_module {
    target = module.capacity
    outputs = {
      disk_gb      = 20
      max_students = 2
    }
  }

  variables {
    users = {
      kurs2 = [
        { email = "a@example.com" },
        { email = "b@example.com" },
      ]
    }
  }
}
