variable "pve_endpoint" {
  description = "Proxmox VE API endpoint. Scoped to .165 only — the other 2 target hosts (.200, .161) aren't PVE yet."
  type        = string
  default     = "https://192.168.1.165:8006/"
}

variable "pve_node_name" {
  description = "Internal PVE node name (NOT necessarily the DNS hostname) — confirm via `pvesh get /nodes` before first apply."
  type        = string
}

variable "pve_insecure" {
  description = "Skip TLS verification for the self-signed PVE cert on the LAN."
  type        = bool
  default     = true
}

variable "k8s_vm_ssh_public_key_file" {
  description = "Path to the public half of the K8s VM cloud-init SSH key (MISSION.md §3 — separate from the PVE-host SSH credential)."
  type        = string
  default     = "~/.ssh/id_k8s_vms.pub"
}

variable "template_vm_id" {
  description = <<-EOT
    VMID of the golden Ubuntu 24.04 cloud-init template that K8s VMs clone
    from. Set to 9001, not the original 9000 — the 2026-07-12 smoke test
    (docs/bootstrap-test-notes.md) built 9001 fresh with the
    qemu-guest-agent vendor-data fix already wired in via cloud-init.tf,
    and it's now the one actually tracked in Terraform state. The original
    9000 (created by hand, pre-Terraform, no guest-agent fix) still exists
    on .165, stopped, unmanaged by this state — left in place as a spare,
    not deleted. Safe to remove by hand once 9001 is confirmed good for
    the real bootstrap.
  EOT
  type        = number
  default     = 9001
}

variable "template_storage_id" {
  description = "PVE storage pool the template's disk and cloud-init drive live on."
  type        = string
}

variable "template_download_storage_id" {
  description = <<-EOT
    PVE storage pool for file-based content: proxmox_download_file's cloud
    image staging (content type "import") and the cloud-init vendor-data
    snippet in cloud-init.tf (content type "snippets"). Must be file-based
    (e.g. a "dir" storage) — LVM-thin pools like local-lvm only support
    "images"/"rootdir" and reject both "import" and "snippets". Confirmed
    via `pvesh get /storage` on .165 that "local" (dir) supports
    import,backup,vztmpl,iso — "snippets" must be added once by hand
    (`pvesm set local --content <existing-list>,snippets`) before first
    apply of cloud-init.tf, same one-time-prereq pattern as
    gpu_mapping_name. Separate from template_storage_id, which is where
    the VM disk itself (block storage, e.g. local-lvm) ends up after
    import.
  EOT
  type        = string
  default     = "local"
}

variable "gateway_ipv4" {
  description = "LAN gateway for static VM/LXC IPs."
  type        = string
  default     = "192.168.1.254"
}

variable "garage_container_storage" {
  description = "NVMe-backed PVE storage pool for the garage-storage LXC disk — confirm exact name via `pvesm status` (docs/infrastructure-desired.md says NVMe-backed but doesn't name the pool)."
  type        = string
}

variable "garage_ip" {
  description = "Static IP for garage-storage. No VMID/IP was locked for it anywhere in MISSION.md/docs — pick one on first apply and treat as provisional per the plan's topology note."
  type        = string
}

variable "garage_ct_id" {
  description = "VMID/CTID for the recreated garage-storage container."
  type        = number
  default     = 301
}

variable "garage_ssh_public_key_file" {
  description = "Path to the public half of garage-storage's dedicated SSH key — a new, separate keypair from PVE-host/k8s-VM credentials (different blast radius: one app LXC, not a whole host or VM fleet). Consumed by ansible/playbooks/garage-configure.yml."
  type        = string
  default     = "~/.ssh/id_garage.pub"
}

variable "nfs_storage_id" {
  description = "PVE storage pool on server1 for the nfs-storage VM's own disks — confirm via `pvesm status` on server1 before first apply (ADR-0024: server1 has no ZFS pool, VM/LXC disks land on local-lvm like .165, but don't assume the name matches — confirm live)."
  type        = string
}

variable "nfs_ip" {
  description = "Static IP for the nfs-storage VM (server1). No VMID/IP was locked for it anywhere else — pick one on first apply and treat as provisional, same precedent as garage_ip."
  type        = string
}

variable "nfs_vm_id" {
  description = "VMID for the nfs-storage VM."
  type        = number
  default     = 302
}

