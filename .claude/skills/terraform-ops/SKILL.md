---
name: terraform-ops
description: Build the correct Infisical-wrapped terraform command for the terraform/ Proxmox VM/LXC provisioning setup (across the 3-node PVE cluster — .165/.200/.161). Use when the user asks how to run terraform plan/apply/import, or wants a command constructed/explained (not run unattended).
user-invocable: true
allowed-tools:
  - Read
  - Bash(terraform -chdir=terraform init *)
  - Bash(terraform -chdir=terraform validate)
  - Bash(terraform -chdir=terraform fmt -check *)
  - Bash(terraform -chdir=terraform plan *)
---

# /terraform-ops — terraform/ Proxmox provisioning helper

`terraform/README.md` is the source of truth for setup and invocation —
this skill builds/explains commands against it, it does not re-derive the
procedure from scratch each time, and it does not execute anything that
mutates real infrastructure. It is not the "Hermes agent" described in
`DECISION.md` §2.

## Scope

`terraform/` provisions VMs/LXCs across the 3-node PVE cluster: `.165`
(primary — pg01/pg02/hermesagent/garage, plus the only template, VMID
9001, all still live there only), `.200` (server1), and `.161`
(ex-laptop). All three are PVE and joined via corosync (ADR-0020);
`.200`/`.161` were reinstalled to PVE per ADR-0024. Cross-host `k8s_nodes`
entries set `node_name`/`datastore_id` explicitly, confirmed via live
`pvesh get /nodes` / `pvesm status` on the target node, never guessed —
see `terraform.tfvars.example`'s worked example and the live
`k8s-worker-02` entry in `terraform.tfvars` (server1) for the pattern.
Since the template only exists on `.165`, cross-host VM creation
clone-then-migrates unless `docs/adr/0026`'s shared-templates NFS pool is
set up first (confirmed live/mounted on all 3 hosts as of 2026-07-30).
Both `server1` and `ex-laptop` now carry real VMs — `k8s-cp-02`
(server1, `.204`) and `k8s-cp-03` (ex-laptop, `.206`), the 2nd/3rd
control-plane+etcd members (ADR-0017), on top of the earlier
`k8s-worker-02` (server1) and `nfs-storage` (server1). `ex-laptop`'s
sleep-risk mitigation is applied (ADR-0013) and it's now proven reliable
enough in practice to host a real HA voter, not just best-effort
capacity.

`pg-etcd-witness.tf` (2026-07-30) adds a small dedicated VM on
`ex-laptop` (`.197`, vm_id 303) — a 3rd, etcd-only Patroni DCS member,
mirroring ADR-0017's quorum logic for Postgres (ADR-0029). Applied and
joined the same day — real 3-node etcd quorum is live. A live check
that day also found `pg01`(`.205`)/`pg02`(`.207`)'s
actual Patroni roles are swapped from every doc (`.207` is the current
Leader) — Terraform doesn't care about Patroni role, only VM specs, so no
`imported.tf` change was needed for that, just docs (`ARCHITECTURE.md`,
`DECISION.md`, `pigsty.yml`'s own comments).

## Invocation pattern (from `terraform/README.md`)

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" \
           PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           TF_VAR_pve_ssh_private_key="$PVE_SSH_PRIVATE_KEY" \
           terraform -chdir=terraform "$@"' _ <subcommand>
```

If `PVE_API_TOKEN`/`PVE_SSH_PRIVATE_KEY` aren't in Infisical yet, that's the
blocker — point at `terraform/README.md`'s "Prerequisites" section (PVE
role/token creation, SSH credential) rather than guessing a workaround.

## What's safe to actually execute here

Read-only / no-mutation, and only if the user asks for a live check:
- `terraform -chdir=terraform init` / `validate` / `fmt -check` — no
  credentials needed for `validate`/`fmt`.
- `terraform -chdir=terraform plan` (with the Infisical wrapper) —
  read-only against the Proxmox API, doesn't change anything.

## What requires the user to run it themselves

Anything that mutates real infra or Terraform state:
- `terraform apply` — always. The **first** apply in this project must use
  `-target` scoped to net-new resources only (see `terraform/README.md`
  step 5) — if the user asks for a broad `apply` before pg01/pg02/hermesagent
  have been imported and verified zero-diff, flag that before printing the
  command.
- `terraform import` — especially `proxmox_virtual_environment_vm.pg01`,
  `.pg02`, and `proxmox_virtual_environment_container.hermesagent`. These
  are **real, production, actively-used** resources
  (`terraform/imported.tf`'s header comment). Never suggest running their
  import without the live-config-capture + per-resource zero-diff `plan
  -target=` gate documented there first. The placeholder variables in
  `imported.tf` (disk datastore, network bridge, MAC address) have no
  defaults on purpose — if they're still unset, importing is not ready yet,
  say so rather than proposing a workaround value.
- `terraform destroy`, `terraform state rm/mv`, `terraform taint` — always
  the user's call, explain the consequence, don't run it.
- The `garage-storage` container (`proxmox_download_file.garage_lxc_template`
  + `proxmox_virtual_environment_container.garage_storage` in `garage.tf`)
  creates a bare Debian LXC directly — no script, no destroy-first, nothing
  interactive. Still an `apply` like any other, same rule as above. Garage's
  actual install/config happens afterward via
  `ansible/playbooks/garage-configure.yml`, not Terraform.

For anything in this list: print the exact command (with the Infisical
wrapper), explain what it will do and which `DECISION.md`/`terraform/README.md`
constraint it touches, and stop. Only proceed if the user explicitly says
to run it now in this session.

## Known gotchas worth surfacing proactively

- **`local_file.kubespray_inventory` doesn't regenerate from a `-target`ed
  apply.** It's a sibling resource to the VM (both depend on
  `var.k8s_nodes`, neither depends on the other) — a `-target`-scoped
  apply for a new `k8s_nodes` entry (recommended, to avoid touching
  already-live nodes) creates the VM but leaves `inventory/ukubi/
  hosts.yaml` stale, silently. Before handing off a `cluster.yml` command
  for a freshly-added node, check
  `terraform plan -target=local_file.kubespray_inventory` first — hit
  this twice already (2026-07-28, 2026-07-30), it's a repeatable footgun
  of the `-target`-for-safety pattern, not a one-off.
- `k8s-worker-gpu`'s `hostpci` block uses a PCI Resource `mapping`, not a
  raw PCI `id` — `id` requires root-password auth and breaks under the
  token-based provider config here. If asked about GPU passthrough errors,
  check whether the `gpu_mapping_name` mapping actually exists on `.165`
  first.
- Some LXC operations (privileged-container feature flags, `arch`) are
  hard-restricted to `root@pam` regardless of API token permissions — a
  documented bpg provider limitation, not a role misconfiguration. See
  `terraform/README.md`'s "Known limitation" note before assuming the
  token's role is broken.
