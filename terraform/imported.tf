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

resource "proxmox_virtual_environment_vm" "pg01" {
  name      = "pg01"
  node_name = var.pve_node_name
  vm_id     = 205
  started   = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.pg01_disk_datastore_id
    interface    = "scsi0"
    size         = 40
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
  }
}

resource "proxmox_virtual_environment_vm" "pg02" {
  name      = "pg02"
  node_name = var.pve_node_name
  vm_id     = 207
  started   = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.pg02_disk_datastore_id
    interface    = "scsi0"
    size         = 40
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
  }
}

resource "proxmox_virtual_environment_container" "hermesagent" {
  node_name    = var.pve_node_name
  vm_id        = 101
  unprivileged = var.hermesagent_unprivileged
  started      = true

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = var.hermesagent_disk_datastore_id
    size         = 19
  }

  network_interface {
    name        = "eth0"
    bridge      = var.hermesagent_network_bridge
    mac_address = var.hermesagent_mac_address
  }

  lifecycle {
    prevent_destroy = true
  }
}
