# terraform/ — Proxmox VM/LXC provisioning

Terraform (via the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) provider)
for VM/LXC provisioning on `.165` (`192.168.1.165`) only. `.200` (server1)
and `.161` (ex-laptop) are both now reinstalled to PVE and joined `.165`'s
corosync cluster via Ansible (see `ansible/README.md`, ADR-0020,
ADR-0024) — but Terraform itself doesn't provision on them yet, so this
is still a single-host *Terraform* setup even though PVE itself is now a
3-node cluster.

**Cross-host gotcha (ADR-0024):** `variables.tf`'s optional per-node
`datastore_id` isn't set for `server1`, so any future `server1`-targeted
VM falls back to `.165`'s `template_storage_id` via `coalesce` — wrong
for a cross-host VM. Any resource block targeting `server1` must set
`datastore_id: local-lvm` explicitly.

**Cross-host cloning (ADR-0026):** cloning the golden template (VMID
9001) onto a different node than `.165` needed two fixes, both now in
place — see `docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md`
for the full story: `k8s-vms.tf`'s `clone` block now sets `node_name`
(the source node) explicitly, and the template's disk + cloud-init drive
+ vendor-data snippet all moved onto a new `shared-templates` NFS storage
(`nfs.tf`, hosted on a dedicated `nfs-storage` VM on `server1`) so the
provider takes its direct-clone path instead of a slower automatic
clone-then-migrate.

Current topology is **provisional**, laid out to have something concrete to
build against — expect it to change:

| Resource | Type | VMID | Status |
|---|---|---|---|
| `k8s-cp-01` | VM | 201 | new-create, test-phase, no import needed |
| `k8s-worker-01` | VM | 202 | new-create, test-phase, no import needed — carries GPU passthrough directly (`hostpci0`), no separate `k8s-worker-gpu` VM |
| `ubuntu-24.04-ci-template` | VM (template) | 9000 | recreated fresh (see `template.tf`) |
| `garage-storage` | LXC | 301 | test artifact, new-create, direct LXC (download_file + container resource), no script, no import |
| `pg01` | VM | 205 | **real, production — imported, `prevent_destroy`** |
| `pg02` | VM | 207 | **real, production — imported, `prevent_destroy`** |
| `hermesagent` | LXC | 101 | **real, production — imported, `prevent_destroy`** |
| `nfs-storage` | VM | 302 | new-create on `server1`, built directly from cloud image (not cloned) — shared PVE storage, ADR-0026 |
| `k8s-worker-02` | VM | 203 | new-create on `server1`, cloned cross-host from the golden template via `shared-templates` |
| `k9s-dashboard` | LXC | 102 | new-create on `server1`, ops-only convenience box (k9s + kubectl against ukubi-cluster), no application workload, no import needed |
| `k8s-cp-02` | VM | 204 | new-create on `server1`, cloned cross-host — 2nd control-plane/etcd member, ADR-0017 |
| `k8s-cp-03` | VM | 206 | new-create on `ex-laptop`, cloned cross-host — 3rd control-plane/etcd member, ADR-0017 |
| `pg-etcd-witness` | VM | 303 | new-create on `ex-laptop`, cloned cross-host — 3rd Patroni DCS/etcd-only member, no PG data, ADR-0029 |

## Prerequisites (one-time, by hand)

### A. Proxmox API token

Infisical does not currently hold a working `PVE_API_TOKEN` — this must be
created first. On `.165` (PVE shell or SSH as an existing admin):

```bash
pveum user add terraform@pve
pveum role add Terraform -privs "VM.Allocate,VM.Audit,VM.Clone,VM.Config.CDROM,VM.Config.Cloudinit,VM.Config.CPU,VM.Config.Disk,VM.Config.HWType,VM.Config.Memory,VM.Config.Network,VM.Config.Options,VM.Console,VM.Migrate,VM.PowerMgmt,VM.GuestAgent.Audit,VM.GuestAgent.Unrestricted,VM.Snapshot,VM.Snapshot.Rollback,VM.Backup,Datastore.Allocate,Datastore.AllocateSpace,Datastore.AllocateTemplate,Datastore.Audit,Pool.Allocate,Pool.Audit,Sys.Audit,Sys.Console,Sys.Modify,Sys.PowerMgmt,Sys.AccessNetwork,Mapping.Audit,Mapping.Use,SDN.Audit,SDN.Use"
pveum aclmod / -user terraform@pve -role Terraform
pveum user token add terraform@pve provider --privsep=0
```

Copy the printed secret immediately — it's shown once. The provider's
`api_token` value is `terraform@pve!provider=<that secret>`.

