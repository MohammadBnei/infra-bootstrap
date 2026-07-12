# qemu-guest-agent isn't in Ubuntu's stock 24.04 cloud image. Without it,
# every VM clone's agent { enabled = true } block makes apply wait out the
# full 15-minute agent timeout (non-fatal, but slow) — see
# docs/bootstrap-test-notes.md's 2026-07-12 entry. This vendor-data snippet
# layers on top of each VM's auto-generated user_account/ip_config
# cloud-init (vendor_data_file_id doesn't replace them, unlike
# user_data_file_id, which would).
#
# Prerequisite, once by hand on .165 (proxmox_virtual_environment_file
# can't create it — content-type support is a storage-level PVE setting):
#   pvesm set local --content import,backup,vztmpl,iso,snippets

resource "proxmox_virtual_environment_file" "qemu_guest_agent_vendor_data" {
  content_type = "snippets"
  datastore_id = var.template_download_storage_id
  node_name    = var.pve_node_name

  source_raw {
    file_name = "qemu-guest-agent.yaml"
    data      = <<-EOT
      #cloud-config
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    EOT
  }
}
