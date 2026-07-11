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
  description = "VMID of the golden Ubuntu 24.04 cloud-init template that K8s VMs clone from."
  type        = number
  default     = 9000
}

variable "template_storage_id" {
  description = "PVE storage pool the template's disk and cloud-init drive live on."
  type        = string
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

variable "pve_host" {
  description = "Bare IP/hostname of the PVE host, for the null_resource SSH connection block (provisioner connections don't inherit the provider's ssh {} config)."
  type        = string
  default     = "192.168.1.165"
}

variable "pve_ssh_private_key" {
  description = "Same key as PROXMOX_VE_SSH_PRIVATE_KEY, passed separately via TF_VAR_pve_ssh_private_key — provisioner connection blocks can't read the provider's ssh {} credentials."
  type        = string
  sensitive   = true
}

variable "garage_template_file_id" {
  description = <<-EOT
    REQUIRED, no default on purpose: the LXC OS template asset
    garage.sh's bootstrap actually used (e.g.
    "local:vztmpl/debian-13-standard_13.x-y_amd64.tar.zst"). Unknowable
    ahead of time — read it from `pct config 301` after
    null_resource.garage_bootstrap runs, before `terraform import`ing
    proxmox_virtual_environment_container.garage_storage. Don't guess the
    exact version substring.
  EOT
  type        = string
}

variable "gpu_mapping_name" {
  description = <<-EOT
    Name of the PVE PCI Resource Mapping (Datacenter -> Resource Mappings)
    pointing at the RTX 2070 SUPER, used by k8s-worker-gpu's hostpci block.
    Must be created once by hand on .165 before this VM's first apply —
    hostpci's raw `id` attribute requires root password auth and is
    incompatible with API-token auth, so `mapping` is used instead.
  EOT
  type        = string
  default     = "gpu"
}