variable "nfs_k8s_disk_size_gb" {
  description = "GB size for nfs-storage's scsi2 disk — the K8s PV export (/export/k8s), backing the unreplicated `nfs` StorageClass (ADR-0036). Kept separate from scsi1's template storage on purpose. Confirm server1's local-lvm free space with `pvesm status` before raising this; unlike Longhorn there is no replication overhead, so 1GB here is 1GB of usable PV."
  type        = number
  default     = 200
}

variable "nfs_ssh_public_key_file" {
  description = "Path to the public half of nfs-storage's dedicated SSH key — new, separate keypair from PVE-host/k8s-VM/garage credentials (own blast radius: one storage VM). Consumed by ansible/playbooks/nfs-configure.yml."
  type        = string
  default     = "~/.ssh/id_nfs.pub"
}

variable "pg_etcd_witness_vm_id" {
  description = "VMID for the pg-etcd-witness VM (ex-laptop) — 3rd Patroni DCS/etcd-only member, ADR-0029."
  type        = number
  default     = 303
}

variable "pg_etcd_witness_ip" {
  description = "Static IP for pg-etcd-witness. No VMID/IP was locked for it anywhere else — pick one on first apply and treat as provisional, same precedent as garage_ip/nfs_ip."
  type        = string
  default     = "192.168.1.197"
}

variable "pg_etcd_witness_ssh_public_key_file" {
  description = "Path to the public half of pg-etcd-witness's dedicated SSH key — new, separate keypair (own blast radius: one DCS-only VM, no PG data). Consumed by whatever ansible step joins it to Pigsty's etcd cluster."
  type        = string
  default     = "~/.ssh/id_pg_etcd_witness.pub"
}

variable "template_shared_storage_id" {
  description = <<-EOT
    PVE storage pool for the golden template's (VMID 9001) disk +
    cloud-init drive — must be a *shared* storage (docs/adr/0026) so
    k8s-vms.tf's cross-node clone takes the provider's direct-clone path
    instead of the slower clone-then-migrate fallback. Deliberately
    separate from template_storage_id, which stays the coalesce fallback
    for k8s_nodes entries that don't set their own datastore_id — do not
    point that variable at shared storage, it would also try to move
    k8s-cp-01/k8s-worker-01's already-working local-lvm disks.
  EOT
  type        = string
}

variable "longhorn_disk_size_gb" {
  description = <<-EOT
    Fallback GB size for a k8s VM's dedicated Longhorn data disk (scsi1)
    when a k8s_nodes entry doesn't set its own longhorn_disk_size_gb.
    ADR-0019 resolved per-VM sizing for Stage 1 (platform apps + searxng/
    pgweb only, no legacy NFS data carried over yet — that inventory
    happens per-app as each one is migrated later): default to roughly
    the same size as the OS disk, sized up when a specific app's data
    volume is known.
  EOT
  type        = number
  default     = 50
}

variable "gpu_mapping_name" {
  description = <<-EOT
    Name of the PVE PCI Resource Mapping (Datacenter -> Resource Mappings)
    pointing at the RTX 2070 SUPER, used by k8s-worker-01's hostpci block.
    Must be created once by hand on .165 before this VM's first apply —
    hostpci's raw `id` attribute requires root password auth and is
    incompatible with API-token auth, so `mapping` is used instead.
  EOT
  type        = string
  default     = "gpu"
}

variable "k8s_nodes" {
  description = <<-EOT
    K8s VM topology, keyed by node name. This is the one place to change
    a node's CPU/memory/disk, add/remove a node, or flip its
    control-plane/etcd/worker/gpu role — k8s-vms.tf and the generated
    kubespray inventory (hosts-inventory.tf) both derive from this map.
    Default reproduces the current 2-node topology exactly
    (ARCHITECTURE.md §2) so `terraform plan` shows zero diff right after
    this variable is introduced.

    node_name/datastore_id are optional, defaulting (via coalesce in
    k8s-vms.tf) to var.pve_node_name/var.template_storage_id — i.e. ".165"
    — so existing entries need not set them. Once `.200`/`.161` join the
    PVE cluster (see docs/adr/0020-pve-corosync-cluster.md), new worker
    entries for them set these explicitly, confirmed from live
    `pvesh get /nodes` / `pvesm status` output, never guessed — see
    terraform.tfvars.example.
  EOT
  type = map(object({
    vm_id                 = number
    ip                    = string
    cpu_cores             = number
    memory_dedicated_mb   = number
    os_disk_size_gb       = number
    longhorn_disk_size_gb = optional(number)
    control_plane         = bool
    etcd                  = bool
    worker                = bool
    gpu                   = bool
    node_name             = optional(string)
    datastore_id          = optional(string)
  }))
  default = {
    "k8s-cp-01" = {
      vm_id                 = 201
      ip                    = "192.168.1.201"
      cpu_cores             = 2
      memory_dedicated_mb   = 4096
      os_disk_size_gb       = 40
      longhorn_disk_size_gb = 40
      control_plane         = true
      etcd                  = true
      worker                = true
      gpu                   = false
    }
    "k8s-worker-01" = {
      vm_id                 = 202
      ip                    = "192.168.1.202"
      cpu_cores             = 6
      memory_dedicated_mb   = 15360
      os_disk_size_gb       = 100
      longhorn_disk_size_gb = 100
      control_plane         = false
      etcd                  = false
      worker                = true
      gpu                   = true
    }
  }
}

