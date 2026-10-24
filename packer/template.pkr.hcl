packer {
  required_plugins {
    openstack = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/openstack"
    }
  }
}

locals {
  cloud                   = "openstack"
  provision_script        = "scripts/provision.sh"
  source_image_name       = "Ubuntu 24.04"
  flavor                  = "gp1.small"
  ssh_username            = "ubuntu"
  ssh_timeout             = "20m"
  use_blockstorage_volume = false
  volume_size             = 20
  use_floating_ip         = false
  files_dir               = "/tmp/kubernetes-app-files"
}

source "openstack" "image" {
  cloud                   = local.cloud
  image_name              = var.image_name
  source_image_name       = local.source_image_name
  flavor                  = local.flavor
  networks                = var.networks
  security_groups         = var.security_groups
  use_blockstorage_volume = local.use_blockstorage_volume
  volume_size             = local.volume_size
  use_floating_ip         = local.use_floating_ip
  ssh_ip_version          = "4"
  ssh_timeout             = local.ssh_timeout
  ssh_username            = local.ssh_username
}

build {
  sources = ["source.openstack.image"]

  provisioner "shell" {
    inline = [
      "echo 'Waiting for cloud-init...'",
      "cloud-init status --wait || true",
      "echo 'Cloud-init ready'",
      "mkdir -p ${local.files_dir}"
    ]
  }

  # labctl, Erststart-Skript und Student-Image-Quellen auf die Build-VM laden.
  provisioner "file" {
    source      = "files/"
    destination = local.files_dir
  }

  provisioner "shell" {
    script      = local.provision_script
    max_retries = 3
    environment_vars = [
      "K3S_VERSION=${var.k3s_version}",
      "STUDENT_IMAGE=${var.student_image}",
      "FILES_DIR=${local.files_dir}",
    ]
  }
}
