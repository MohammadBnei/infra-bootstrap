# k8s-cp-01 / k8s-worker-01 / k8s-worker-gpu — MISSION.md §3 locked
# IDs/IPs. Pure new-create, no import: whatever currently sits at the old
# test-run IPs (.241/.242 in inventory/ukubi/hosts.yaml) is confirmed
# test-only and out of scope here. If VMID 201/202/203 are already occupied
# by leftover test VMs, destroy those manually before first apply — they
# carry no data worth protecting.

resource "proxmox_virtual_environment_vm" "k8s_cp_01" {
  name      = "k8s-cp-01"
  node_name = var.pve_node_name
  vm_id     = 201
  started   = true

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full  = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi0"
    size         = 40
  }

  initialization {
    datastore_id = var.template_storage_id

    user_account {
      username = "core"
      keys     = [trimspace(file(var.k8s_vm_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "192.168.1.201/24"
        gateway = var.gateway_ipv4
      }
    }
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

resource "proxmox_virtual_environment_vm" "k8s_worker_01" {
  name      = "k8s-worker-01"
  node_name = var.pve_node_name
  vm_id     = 202
  started   = true

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full  = true
  }

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi0"
    size         = 60
  }

  initialization {
    datastore_id = var.template_storage_id

    user_account {
      username = "core"
      keys     = [trimspace(file(var.k8s_vm_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "192.168.1.202/24"
        gateway = var.gateway_ipv4
      }
    }
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

resource "proxmox_virtual_environment_vm" "k8s_worker_gpu" {
  name      = "k8s-worker-gpu"
  node_name = var.pve_node_name
  vm_id     = 203
  started   = true

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full  = true
  }

  cpu {
    cores = 6
  }

  memory {
    dedicated = 15360
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi0"
    size         = 100
  }

  # RTX 2070 SUPER passthrough via a pre-created PCI Resource Mapping (see
  # variables.tf gpu_mapping_name) — hostpci's raw `id` attribute needs root
  # password auth, incompatible with the api_token this provider uses.
  # IOMMU/vfio-pci binding on the host is a prerequisite this doesn't manage.
  hostpci {
    device  = "hostpci0"
    mapping = var.gpu_mapping_name
    pcie    = true
  }

  initialization {
    datastore_id = var.template_storage_id

    user_account {
      username = "core"
      keys     = [trimspace(file(var.k8s_vm_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "192.168.1.203/24"
        gateway = var.gateway_ipv4
      }
    }
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
