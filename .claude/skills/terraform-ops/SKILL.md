---
name: terraform-ops
description: Build the correct Infisical-wrapped terraform command for the terraform/ Proxmox VM/LXC provisioning setup. Use when the user asks how to run terraform plan/apply/import against .165, or wants a command constructed/explained (not run unattended).
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

`terraform/` provisions VMs/LXCs on `.165` only (`192.168.1.165` — the only
currently-live Proxmox host). `.200`/`.161` aren't PVE yet; don't suggest
Terraform changes for them.

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
- The `garage-storage` bootstrap (`null_resource.garage_bootstrap` in
  `garage.tf`) runs a community-scripts.org installer over SSH and destroys
  the existing test container first — mutating, so it's an `apply` like any
  other, same rule as above.

For anything in this list: print the exact command (with the Infisical
wrapper), explain what it will do and which `DECISION.md`/`terraform/README.md`
constraint it touches, and stop. Only proceed if the user explicitly says
to run it now in this session.

## Known gotchas worth surfacing proactively

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
