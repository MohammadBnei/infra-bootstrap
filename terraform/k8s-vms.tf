# k8s-cp-01 / k8s-worker-01 — MISSION.md §3 locked IDs/IPs. 2-node
# cluster: k8s-worker-01 carries the GPU passthrough directly, no separate
# k8s-worker-gpu VM (ARCHITECTURE.md §2). Pure new-create, no import:
# whatever currently sits at the old test-run IPs (.241/.242 in
# inventory/ukubi/hosts.yaml) is confirmed test-only and out of scope here.
# If VMID 201/202 are already occupied by leftover test VMs, destroy those
# manually before first apply — they carry no data worth protecting.
#
# Each VM also carries a second disk (scsi1, var.longhorn_disk_size_gb)
# reserved for Longhorn's data path — ARCHITECTURE.md storage section.
# Terraform allocates the raw block device; cloud-init.tf's vendor-data
# formats + mounts it at /var/lib/longhorn on first boot before Longhorn
# is deployed via gitops.

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

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi1"
    size         = var.longhorn_disk_size_gb
  }

  initialization {
    datastore_id = var.template_storage_id

    # PVE's cloud-init generator otherwise defaults this VM's DNS search
    # domain to "dev" (a real public TLD) — with ndots:5, every in-cluster
    # FQDN tries appending it before the absolute name, gets a live
    # non-NXDOMAIN answer from a public Cloudflare-fronted IP, and never
    # reaches the correct ClusterIP. Root cause of the 2026-07-13 smoke
    # test's Infisical/ArgoCD 409 findings (docs/bootstrap-test-notes.md).
    # "localdomain" isn't a real TLD, so a failed lookup against it
    # correctly NXDOMAINs and falls through to the real name.
    dns {
      domain = "localdomain"
    }

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

    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vm_vendor_data.id
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

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi1"
    size         = var.longhorn_disk_size_gb
  }

  # RTX 2070 SUPER passthrough via a pre-created PCI Resource Mapping (see
  # variables.tf gpu_mapping_name) — hostpci's raw `id` attribute needs root
  # password auth, incompatible with the api_token this provider uses.
  # IOMMU/vfio-pci binding on the host is a prerequisite this doesn't manage.
  #
  # TEMPORARILY DISABLED for the 2026-07-13 DNS-fix smoke test: the "gpu"
  # PCI Resource Mapping doesn't exist yet on .165 (VM start failed with
  # "PCI device mapping not found for 'gpu'") — it's a one-time manual step
  # in the Proxmox UI (Datacenter -> Resource Mappings) requiring root, out
  # of reach of the API-token provider. Re-enable this block once that
  # mapping is created.
  # hostpci {
  #   device  = "hostpci0"
  #   mapping = var.gpu_mapping_name
  #   pcie    = true
  # }

  initialization {
    datastore_id = var.template_storage_id

    # See k8s_cp_01's initialization.dns comment — same fix, same reason.
    dns {
      domain = "localdomain"
    }

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

    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vm_vendor_data.id
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
