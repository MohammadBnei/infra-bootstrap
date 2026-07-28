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

  # datastore_id is template_shared_storage_id (NFS, docs/adr/0026), not
  # template_storage_id — both this disk AND the cloud-init drive below
  # must be on *shared* storage for k8s-vms.tf's cross-node clone to take
  # the provider's direct-clone path (it checks every datastore the
  # source VM's disks use). template_storage_id stays the separate,
  # unmoved default for k8s_nodes entries that don't set their own
  # datastore_id — repointing it here too would also try to move
  # k8s-cp-01/k8s-worker-01's already-working local-lvm disks onto NFS.
  disk {
    datastore_id = var.template_shared_storage_id
    interface    = "scsi0"
    import_from  = proxmox_download_file.ubuntu_2404_cloudimg.id
  }

  # Empty cloud-init drive — clones set user_account/ip_config per VM.
  initialization {
    datastore_id = var.template_shared_storage_id
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
