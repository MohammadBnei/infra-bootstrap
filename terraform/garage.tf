# garage-storage (VMID 301) — confirmed test artifact, no data. Direct
# new-create: download a plain Debian 12 LXC OS template, then create the
# container from it in one pass. No community-script installer, no
# null_resource/remote-exec, no terraform import dance — the previous
# two-phase design relied on the community-scripts.org `ct/garage.sh`
# installer to create+configure the container in one step, but that script
# drops into an interactive whiptail menu instead of honoring its own
# non-interactive var_* settings and hangs forever under Terraform's
# non-interactive SSH provisioner (docs/bootstrap-test-notes.md,
# docs/runbook-k8s-bootstrap.md's old step 4). Garage's actual
# install/config (binary, systemd unit, layout, buckets, keys) now happens
# entirely via ansible/playbooks/garage-configure.yml, once this bare,
# SSH-reachable container exists — Terraform's job stops there.
#
# Debian 13, matching what's already current on the official Proxmox
# template mirror (confirmed via `pveam available` on .165 — 13.6-1 is the
# live "system" section entry as of this writing; .165 also already has a
# 13.1-2 vztmpl cached locally from earlier testing, but this resource
# manages its own download rather than depending on that out-of-band
# artifact, so a from-scratch rebuild on a fresh host still works). Re-run
# `pveam available` before applying if this has gone stale.
resource "proxmox_download_file" "garage_lxc_template" {
  content_type = "vztmpl"
  datastore_id = var.template_download_storage_id
  node_name    = var.pve_node_name
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  file_name    = "debian-13-standard_13.6-1_amd64.tar.zst"
  overwrite    = false
}

resource "proxmox_virtual_environment_container" "garage_storage" {
  node_name    = var.pve_node_name
  vm_id        = var.garage_ct_id
  unprivileged = true
  started      = true
  tags         = ["storage", "s3", "garage"]

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.garage_container_storage
    size         = 200
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "garage-storage"

    # LXC user_account has no `username` — it always configures root, unlike
    # the VM cloud-init user_account block in k8s-vms.tf which sets one.
    user_account {
      keys = [trimspace(file(var.garage_ssh_public_key_file))]
    }

    ip_config {
      ipv4 {
        address = "${var.garage_ip}/24"
        gateway = var.gateway_ipv4
      }
    }
  }

  operating_system {
    type             = "debian"
    template_file_id = proxmox_download_file.garage_lxc_template.id
  }
}