This privilege list is a starting point (adapted from the bpg provider's
own example, which they flag as "likely too permissive — review and
adjust"; identity/access-management privileges like `Realm.Allocate` and
`User.Modify` were dropped since they're irrelevant to VM/LXC
provisioning; `VM.Monitor` was dropped too — it doesn't exist as a
privilege name and `pveum role add` rejects it outright). If
`plan`/`apply` ever fails with `Permission check failed`,
that error names the exact missing privilege — add it and move on.

**Known limitation** (documented by bpg, not a bug in this setup): some
operations are hard-restricted to `root@pam` regardless of token
permissions — e.g. changing privileged-container feature flags, setting
`arch`. Relevant to the `hermesagent` import if it's a privileged
container. If you hit `"...only allowed for root@pam"`, that's expected;
the fallback is password auth as `root@pam` for that one operation, not a
role misconfiguration.

### B. SSH credential for node-side operations

The provider's `ssh` block needs a **Linux/PAM account on the PVE host** —
this is a different identity system from the `terraform@pve` PVE-realm API
user in step A, even though they could share a name. Needed for: cloud
image download and template build. (Garage no longer touches this
credential at all — `garage-storage` gets its own dedicated SSH keypair
straight to the LXC, see `garage_ssh_public_key_file` in `variables.tf` and
`ansible/playbooks/garage-configure.yml`.)

For a single-operator homelab, SSH as `root@pam` with a dedicated,
key-only credential is the pragmatic choice (no new Linux user to
provision, `root@pam` already exists). Generate a fresh keypair — don't
reuse `~/.ssh/id_k8s_vms`, that's for cloud-init VM guest access, a
different purpose — and add the public half to `.165`'s
`/root/.ssh/authorized_keys`.

### C. Store both in Infisical

Write both at the project root, per the schema in `docs/secrets.md` (no
folders — everything lives at root):

| Secret | Value |
|---|---|
| `PVE_API_TOKEN` | `terraform@pve!provider=<secret>` from step A |
| `PVE_SSH_PRIVATE_KEY` | private half of the keypair from step B |

## Running Terraform

The bpg provider and this repo's own tooling don't use the same env var
names, so the invocation wrapper renames the two Infisical secrets into the
provider's expected `PROXMOX_VE_*` env vars:

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" \
           PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           terraform -chdir=terraform "$@"' _ plan
