# pg01, pg02, hermesagent — REAL, production, actively used. Per the plan:
# maximum care, no guessing, no shortcuts.
#
# ============================================================================
# DO NOT RUN `terraform import` OR ANY `apply` TOUCHING THIS FILE until:
#   1. You've captured live config read-only via SSH to .165:
#        qm config 205   (pg01)
#        qm config 207   (pg02)
#        pct config 101  (hermesagent)
#   2. Every value below — especially disk datastore/format, network bridge,
#      and MAC ADDRESS — has been corrected to match that live output
#      exactly. A missing/wrong MAC reads as a spurious diff and risks
#      Terraform wanting to replace the NIC.
#   3. `terraform plan -target=<resource>` shows a ZERO-diff for each one,
#      individually, before moving to the next.
# The disk_datastore_id / network_bridge / mac_address variables below have
# NO DEFAULT on purpose — Terraform will hard-fail on `plan`/`apply` until
# you supply them from live capture. That's intentional, not a bug: it's a
# forcing function so this can't be applied against guessed values.
# ============================================================================

variable "pg01_disk_datastore_id" {
  description = "REQUIRED, from live `qm config 205` — do not guess."
  type        = string
}

variable "pg01_network_bridge" {
  description = "REQUIRED, from live `qm config 205` net0 line — do not guess."
  type        = string
}

variable "pg01_mac_address" {
  description = "REQUIRED, from live `qm config 205` net0 line — do not guess."
  type        = string
}

variable "pg02_disk_datastore_id" {
  description = "REQUIRED, from live `qm config 207` — do not guess."
  type        = string
}

variable "pg02_network_bridge" {
  description = "REQUIRED, from live `qm config 207` net0 line — do not guess."
  type        = string
}

variable "pg02_mac_address" {
  description = "REQUIRED, from live `qm config 207` net0 line — do not guess."
  type        = string
}

variable "hermesagent_disk_datastore_id" {
  description = "REQUIRED, from live `pct config 101` — do not guess."
  type        = string
}

variable "hermesagent_network_bridge" {
  description = "REQUIRED, from live `pct config 101` net0 line — do not guess."
  type        = string
}

variable "hermesagent_mac_address" {
  description = "REQUIRED, from live `pct config 101` net0 line — do not guess."
  type        = string
}

variable "hermesagent_unprivileged" {
  description = "REQUIRED, from live `pct config 101` (unprivileged: 0 or 1) — do not guess. Also determines whether the root@pam-only privileged-container limitation (see README.md) applies."
  type        = bool
}

# Live capture 2026-07-20 (`qm config 205`/`207`, `pct config 101` on
# .165) — memory/disk size/machine/smbios/cloud-init below are corrected to
# match exactly. `scsihw`/`boot`/`bootdisk`/`meta`/`vmgenid` seen in the
# live output have no equivalent in this provider's schema (checked via
# `terraform providers schema -json`) — nothing to set, they're simply
# outside what Terraform can manage here, not an oversight.

resource "proxmox_virtual_environment_vm" "pg01" {
  name      = "pg01"
  node_name = var.pve_node_name
  vm_id     = 205
  started   = true
  machine   = "q35"

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.pg01_disk_datastore_id
    interface    = "scsi0"
    # live scsi0 size=53760M = 52.5G exactly — the provider rejects
    # fractions at runtime despite the schema saying `number` ("Attribute
    # must be a whole number"). No integer is a true zero-diff (round up
    # = grows a production disk on apply, round down = shrink risk), so
    # this is ignore_changes'd below instead of guessed.
    size = 53
  }

  smbios {
    uuid = "e67c96be-15ed-4528-95a6-d3a9714d0e2d"
  }

  initialization {
    datastore_id = var.pg01_disk_datastore_id

    # live config has no dns override — PVE node defaults apply. Unlike
    # k8s-vms.tf's k8s_node, pg01 isn't cluster-DNS-bound, so the
    # "localdomain" workaround there doesn't apply here.

    user_account {
      username = "vagrant"
      # cipassword reads back as "**********" from Proxmox everywhere —
      # the real value is unrecoverable. Left unset: password is
      # `optional`, not `computed`, in the provider schema, so both sides
      # should read null. If the zero-diff plan -target gate below shows a
      # password diff, that assumption was wrong — add `ignore_changes`
      # for `initialization[0].user_account` instead of guessing a value.
      keys = ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCymdmTAQRj+9UTDCW4fj/zYYf0dX0FULRG+zCPypvzqwdg8I+Jz0qV/cZEGfyaJMZbbaW2pCoJP340g0SAsYNgV/MEoKCC/reIrKIaSB4710bVl7P5y+dU9cyonkm8UPzgDEkcb9Vk23d50QrInNFO1ZzqsrNCIL3kViTD5yKjsRwrfahyu/jTCKVq8L6RhFVNTungfAChRPUDp1RmPaFy2wzV/Kh7hm3OtU+LL/D9Ft2S05ebobQpm34NGrx3Ac+dNPSoIH3vPdTjPyaCiWuJ0DlxmboLTRIyTatop9dwi/5bENAzxMeWGgoJAIbQvX5A8wQhrqN6T4GcQV26AuY4zYTNyzqD2bsnDhtpZ+QcfzmMZuB/j5IV2NidwRkUgOMYFkI7J+wDnbobNhpAuFNK0z39++GbvHp0HaFyPFy2E2+hb7098bbqZfbCD2OgwOY2oXZOv/LLg7DHelksMSfMhAw3HEAzJ1h/wnrtdqdX/oFqtDjyyuZjygvA7DNQjkgHiV7tCM2ZUh/AMPc60rff1imgJOuS9JJXYDFAaesYZqcvMaAeTY2UyQQWz4gLHtbHQ6Y2Oaq8fXetA0mivKUYitgfwQDbz6Wh81bQEjXg1j56fuIKi6IzOSILRv0NxgF7508K5CUEpjhg3EWQrl4ZAaZIFM31z7OSJXniJWntqQ== mohammadamine.banaei@pm.me"]
    }

    ip_config {
      ipv4 {
        address = "192.168.1.205/24"
        gateway = "192.168.1.254"
      }
    }
  }

  network_device {
    bridge      = var.pg01_network_bridge
    mac_address = var.pg01_mac_address
  }

  agent {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
    # see disk.size comment above — no whole-number GB value is a true
    # zero-diff for a 52.5G live disk.
    ignore_changes = [disk[0].size]
  }
}

