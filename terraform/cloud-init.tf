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
# datastore_id is template_shared_storage_id (NFS, docs/adr/0026), not
# template_download_storage_id (.165's local "snippets" storage) — every
# PVE node has its own separately-named "local" storage, so a
# server1-hosted k8s_nodes entry (e.g. k8s-worker-02) would resolve
# vendor_data_file_id against server1's *own* local storage at boot and
# never find a file that only physically exists on .165, silently losing
# the qemu-guest-agent install + Longhorn disk auto-format this snippet
# provides. Shared NFS storage is visible under the same name from every
# node, so this only needs to exist once.
#
# Prerequisite, once by hand (docs/adr/0026 / terraform/README.md): the
# shared-templates NFS storage must be registered with content type
# "snippets" alongside "images" before this resource's first apply.

resource "proxmox_virtual_environment_file" "k8s_vm_vendor_data" {
  content_type = "snippets"
  datastore_id = var.template_shared_storage_id
  node_name    = var.pve_node_name

  source_raw {
    file_name = "k8s-vm-vendor-data.yaml"
    data      = <<-EOT
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
}
