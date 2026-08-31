# k9s-dashboard (VMID 102, server1) — pure ops/convenience LXC. A human
# SSHes in and runs k9s against the live ukubi-cluster. No application
# workload, nothing else runs here. Direct new-create, same pattern as
# garage.tf. Terraform's job stops at "bare, SSH-reachable container" —
# kubectl/k9s install and kubeconfig delivery happen entirely via
# ansible/playbooks/k9s-dashboard-configure.yml, never a Terraform
# provisioner (see garage.tf's header comment — a Terraform-driven
# installer once hung under the non-interactive SSH provisioner).
#
# node_name hardcoded to "server1" rather than var.pve_node_name — single
# fixed-purpose resource (user's explicit placement choice), same reasoning
# as nfs.tf's identical hardcoding. Needs its own vztmpl download (below)
# rather than reusing garage.tf's proxmox_download_file.garage_lxc_template:
# "local" storage's vztmpl content is per-node in Proxmox, not shared
# across the corosync cluster, so a template downloaded onto .165 isn't
# visible to server1.
resource "proxmox_download_file" "k9s_dashboard_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "server1"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  file_name    = "debian-13-standard_13.6-1_amd64.tar.zst"
  overwrite    = false
}

resource "proxmox_virtual_environment_container" "k9s_dashboard" {
  node_name    = "server1"
  vm_id        = var.k9s_dashboard_ct_id
  unprivileged = true
  started      = true
  tags         = ["ops", "k9s", "dashboard"]

  cpu {
    cores = 1
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = var.k9s_dashboard_container_storage
    size         = 8
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "k9s-dashboard"

    # LXC user_account has no `username` — always configures root, same as
    # garage_storage.
    user_account {
      keys = [trimspace(file(pathexpand(var.k9s_dashboard_ssh_public_key_file)))]
    }

    ip_config {
      ipv4 {
        address = "${var.k9s_dashboard_ip}/24"
        gateway = var.gateway_ipv4
      }
    }

    # Matches live (`pct config 102`: nameserver 192.168.1.55, searchdomain
    # bnei.lan). Undeclared, terraform reads the live values as drift and
    # REMOVES them on the next apply — which would take `.lan` resolution with
    # them, and `.lan` is how this container reaches registry.bnei.lan and the
    # k8s-*.bnei.lan names. Found 2026-08-31 in the discard=on plan.
    dns {
      domain  = "bnei.lan"
      servers = ["192.168.1.55"] # Pi-hole
    }
  }

  operating_system {
    type             = "debian"
    template_file_id = proxmox_download_file.k9s_dashboard_lxc_template.id
  }
}
