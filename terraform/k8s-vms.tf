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
  node_name = coalesce(each.value.node_name, var.pve_node_name)
  vm_id     = each.value.vm_id
  started   = true
  # q35 required for PCIe passthrough (hostpci needs a PCIe root port,
  # which the default i440fx/"pc" machine type doesn't provide) — set
  # for every node, not just the GPU one, for consistency with pg01/pg02
  # in imported.tf, which already use q35 uniformly.
  machine = "q35"

  # clone.node_name is the SOURCE node (always var.pve_node_name — the
  # template only ever lives on .165), independent of this resource's own
  # (coalesced) node_name, which is the destination. Verified against
  # bpg/terraform-provider-proxmox's actual vmCreateClone: leaving this
  # unset makes the provider call CloneVM against the *target* node
  # (node-scoped API endpoint, not ID-scoped — cluster-unique VMIDs don't
  # save you here), which 404s for any cross-host worker since VM 9001
  # only physically exists on .165. Setting it lets the provider pick the
  # right path itself: a direct clone if the template's disks are on
  # shared storage (docs/adr/0026's shared-templates NFS pool), or an
  # automatic clone-then-migrate if not.
  #
  # Set to null (== omitted) for same-host entries, not unconditionally —
  # confirmed via a real `terraform plan` that clone.node_name is a
  # ForceNew attribute: setting it on an entry that already exists in
  # state (k8s-cp-01/k8s-worker-01, both live production VMs) marks them
  # "must be replaced" even though the resolved value is identical to
  # where they already live. Only entries actually landing on a different
  # node need it; same-host entries must keep this block byte-for-byte
  # unchanged from before this ADR-0026 change.
  clone {
    node_name = coalesce(each.value.node_name, var.pve_node_name) != var.pve_node_name ? var.pve_node_name : null
    vm_id     = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full      = true
  }

  # down_delay doubles as Proxmox's own ACPI shutdown timeout for this VM
  # (used by qmshutdown/pve-guests.service when no explicit --timeout is
  # given) — default is 180s. Confirmed live 2026-07-30
  # (docs/bootstrap-test-notes.md): with the default, Proxmox force-killed
  # k8s-cp-01/k8s-worker-01 mid-eviction — ansible/playbooks/
  # self-drain-configure.yml's own drain got through only 2-3 of 34 pods
  # before the whole VM vanished with zero further logging, since its
  # graceful drain_stop_timeout_sec (240s) never got a chance to run out
  # on its own. 300s here gives that drain real headroom to finish before
  # Proxmox's patience does. Harmless for nodes without self-drain
  # configured — this only affects how long a graceful shutdown/reboot is
  # allowed to take, not normal operation.
  #
  # order=2 puts these behind nfs.tf's nfs-storage (order=1) on server1: the
  # cross-host entries there reference shared-templates for their cloud-init
  # vendor snippet, and PVE starts unordered guests in VMID order, i.e.
  # before the NFS server that backs it. Harmless on the other two hosts —
  # start order is per-node.
  startup {
    order      = 2
    down_delay = 300
  }

  cpu {
    cores = each.value.cpu_cores
    # Default (unset) resolves to Proxmox's "qemu64" baseline, which lacks
    # AVX2 — confirmed via /proc/cpuinfo on k8s-worker-01 ("QEMU Virtual
    # CPU version 2.5+", no avx2 flag). Bun (used by editable-blog's
    # runtime image) hard-requires AVX2 and crashes with SIGILL
    # (exit 132) without it. "host" passes through .165's real CPU
    # features. Revisit for Stage 2: "host" isn't live-migration-safe
    # across physically different CPUs once .200/.161 join — may need a
    # named baseline model (e.g. a modern microarchitecture common to all
    # three hosts) instead once their CPUs are known.
    type = "host"
  }

  memory {
    dedicated = each.value.memory_dedicated_mb
  }

  disk {
    datastore_id = coalesce(each.value.datastore_id, var.template_storage_id)
    interface    = "scsi0"
    size         = each.value.os_disk_size_gb
  }

  disk {
    datastore_id = coalesce(each.value.datastore_id, var.template_storage_id)
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
    datastore_id = coalesce(each.value.datastore_id, var.template_storage_id)

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

    # Same-host entries keep the original (.165-local) snippet untouched;
    # cross-host entries use the shared-storage copy — see cloud-init.tf's
    # header comment for why this can't just be one repointed resource.
    vendor_data_file_id = coalesce(each.value.node_name, var.pve_node_name) != var.pve_node_name ? proxmox_virtual_environment_file.k8s_vm_vendor_data_shared.id : proxmox_virtual_environment_file.k8s_vm_vendor_data.id
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
