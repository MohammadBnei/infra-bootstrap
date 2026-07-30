# pg-etcd-witness (ex-laptop) — dedicated, etcd-only 3rd member of Pigsty's
# Patroni DCS (docs/adr/0029). No PG data, no separate PG role: this VM
# exists purely so the DCS has real 3-node quorum (floor(N/2)+1) instead of
# today's single etcd node on `.165` — same reasoning as ADR-0017's k8s
# 3-CP/etcd placement, applied to Postgres.
#
# Deliberately NOT co-located on the existing k8s-cp-03 VM on this same
# host: keeps Patroni's DCS availability independent of k8s control-plane
# lifecycle events (kubeadm upgrades, CP restarts) on the same box — see
# ADR-0029's placement rationale.
#
# Cloned from the golden template (VMID 9001) via shared-templates NFS
# (ADR-0026), same cross-host clone path k8s-cp-02/k8s-cp-03 already use
# successfully — no need for nfs.tf's manual cloud-image bootstrap, that
# was only necessary for nfs-storage itself (the shared-storage
# chicken-and-egg). Reuses k8s_vm_vendor_data_shared (cloud-init.tf) for
# qemu-guest-agent — its Longhorn-disk-format block is guarded on
# `/dev/sdb` existing, a no-op here since this VM has no second disk.
#
# Terraform's job stops at a bare, SSH-reachable VM — actually joining it
# to Pigsty's etcd cluster (`etcd.yml`/equivalent add-member operation) is
# a live DCS change, the user's own action per pigsty/CLAUDE.md's
# confirmation rules, not run unattended from here.

resource "proxmox_virtual_environment_vm" "pg_etcd_witness" {
  name      = "pg-etcd-witness"
  node_name = "ex-laptop"
  vm_id     = var.pg_etcd_witness_vm_id
  started   = true
  machine   = "q35"
  tags      = ["postgres", "etcd", "witness"]

  # Source node for the clone is always var.pve_node_name (.165, the only
  # host the template physically lives on) — see k8s-vms.tf's identical
  # clone.node_name comment for why this can't be left unset.
  clone {
    node_name = var.pve_node_name
    vm_id     = proxmox_virtual_environment_vm.ubuntu_2404_template.vm_id
    full      = true
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-lvm" # ADR-0028 — ex-laptop has no dedicated ZFS pool
    interface    = "scsi0"
    size         = 10
  }

  initialization {
    datastore_id = "local-lvm"

    dns {
      domain = "localdomain" # see k8s-vms.tf's identical workaround
    }

    user_account {
      username = "core"
      keys     = [trimspace(file(var.pg_etcd_witness_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "${var.pg_etcd_witness_ip}/${var.network_cidr_prefix}"
        gateway = var.gateway_ipv4
      }
    }

    vendor_data_file_id = proxmox_virtual_environment_file.k8s_vm_vendor_data_shared.id
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
