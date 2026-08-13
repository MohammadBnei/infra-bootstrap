# build-runner (VMID 103, server1) — GitHub Actions runner that builds
# container images and pushes them to the in-cluster registry (ADR-0034).
#
# This lives in an LXC rather than a pod, and that is a correction, not a
# preference. The original design put it in-cluster with buildah under
# `--isolation chroot --storage-driver vfs`, on the reasoning that this
# avoids needing a privileged pod. That holds for buildah's *run* step and
# not for its *storage* step: extracting an image layer calls
# `mount --make-rprivate /`, which needs CAP_SYS_ADMIN, and it fails in an
# unprivileged pod with `remount /, flags: 0x44000: permission denied`
# (containers/buildah#4920, #5622). The genuinely-rootless path wants
# setuid newuidmap/newgidmap, which fails under Kubernetes too (#4049).
# Confirmed live before this file existed — see docs/bootstrap-test-notes.md.
#
# The remaining in-cluster option was a privileged container executing an
# app repo's Dockerfile, which is a node-level escape risk and strictly
# worse than the identity coupling ADR-0034 splits the runners to avoid.
# An LXC has real root, so the whole problem class disappears; builds leave
# the cluster entirely, which is *stronger* isolation than the
# no-ServiceAccount pod it replaces; and it is still on the LAN, so the
# latency argument is untouched. ADR-0035 already commits to an LXC runner
# for Forgejo, so Phase 2 inherits this rather than duplicating it.
#
# Direct new-create, same pattern as garage.tf/k9s-dashboard.tf. Terraform's
# job stops at "bare, SSH-reachable container" — podman/buildah and the
# runner itself are installed entirely via
# ansible/playbooks/build-runner-configure.yml, never a Terraform
# provisioner (see garage.tf's header for why).
#
# node_name hardcoded to "server1" for the same reason k9s-dashboard is:
# single fixed-purpose resource, and "local" storage's vztmpl content is
# per-node in Proxmox, so it needs its own download rather than reusing
# another host's template.
resource "proxmox_download_file" "build_runner_lxc_template" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "server1"
  url          = "http://download.proxmox.com/images/system/debian-13-standard_13.6-1_amd64.tar.zst"
  file_name    = "debian-13-standard_13.6-1_amd64.tar.zst"
  overwrite    = false
}

resource "proxmox_virtual_environment_container" "build_runner" {
  node_name    = "server1"
  vm_id        = var.build_runner_ct_id
  unprivileged = true
  started      = true
  tags         = ["ci", "build", "runner"]

  # Builds are the whole point, so this is sized for them rather than for
  # idling. The disk is the number most likely to need revisiting: podman
  # keeps every pulled base image and build layer, and nothing prunes it
  # automatically — build-runner-configure.yml installs a weekly
  # `podman system prune` timer for exactly that reason.
  cpu {
    cores = 4
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.build_runner_container_storage
    size         = 40
  }

  # nesting is required, not optional: podman/buildah inside an unprivileged
  # LXC needs it to create the mount and user namespaces that the
  # in-cluster attempt could not. keyctl is needed for the same reason
  # podman documents it for LXC — the kernel keyring is namespaced and
  # container runtimes touch it during image handling.
  features {
    nesting = true
    keyctl  = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "build-runner"

    # LXC user_account has no `username` — always configures root, same as
    # garage_storage and k9s_dashboard.
    user_account {
      keys = [trimspace(file(pathexpand(var.build_runner_ssh_public_key_file)))]
    }

    # Set explicitly rather than left to DHCP: Proxmox statically injects
    # /etc/resolv.conf at the LXC level, bypassing DHCP-handed DNS entirely
    # — k9s-dashboard hit exactly this and could not resolve bnei.lan
    # (docs/bootstrap-test-notes.md). This box must reach
    # registry.bnei.lan to push, so it gets Pi-hole up front instead of
    # being debugged into it later.
    dns {
      servers = [var.pihole_ip]
    }

    ip_config {
      ipv4 {
        address = "${var.build_runner_ip}/24"
        gateway = var.gateway_ipv4
      }
    }
  }

  operating_system {
    type             = "debian"
    template_file_id = proxmox_download_file.build_runner_lxc_template.id
  }
}