```

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in the
non-secret values (storage pool names, node name — see that file's
comments for exactly what to check and how). `terraform.tfvars` holds no
secrets by design, but don't commit your filled-in copy — keep it local.

## First-run order

1. `terraform init` / `terraform validate` — no credentials needed yet.
2. `terraform plan` — before any import, expect "will create" for the
   template/K8s VMs/garage bootstrap, and either "will create" or a
   conflict error for pg01/pg02/hermesagent (useful: confirms the
   hand-written blocks in `imported.tf` point at the right live VMIDs
   before you import).
3. **Import pg01, pg02, hermesagent** — see the safety procedure at the
   top of `imported.tf`. Do not skip the live-config capture step; the
   placeholder variables in that file have no defaults specifically so
   `plan`/`apply` hard-fails until you supply real values, not guesses.
   After each import, `terraform plan -target=<resource>` must show zero
   changes before importing the next one.
4. **Garage**: `garage.tf` creates the bare LXC in one pass — download the
   Debian 12 vztmpl, then create the container directly. No script, no
   `terraform import`, nothing to hand-correct against `pct config`
   afterward. Once it's `started`, hand off to
   `ansible/playbooks/garage-configure.yml` (see `ansible/README.md`) for
   install/config — Terraform's job stops at "bare, SSH-reachable
   container."
   **k9s-dashboard**: `k9s-dashboard.tf` creates the bare LXC the same
   way — no script, no import. Lives on `server1`, not `.165` (user's
   explicit placement choice), so it downloads its own Debian 13 vztmpl
   rather than reusing `garage.tf`'s — `vztmpl` content on "local" storage
   is per-node in Proxmox, not visible across the corosync cluster. Once
   `started`, hand off to `ansible/playbooks/k9s-dashboard-configure.yml`
   (see `ansible/README.md`).
5. **First real `terraform apply` must use `-target`**, scoped only to
   genuinely-new resources:
   ```
   terraform apply \
     -target=proxmox_download_file.ubuntu_2404_cloudimg \
     -target=proxmox_virtual_environment_vm.ubuntu_2404_template \
     -target='proxmox_virtual_environment_vm.k8s_node["k8s-cp-01"]' \
     -target='proxmox_virtual_environment_vm.k8s_node["k8s-worker-01"]' \
     -target=proxmox_download_file.garage_lxc_template \
     -target=proxmox_virtual_environment_container.garage_storage \
     -target=proxmox_download_file.k9s_dashboard_lxc_template \
     -target=proxmox_virtual_environment_container.k9s_dashboard
   ```
   This guarantees pg01/pg02/hermesagent can't be touched by an early,
   broad apply even by accident.
6. After that, a full `terraform plan` (no `-target`) should show `No
   changes.` on pg01/pg02/hermesagent/garage/k9s-dashboard every time —
   that's the ongoing steady-state health check.
7. `k8s-worker-01`'s `hostpci0` block needs a PCI Resource Mapping named
   per `gpu_mapping_name` (default `"gpu"`) — **done** as of 2026-07-14:
   `node=bnei,path=0000:0b:00,id=10de:1e84,iommugroup=2`, covering all 4
   functions of the RTX 2070 SUPER. Created via `pvesh create
   /cluster/mapping/pci` (Datacenter → Resource Mappings → PCI Devices in
   the PVE UI works too). The `hostpci` block uses `mapping`, not a raw
   PCI `id`, because `id` requires root password auth and is incompatible
   with API-token auth. This also required the host to actually have
   `vfio-pci` bound to the device — see `docs/infrastructure-actual.md`'s
   "GPU passthrough" section and `docs/bootstrap-test-notes.md`'s
   2026-07-14 entry for what that took (AMD-Vi was disabled in BIOS, plus
   a systemd unit to force the binding reliably).
8. `cloud-init.tf`'s `qemu_guest_agent_vendor_data` snippet (installs and
   starts `qemu-guest-agent` on every K8s VM clone — see
   `docs/bootstrap-test-notes.md`'s 2026-07-12 entry for why this matters:
   without it, every clone's `apply` eats a 15-minute non-fatal wait)
   needs the `snippets` content type enabled once by hand on whichever
   storage `template_download_storage_id` points at (default `"local"`):
   ```bash
   pvesm set local --content vztmpl,import,iso,backup,snippets
   ```
   Metadata-only, reversible, doesn't touch existing files on that
   storage. Same one-time-prereq pattern as the GPU mapping above.
9. Once VMs boot: `ssh -i ~/.ssh/id_k8s_vms core@192.168.1.201` (etc.) to
   confirm cloud-init actually worked before handing off to kubespray.

## Shared storage for cross-host cloning (Stage 2, ADR-0026)

Needed once before the first `k8s_nodes` entry targeting `server1`/
`ex-laptop` (e.g. `k8s-worker-02`) — see
`docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md` for the why.

1. `terraform apply -target=proxmox_download_file.nfs_vm_cloudimg
   -target=proxmox_virtual_environment_file.nfs_vm_vendor_data
   -target=proxmox_virtual_environment_vm.nfs_storage` — bare,
   SSH-reachable VM only, same "Terraform stops at bare" split as
   `garage.tf`. The vendor-data snippet must be targeted alongside the VM,
   not applied separately after — `agent.enabled = true` makes `apply`
   wait on a qemu-guest-agent handshake that never arrives if the snippet
   installing it isn't there at first boot (confirmed by testing).
2. `ansible-playbook -i ansible/inventories/nfs/hosts.yml
   -i ansible/inventories/proxmox/hosts.yml
   ansible/playbooks/nfs-configure.yml` — formats the export disk,
   installs and configures `nfs-kernel-server`, **and** registers
   `shared-templates` as a PVE storage pool (idempotent — the second play
   only runs `pvesm add` if it isn't already registered). `storage.cfg` is
   cluster-shared (ADR-0020), so this only needs one PVE host regardless
   of node count.
3. `terraform plan` — expect only the golden template's disk +
   cloud-init drive moving onto `shared-templates`; `apply` once
   confirmed.
4. From here, any new `k8s_nodes` entry with `node_name` set to
   `server1`/`ex-laptop` clones directly via `shared-templates` instead
   of the automatic clone-then-migrate fallback.

## Out of scope here

- `.161` (ex-laptop) — corosync-clustered with `.165`/`server1` since
  ADR-0020, but no `k8s_nodes`/`nfs.tf` resource targets it yet. The
  single-provider-block pattern (`node_name`/`datastore_id` per resource,
  no provider aliasing needed) already extends there the same way it did
  to `server1` — just not exercised yet.
- Installing kubespray/Pigsty on top of the VMs this creates — that's the
  next, already-planned step, done via the existing `ansible-ops` skill.
