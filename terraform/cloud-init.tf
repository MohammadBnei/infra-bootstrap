# Two concerns bundled into one vendor-data snippet, shared by all three
# k8s VMs (cp01/worker01/worker-gpu each set vendor_data_file_id to this
# resource):
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