resource "proxmox_virtual_environment_vm" "pg02" {
  name      = "pg02"
  node_name = var.pve_node_name
  vm_id     = 207
  started   = true
  machine   = "q35"

  cpu {
    cores = 2
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.pg02_disk_datastore_id
    interface    = "scsi0"
    # see pg01's comment above — same 52.5G-isn't-a-whole-number issue,
    # ignore_changes'd below.
    size = 53
  }

  smbios {
    uuid = "28e578af-e965-4aee-9882-c947b3142711"
  }

  initialization {
    datastore_id = var.pg02_disk_datastore_id

    user_account {
      username = "vagrant"
      # see pg01's comment above — same cipassword caveat, same key.
      keys = ["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCymdmTAQRj+9UTDCW4fj/zYYf0dX0FULRG+zCPypvzqwdg8I+Jz0qV/cZEGfyaJMZbbaW2pCoJP340g0SAsYNgV/MEoKCC/reIrKIaSB4710bVl7P5y+dU9cyonkm8UPzgDEkcb9Vk23d50QrInNFO1ZzqsrNCIL3kViTD5yKjsRwrfahyu/jTCKVq8L6RhFVNTungfAChRPUDp1RmPaFy2wzV/Kh7hm3OtU+LL/D9Ft2S05ebobQpm34NGrx3Ac+dNPSoIH3vPdTjPyaCiWuJ0DlxmboLTRIyTatop9dwi/5bENAzxMeWGgoJAIbQvX5A8wQhrqN6T4GcQV26AuY4zYTNyzqD2bsnDhtpZ+QcfzmMZuB/j5IV2NidwRkUgOMYFkI7J+wDnbobNhpAuFNK0z39++GbvHp0HaFyPFy2E2+hb7098bbqZfbCD2OgwOY2oXZOv/LLg7DHelksMSfMhAw3HEAzJ1h/wnrtdqdX/oFqtDjyyuZjygvA7DNQjkgHiV7tCM2ZUh/AMPc60rff1imgJOuS9JJXYDFAaesYZqcvMaAeTY2UyQQWz4gLHtbHQ6Y2Oaq8fXetA0mivKUYitgfwQDbz6Wh81bQEjXg1j56fuIKi6IzOSILRv0NxgF7508K5CUEpjhg3EWQrl4ZAaZIFM31z7OSJXniJWntqQ== mohammadamine.banaei@pm.me"]
    }

    ip_config {
      ipv4 {
        address = "192.168.1.207/24"
        gateway = "192.168.1.254"
      }
    }
  }

  network_device {
    bridge      = var.pg02_network_bridge
    mac_address = var.pg02_mac_address
  }

  agent {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].size]
  }
}

resource "proxmox_virtual_environment_container" "hermesagent" {
  node_name    = var.pve_node_name
  vm_id        = 101
  unprivileged = var.hermesagent_unprivileged
  started      = true
  tags         = ["agent", "ai", "automation", "community-script"]

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.hermesagent_disk_datastore_id
    # live rootfs size=20G (imported.tf previously said 19 — wrong).
    size = 20
  }

  features {
    nesting = true
    keyctl  = true
  }

  # operating_system.type = "debian" matches live `ostype`, but the
  # provider requires operating_system.template_file_id too (only
  # meaningful at create time via clone) — no value exists for this
  # already-running LXC, so the block is left out rather than guessed.

  initialization {
    hostname = "hermesagent"
  }

  network_interface {
    name        = "eth0"
    bridge      = var.hermesagent_network_bridge
    mac_address = var.hermesagent_mac_address
  }

  lifecycle {
    prevent_destroy = true
    # live `description` is the community-scripts.org install banner
    # (long percent-encoded HTML) — decorative only, not reproduced here
    # to avoid a transcription error silently "fixing" cosmetic text on a
    # production LXC. Ignored so it's never flagged as drift.
    ignore_changes = [description]
  }
}
