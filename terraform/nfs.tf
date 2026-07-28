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
# "local" storage actually supports content type "import" via `pvesh get
# /storage` before first apply — same "confirm, don't guess" discipline
# as pve_node_name (true by default on a fresh PVE install, matching
# .165, but not yet verified live on server1).

resource "proxmox_download_file" "nfs_vm_cloudimg" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "server1"
  url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  file_name    = "noble-server-cloudimg-amd64-nfs.qcow2"
  overwrite    = false
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

  initialization {
    datastore_id = var.nfs_storage_id

    dns {
      domain = "localdomain" # see k8s-vms.tf's identical workaround for why
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
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }
}
