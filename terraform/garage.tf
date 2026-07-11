# garage-storage (VMID 301) — confirmed test artifact, no data. Rebuilt via
# the community-scripts.org LXC installer (creates the container AND
# installs/configures Garage in one step — a hand-rolled Terraform LXC
# resource alone would only give a bare container), then adopted into
# Terraform state so it's tracked like everything else going forward.
#
# Two-phase, by necessity: the script itself must run once (phase 1) before
# the resulting container's exact live config is knowable, which is what
# phase 2's resource block needs to mirror for a clean `terraform import`.
# The `proxmox_virtual_environment_container` block below is a STARTING
# POINT — before running `terraform import`, verify every value against
# `pct config <ctid>` on .165 per the plan's "read for safe sync" step, and
# fix any mismatch first (a bad match here isn't dangerous the way
# pg/hermes are, since there's no data on it, but a spurious diff still
# wastes an apply cycle or risks an unwanted recreate).

# Phase 1: destroy the old test container, then bootstrap fresh via the
# community-scripts.org installer with pinned, non-interactive settings.
# Use https://community-scripts.org/generator to produce/verify the exact
# var_* set for garage.sh before filling in the inline script below — the
# values here are the plan's starting point, not guaranteed final.
resource "null_resource" "garage_bootstrap" {
  connection {
    type        = "ssh"
    host        = var.pve_host
    user        = "root"
    private_key = var.pve_ssh_private_key
  }

  provisioner "remote-exec" {
    inline = [
      "pct status ${var.garage_ct_id} >/dev/null 2>&1 && pct stop ${var.garage_ct_id} --force || true",
      "pct status ${var.garage_ct_id} >/dev/null 2>&1 && pct destroy ${var.garage_ct_id} || true",
      join(" ", [
        "var_ctid=${var.garage_ct_id}",
        "var_hostname=garage-storage",
        "var_cpu=2",
        "var_ram=2048",
        "var_disk=200",
        "var_container_storage=${var.garage_container_storage}",
        "var_brg=vmbr0",
        "var_net=${var.garage_ip}/24",
        "var_gateway=${var.gateway_ipv4}",
        "var_unprivileged=1",
        "bash -c \"$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/garage.sh)\"",
      ]),
    ]
  }

  triggers = {
    ct_id = var.garage_ct_id # one-shot; taint manually to force a rerun
  }
}

# Phase 2: adopt the container the script created. `terraform import
# proxmox_virtual_environment_container.garage_storage <node>/<ctid>` after
# verifying this block matches live `pct config` output, then confirm
# `terraform plan` is zero-diff before this is trusted.
resource "proxmox_virtual_environment_container" "garage_storage" {
  node_name    = var.pve_node_name
  vm_id        = var.garage_ct_id
  unprivileged = true
  started      = true

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

    ip_config {
      ipv4 {
        address = "${var.garage_ip}/24"
        gateway = var.gateway_ipv4
      }
    }
  }

  operating_system {
    type             = "debian"
    template_file_id = var.garage_template_file_id
  }

  depends_on = [null_resource.garage_bootstrap]
}