variable "network_bridge" {
  description = "PVE bridge for k8s VM network_device — single flat LAN today (ARCHITECTURE.md §3), one bridge for all nodes."
  type        = string
  default     = "vmbr0"
}

variable "network_cidr_prefix" {
  description = "CIDR prefix for k8s VM static IPs (gateway_ipv4 above supplies the gateway)."
  type        = number
  default     = 24
}

variable "k8s_vm_ssh_private_key_file" {
  description = <<-EOT
    Path to the private half of the K8s VM cloud-init SSH key — used only
    to render `ansible_ssh_private_key_file` into the generated kubespray
    inventory (hosts-inventory.tf); never read by Terraform itself (no
    `file()` call). Sibling of k8s_vm_ssh_public_key_file, which IS read
    by Terraform to seed each VM's authorized key.
  EOT
  type        = string
  default     = "~/.ssh/id_k8s_vms"
}

variable "k9s_dashboard_container_storage" {
  description = "PVE storage pool for the k9s-dashboard LXC disk — confirm exact name via `pvesm status`. Fine to reuse the same pool as garage_container_storage; this box is tiny (8GB, negligible I/O)."
  type        = string
}

variable "k9s_dashboard_ip" {
  description = "Static IP for k9s-dashboard. No VMID/IP was locked for it anywhere in MISSION.md/docs — pick one on first apply and treat as provisional, same precedent as garage_ip/nfs_ip."
  type        = string
}

variable "k9s_dashboard_ct_id" {
  description = "VMID/CTID for the k9s-dashboard container."
  type        = number
  default     = 102
}

variable "k9s_dashboard_ssh_public_key_file" {
  description = "Path to the public half of k9s-dashboard's dedicated SSH key — a new, separate keypair from PVE-host/k8s-VM/garage/nfs credentials (own blast radius: this box carries a live cluster-admin-scoped kubeconfig on disk). Consumed by ansible/playbooks/k9s-dashboard-configure.yml."
  type        = string
  default     = "~/.ssh/id_k9s_dashboard.pub"
}

variable "build_runner_container_storage" {
  description = "PVE storage pool for the build-runner LXC disk — confirm exact name via `pvesm status`. Unlike k9s-dashboard this box does real I/O (image pulls, layer extraction), so prefer the NVMe-backed pool."
  type        = string
}

variable "build_runner_ip" {
  description = "Static IP for build-runner. 192.168.1.111 is unused (ARCHITECTURE.md §3's .100-.199 LXC range) and suggested; treat as provisional, same precedent as garage_ip/k9s_dashboard_ip. Must also be added to pihole_hosts_records if anything needs to resolve it by name."
  type        = string
}

variable "build_runner_ct_id" {
  description = "VMID/CTID for the build-runner container."
  type        = number
  default     = 103
}

variable "build_runner_ssh_public_key_file" {
  description = "Path to the public half of build-runner's dedicated SSH key — its own keypair, separate from every other box's. Blast radius worth keeping distinct: this container executes app-repo Dockerfiles and holds a GitHub PAT with repo administration. Consumed by ansible/playbooks/build-runner-configure.yml."
  type        = string
  default     = "~/.ssh/id_build_runner.pub"
}

variable "pihole_ip" {
  description = "Pi-hole's IP, injected as the LXC nameserver. Set explicitly because Proxmox statically writes /etc/resolv.conf at the LXC level and bypasses DHCP-handed DNS — k9s-dashboard was debugged into this the hard way (docs/bootstrap-test-notes.md). Anything needing to resolve *.bnei.lan needs it."
  type        = string
  default     = "192.168.1.55"
}
