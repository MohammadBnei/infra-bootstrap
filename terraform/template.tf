# VMID 9001 ("ubuntu-24.04-ci-template") is this resource's live VMID —
# built fresh by Terraform during the 2026-07-12 smoke test
# (docs/bootstrap-test-notes.md), already includes the qemu-guest-agent
# vendor-data fix (cloud-init.tf). The original 9000 was created by hand
# pre-Terraform, has no guest-agent fix, and still sits on .165 stopped and
# unmanaged — a spare, not this resource, safe to remove by hand once 9001
# is confirmed good.

resource "proxmox_download_file" "ubuntu_2404_cloudimg" {
  content_type = "import"
  datastore_id = var.template_download_storage_id
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
