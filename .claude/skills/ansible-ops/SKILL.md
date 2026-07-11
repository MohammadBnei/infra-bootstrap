---
name: ansible-ops
description: Build the correct Infisical-wrapped ansible/kubespray/pigsty command for this repo. Use when the user asks how to run kubespray, pigsty, or an ansible playbook against ukubi-cluster, or wants a command constructed/explained (not run unattended).
user-invocable: true
allowed-tools:
  - Read
  - Bash(ansible --version)
  - Bash(ansible -i * -m ping)
  - Bash(ansible-playbook -i * --list-tasks *)
  - Bash(ansible-playbook -i * --check --diff *)
---

# /ansible-ops — ansible/kubespray/pigsty operations helper

This repo's own `README.md` is explicit: "You run the actual tool
(`ansible-playbook`, `kubespray`, `pigsty`) on your Mac against this
repo." This skill **builds and explains commands, it does not execute
anything that mutates real infrastructure.** It is not the "Hermes agent"
described in MISSION.md §12.

## Which tool, which playbook

- **Kubespray** — `kubespray/cluster.yml` (submodule). Greenfield bootstrap
  always uses `cluster.yml`, **never `scale.yml`** (MISSION.md §12 —
  `scale.yml` skips the control-plane join role). Invoked against
  `inventory/ukubi/hosts.yaml`.
- **Pigsty** — vendored in `pigsty/`, its own playbooks (`deploy.yml`,
  `pgsql.yml`, `node.yml`, etc.) and its own `pigsty/CLAUDE.md`/
  `pigsty/README.md`. For Pigsty-specific flag or playbook questions,
  defer to Pigsty's own docs rather than re-deriving them here.
- **Custom playbooks** (`ansible/playbooks/*.yml` — pve-postinstall,
  vm-provision, k8s-node-prereqs) — **don't exist yet** per
  `ansible/README.md`'s TODO checklist. Don't reference a path that isn't
  there; if asked to run one, say it hasn't been drafted and offer to
  draft it (that's a separate task, not this skill's job to invent
  silently).

## Secrets pattern (from `docs/secrets.md` and `ansible/README.md`)

```bash
# daily auth pattern
source ~/.hermes/cache/inf-env.sh && infisical secrets ...

# wrapping a playbook run so secrets are injected as env vars, never written to disk
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
    ansible/playbooks/pve-postinstall.yml
```

Never write a secret *value* into any file in this repo — only reference
names (e.g. in `pigsty.yml.j2`), per `docs/secrets.md`.

## What's safe to actually execute here

Read-only / dry-run only, and only if the user asks for a live check:
- `ansible -i <inventory> all -m ping` — reachability check
- `ansible-playbook -i <inventory> <playbook> --check --diff` — dry run
- `ansible-playbook --list-tasks <playbook>` — inspect without running

## What requires the user to run it themselves

Anything that mutates real infra:
- `kubespray/cluster.yml` (or any kubespray playbook without `--check`)
- Pigsty `deploy.yml`, `pgsql.yml`, or any Pigsty playbook without a
  dry-run flag
- Proxmox VM/LXC provisioning (`vm-provision.yml`, once it exists)

For these: print the exact command (with the Infisical wrapper), explain
what it will do and what MISSION.md constraint it touches, and stop. Only
proceed if the user explicitly says to run it now in this session.
