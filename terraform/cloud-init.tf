# Two concerns bundled into one vendor-data snippet, shared by both k8s VMs
# (cp01/worker01 each set vendor_data_file_id to this resource):
#
# 1. qemu-guest-agent isn't in Ubuntu's stock 24.04 cloud image. Without
#    it, every VM clone's agent { enabled = true } block makes apply wait
#    out the full 15-minute agent timeout (non-fatal, but slow) — see
#    docs/bootstrap-test-notes.md's 2026-07-12 entry.
# 2. Each VM's second disk (scsi1, var.longhorn_disk_size_gb) ships
#    raw/unformatted — format + mount it at /var/lib/longhorn on every
#    boot (idempotent) so Longhorn's wave-0 GitOps sync has a disk to use
#    without a separate ansible step.
#
# This layers on top of each VM's auto-generated user_account/ip_config
# cloud-init (vendor_data_file_id doesn't replace them, unlike
# user_data_file_id, which would).
#
# Prerequisite, once by hand on .165 (proxmox_virtual_environment_file
# can't create it — content-type support is a storage-level PVE setting):
#   pvesm set local --content import,backup,vztmpl,iso,snippets

resource "proxmox_virtual_environment_file" "k8s_vm_vendor_data" {
  content_type = "snippets"
  datastore_id = var.template_download_storage_id
  node_name    = var.pve_node_name

  source_raw {
    file_name = "k8s-vm-vendor-data.yaml"
    data      = local.k8s_vm_vendor_data_content
  }
}

# Identical content, but on shared-templates (NFS, docs/adr/0026) instead
# of .165's node-local "local" storage. Every PVE node has its own
# separately-named "local" storage, so a server1-hosted k8s_nodes entry
# (e.g. k8s-worker-02) would resolve vendor_data_file_id against server1's
# *own* (empty) local storage at boot and never find a file that only
# physically exists on .165 — silently losing the qemu-guest-agent install
# + Longhorn disk auto-format this snippet provides.
#
# Deliberately a SEPARATE resource from k8s_vm_vendor_data above, not a
# repoint of its datastore_id: vendor_data_file_id is a ForceNew attribute
# on proxmox_virtual_environment_vm, confirmed via a real `terraform plan`
# that changing the shared snippet's location marks every VM referencing
# it — including the already-live k8s-cp-01/k8s-worker-01 — "must be
# replaced". k8s-vms.tf picks whichever of these two resources matches
# each entry's actual node, so same-host entries keep pointing at the
# original, byte-for-byte-unchanged resource below.
#
# Prerequisite, once by hand (docs/adr/0026 / terraform/README.md): the
# shared-templates NFS storage must be registered with content type
# "snippets" alongside "images" before this resource's first apply.
resource "proxmox_virtual_environment_file" "k8s_vm_vendor_data_shared" {
  content_type = "snippets"
  datastore_id = var.template_shared_storage_id
  node_name    = var.pve_node_name

  source_raw {
    file_name = "k8s-vm-vendor-data.yaml"
    data      = local.k8s_vm_vendor_data_content
  }
}

locals {
  k8s_vm_vendor_data_content = <<-EOT
    #cloud-config
    packages:
      - qemu-guest-agent
    runcmd:
      - systemctl enable --now qemu-guest-agent
    bootcmd:
      - |
        if [ -b /dev/sdb ]; then
          blkid /dev/sdb | grep -q TYPE= || mkfs.ext4 -L longhorn /dev/sdb
          mkdir -p /var/lib/longhorn
          grep -q "/var/lib/longhorn" /etc/fstab || \
            echo "LABEL=longhorn /var/lib/longhorn ext4 defaults 0 2" >> /etc/fstab
          mount -a
        fi
  EOT
}
