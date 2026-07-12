# terraform/ — Proxmox VM/LXC provisioning

Terraform (via the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest) provider)
for VM/LXC provisioning on `.165` (`192.168.1.165`), the only currently-live
Proxmox host. `.200` and `.161` still need a PVE reinstall — this isn't a
multi-host setup yet.

Current topology is **provisional**, laid out to have something concrete to
build against — expect it to change:

| Resource | Type | VMID | Status |
|---|---|---|---|
| `k8s-cp-01` | VM | 201 | new-create, test-phase, no import needed |
| `k8s-worker-01` | VM | 202 | new-create, test-phase, no import needed |
| `k8s-worker-gpu` | VM | 203 | new-create, test-phase, GPU passthrough |
| `ubuntu-24.04-ci-template` | VM (template) | 9000 | recreated fresh (see `template.tf`) |
| `garage-storage` | LXC | 301 | test artifact, destroyed + rebuilt via community script, then imported |
| `pg01` | VM | 205 | **real, production — imported, `prevent_destroy`** |
| `pg02` | VM | 207 | **real, production — imported, `prevent_destroy`** |
| `hermesagent` | LXC | 101 | **real, production — imported, `prevent_destroy`** |

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
image download, template build, and running the garage.sh installer.

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
names, and provisioner `connection` blocks can't inherit the provider's
`ssh {}` credentials — so the invocation wrapper sets three env vars from
the same two Infisical secrets:

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" \
           PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           TF_VAR_pve_ssh_private_key="$PVE_SSH_PRIVATE_KEY" \
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
4. **Garage**: `garage.tf`'s `null_resource.garage_bootstrap` destroys the
   old test container and reruns the community-scripts.org installer (use
   the [generator](https://community-scripts.org/generator) to verify the
   exact `var_*` set before trusting the inline command). After it runs,
   read `pct config <ctid>` and correct `garage.tf`'s
   `proxmox_virtual_environment_container` block to match before
   `terraform import`-ing it too.
5. **First real `terraform apply` must use `-target`**, scoped only to
   genuinely-new resources:
   ```
   terraform apply \
     -target=proxmox_download_file.ubuntu_2404_cloudimg \
     -target=proxmox_virtual_environment_vm.ubuntu_2404_template \
     -target=proxmox_virtual_environment_vm.k8s_cp_01 \
     -target=proxmox_virtual_environment_vm.k8s_worker_01 \
     -target=proxmox_virtual_environment_vm.k8s_worker_gpu \
     -target=null_resource.garage_bootstrap \
     -target=proxmox_virtual_environment_container.garage_storage
   ```
   This guarantees pg01/pg02/hermesagent can't be touched by an early,
   broad apply even by accident.
6. After that, a full `terraform plan` (no `-target`) should show `No
   changes.` on pg01/pg02/hermesagent/garage every time — that's the
   ongoing steady-state health check.
7. `k8s-worker-gpu` additionally needs a PCI Resource Mapping named per
   `gpu_mapping_name` (default `"gpu"`) created once by hand — Datacenter
   → Resource Mappings → PCI Devices in the PVE UI, or `pvesh create`. The
   `hostpci` block uses `mapping`, not a raw PCI `id`, because `id` requires
   root password auth and is incompatible with API-token auth. Re-verify
   the RTX 2070 SUPER's PCI address with `lspci -nn | grep -i nvidia`
   before creating the mapping — addressing can shift between boots.
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

## Out of scope here

- `inventory/ukubi/hosts.yaml`, `ARCHITECTURE.md`, `DECISION.md`,
  `CLAUDE.md`, `ansible/README.md`, and skill files are **not** touched
  by this work — update them separately if/when this setup is adopted as
  the new locked provisioning method.
- `.200`/`.161` — no multi-host abstraction until those hosts actually run
  PVE.
- Installing kubespray/Pigsty on top of the VMs this creates — that's the
  next, already-planned step, done via the existing `ansible-ops` skill.
