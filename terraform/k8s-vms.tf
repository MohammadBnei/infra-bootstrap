# K8s VM topology is driven entirely by var.k8s_nodes (variables.tf) — see
# that variable's description before editing anything below. ARCHITECTURE.md
# §2 is the canonical target spec; the default there matches ARCHITECTURE.md
# exactly. Pure new-create, no import: whatever currently sits at old
# test-run IPs is confirmed test-only and out of scope here. If a node's
# vm_id is already occupied by a leftover test VM, destroy it manually
# before first apply — it carries no data worth protecting.
#
# Each node also carries a second disk (scsi1, longhorn_disk_size_gb or the
# shared var.longhorn_disk_size_gb fallback) reserved for Longhorn's data
# path — ARCHITECTURE.md storage section. Terraform allocates the raw block
# device; cloud-init.tf's vendor-data formats + mounts it at
# /var/lib/longhorn on first boot before Longhorn is deployed via gitops.
#
# PVE's cloud-init generator otherwise defaults DNS search domain to "dev"
# (a real public TLD) — with ndots:5, every in-cluster FQDN tries appending
# it before the absolute name, gets a live non-NXDOMAIN answer from a public
# Cloudflare-fronted IP, and never reaches the correct ClusterIP. Root cause
# of the 2026-07-13 smoke test's Infisical/ArgoCD 409 findings
# (docs/bootstrap-test-notes.md). "localdomain" isn't a real TLD, so a
# failed lookup against it correctly NXDOMAINs and falls through to the
# real name — hardcoded below, not a variable, since it's a fixed
# workaround rather than a real per-node choice.
#
# GPU passthrough (RTX 2070 SUPER) is via a pre-created PCI Resource Mapping
# (variables.tf gpu_mapping_name) — hostpci's raw `id` attribute needs root
# password auth, incompatible with the api_token this provider uses. IOMMU/
# vfio-pci binding on the host is a prerequisite this doesn't manage (host
# needs AMD-Vi enabled in BIOS — AMD CBS -> NBIO Common Options — plus
# vfio-pci bound to all 4 functions of 0b:00; see
# /usr/local/bin/vfio-pci-bind-gpu.sh + vfio-pci-bind-gpu.service on .165,
# which force-bind at boot since the modprobe.d ids= option alone loses the
# race against xhci_hcd/snd_hda_intel/i2c_nvidia_gpu on some boots). The
# "gpu" PCI Resource Mapping now exists on .165 (node bnei, all 4 functions
# of 0000:0b:00, iommu group 2).

resource "proxmox_virtual_environment_vm" "k8s_node" {
  for_each  = var.k8s_nodes
  name      = each.key
  node_name = var.pve_node_name
  vm_id     = each.value.vm_id
  started   = true

  clone {
    vm_id = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full  = true
  }

  cpu {
    cores = each.value.cpu_cores
  }

  memory {
    dedicated = each.value.memory_dedicated_mb
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi0"
    size         = each.value.os_disk_size_gb
  }

  disk {
    datastore_id = var.template_storage_id
    interface    = "scsi1"
    size         = coalesce(each.value.longhorn_disk_size_gb, var.longhorn_disk_size_gb)
  }

  dynamic "hostpci" {
    for_each = each.value.gpu ? [1] : []
    content {
      device  = "hostpci0"
      mapping = var.gpu_mapping_name
      pcie    = true
    }
  }

  initialization {
    datastore_id = var.template_storage_id

    dns {
      domain = "localdomain"
    }

    user_account {
      username = "core"
      keys     = [trimspace(file(var.k8s_vm_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.network_cidr_prefix}"
        gateway = var.gateway_ipv4
      }
    }

    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vm_vendor_data.id
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }
}

# Renamed from two hardcoded resources (k8s_cp_01, k8s_worker_01) to a
# single for_each keyed by var.k8s_nodes — these `moved` blocks keep
# Terraform from treating the rename as destroy+recreate.
moved {
  from = proxmox_virtual_environment_vm.k8s_cp_01
  to   = proxmox_virtual_environment_vm.k8s_node["k8s-cp-01"]
}

moved {
  from = proxmox_virtual_environment_vm.k8s_worker_01
  to   = proxmox_virtual_environment_vm.k8s_node["k8s-worker-01"]
}
