# VMID 9000 ("ubuntu-24.04-ci-template") already exists on .165, created
# manually. Per the plan: it's a template (no user data), low risk either
# way. Default here is destroy-and-recreate under Terraform ownership, since
# that's simpler than the zero-diff import dance reserved for pg/hermes. If
# you'd rather adopt the existing one instead, `terraform import` this
# resource against the live VMID before first apply and skip the destroy.

resource "proxmox_download_file" "ubuntu_2404_cloudimg" {
  content_type = "import"
  datastore_id = var.template_storage_id
  node_name    = var.pve_node_name
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  overwrite    = false
}

resource "proxmox_virtual_environment_vm" "ubuntu_2404_template" {
  name      = "ubuntu-24.04-ci-template"
  node_name = var.pve_node_name
  vm_id     = var.template_vm_id
  template  = true
  started   = false

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi0"
    import_from  = proxmox_download_file.ubuntu_2404_cloudimg.id
  }

  # Empty cloud-init drive — clones set user_account/ip_config per VM.
  initialization {
    datastore_id = var.template_storage_id
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }
}
