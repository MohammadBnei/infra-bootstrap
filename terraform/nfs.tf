# nfs-storage (server1) — lightweight cloud-init VM providing NFS-backed
# shared PVE storage (docs/adr/0026) so cross-host VM/template cloning
# takes the bpg/proxmox provider's direct-clone path instead of its
# clone-then-migrate fallback for non-shared storage.
#
# An LXC was considered first (mirroring garage.tf) and rejected:
# nfs-kernel-server needs kernel-level nfsd, which isn't reliably
# namespaced inside a container, and `terraform providers schema -json`
# confirms proxmox_virtual_environment_container exposes no AppArmor/
# privilege escape hatch to work around it — a bare Terraform LXC here
# would be fragile in a way that's hard to reproduce or debug later.
#
# Built directly from the Ubuntu cloud image on server1 — NOT cloned from
# the golden template (VMID 9001) — specifically to avoid the cross-host
# clone chicken-and-egg this VM exists to solve (9001 isn't on shared
# storage until this VM is up and exporting).
#
# Terraform's job stops at a bare, SSH-reachable VM with a raw second
# disk for the export directory — same "create bare, configure via
# ansible" split as garage.tf/garage-configure.yml. NFS install/config
# (nfs-kernel-server, /etc/exports, exportfs) happens entirely in
# ansible/playbooks/nfs-configure.yml.
#
# node_name/download storage are hardcoded to "server1" rather than
# variables — this is a single fixed-purpose resource (user's explicit
# placement choice), unlike k8s_nodes' extensible map. Confirm server1's
# "local" storage actually supports content types "import" and "snippets"
# via `pvesh get /storage` before first apply — same "confirm, don't
# guess" discipline as pve_node_name (true by default on a fresh PVE
# install, matching .165, but not yet verified live on server1). If
# "snippets" isn't enabled yet: `pvesm set local --content
# <existing-list>,snippets` on server1, same one-time prereq as .165's.

resource "proxmox_download_file" "nfs_vm_cloudimg" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "server1"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64-nfs.qcow2"
  overwrite    = false
}

# Guest-agent-only vendor-data — deliberately NOT cloud-init.tf's shared
# k8s_vm_vendor_data (that also formats a Longhorn disk, irrelevant here,
# and would pull in the cross-node shared-storage dependency this VM
# exists to solve in the first place). Confirmed by a real test run: with
# agent.enabled = true below and no way to install the agent before first
# boot, `terraform apply` hangs waiting for a guest-agent handshake that
# never comes (same failure mode cloud-init.tf's own header comment
# documents for the k8s VMs) — installing it via nfs-configure.yml
# afterward is too late, Terraform is already stuck waiting during create.
resource "proxmox_virtual_environment_file" "nfs_vm_vendor_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "server1"

  source_raw {
    file_name = "nfs-vm-vendor-data.yaml"
    data      = <<-EOT
      #cloud-config
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "nfs_storage" {
  name      = "nfs-storage"
  node_name = "server1"
  vm_id     = var.nfs_vm_id
  started   = true
  tags      = ["storage", "nfs"]

  cpu {
    cores = 1
  }

  # Still 1GB with ADR-0036's second export: nfsd is kernel threads, and the
  # only thing more RAM buys is page cache, which barely helps a class scoped
  # to streamed bulk data on `sync` exports. Bump it if `free`/`nfsstat` ever
  # says so, not on principle.
  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.nfs_storage_id
    interface    = "scsi0"
    size         = 20
    import_from  = proxmox_download_file.nfs_vm_cloudimg.id
  }

  # Raw, unformatted — ansible/playbooks/nfs-configure.yml formats + mounts
  # this as the actual NFS export path. Sized for the golden template's own
  # disk (a few GB) plus headroom for a transient full-clone landing here
  # during any future cross-host k8s_nodes provisioning (the provider's
  # direct-clone path keeps the new disk on this shared storage until
  # Terraform's own datastore_id reconciliation moves it to the target
  # node's local storage) — 100GB comfortably covers one such transient
  # clone at today's k8s_nodes disk sizes, not sized for steady-state use.
  disk {
    datastore_id = var.nfs_storage_id
    interface    = "scsi1"
    size         = 100
  }

  # ADR-0036 — K8s PV storage, deliberately a SEPARATE disk from scsi1 above
  # and not a subdirectory of it. scsi1 is sized for a transient template
  # clone; a PVC that runs away on a shared disk would starve the PVE storage
  # ADR-0026 exists to provide, i.e. break cross-host VM cloning. Different
  # lifetimes, different blast radius, different disk.
  # Also raw — ansible/playbooks/nfs-configure.yml formats and exports it at
  # /export/k8s, same split as scsi1.
  disk {
    datastore_id = var.nfs_storage_id
    interface    = "scsi2"
    size         = var.nfs_k8s_disk_size_gb
  }

  initialization {
    datastore_id = var.nfs_storage_id

    # servers: ADR-0036 exports /export/k8s to `k8s-*.bnei.lan` hostnames
    # rather than literal IPs, so `exportfs` on this box has to resolve
    # bnei.lan — Pi-hole is authoritative for it (DECISION.md §2). Same fix
    # build-runner.tf carries, and the same failure k9s-dashboard was
    # debugged into (docs/bootstrap-test-notes.md).
    # NOTE for the already-running VM: this regenerates the cloud-init
    # drive, which only takes effect on reboot. nfs-configure.yml asserts
    # resolution works rather than assuming it landed.
    dns {
      domain  = "localdomain" # see k8s-vms.tf's identical workaround for why
      servers = [var.pihole_ip]
    }

    user_account {
      username = "core"
      keys     = [trimspace(file(var.nfs_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "${var.nfs_ip}/${var.network_cidr_prefix}"
        gateway = var.gateway_ipv4
      }
    }

    vendor_data_file_id = proxmox_virtual_environment_file.nfs_vm_vendor_data.id
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }

  # Safe now that nfs_vm_vendor_data (above) installs the agent at first
  # boot — confirmed by testing that enabling this without a way to
  # install the agent before boot makes apply hang waiting for a
  # handshake that never arrives (see that resource's comment).
  agent {
    enabled = true
  }
}
