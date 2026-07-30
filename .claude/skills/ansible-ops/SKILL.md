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
described in `DECISION.md` §2.

## Which tool, which playbook

- **Kubespray** — `kubespray/cluster.yml` (submodule). Greenfield bootstrap
  and any control-plane/etcd membership change (adding/removing a CP node)
  always uses `cluster.yml`, **never `scale.yml`** (`DECISION.md` §2 —
  `scale.yml` skips the control-plane join role; worker-only additions,
  e.g. `k8s-worker-02`, used `scale.yml` fine). Invoked against
  `inventory/ukubi/hosts.yaml`.
  - **Ansible version is a hard constraint, not a suggestion**: kubespray
    v2.31.0 requires ansible-core strictly `2.18.0 ≤ v < 2.19.0`
    (`kubespray/requirements.txt` pins `ansible==11.13.0`). The Homebrew
    `ansible-playbook` on `PATH` is very likely newer and will fail
    immediately at kubespray's own version-assertion task. Use a dedicated
    venv (`kubespray-venv/` — already gitignored, may not actually exist
    on a given machine even though this is documented; verify with
    `kubespray-venv/bin/ansible-playbook --version` before trusting it,
    recreate with `python3.12 -m venv kubespray-venv && kubespray-venv/bin/pip
    install -r kubespray/requirements.txt` if missing).
  - **`--tags` narrows the run** — a full `cluster.yml` run touches
    everything and can take many minutes; for a targeted config change
    (e.g. DNS/CoreDNS), find the actual tag first
    (`grep -rn "tags:" -A2 kubespray/roles/<relevant-role>/tasks/*.yml`)
    rather than defaulting to a full untagged run every time. Example:
    CoreDNS + nodelocaldns config changes only need
    `--tags coredns,nodelocaldns` (both live in the same
    `kubernetes-apps/ansible` role, two separate tags).
  - **`inventory/ukubi/hosts.yaml` is Terraform-generated** — adding a
    `k8s_nodes` entry and applying it with a `-target`-scoped `terraform
    apply` (recommended, to avoid touching already-live nodes) creates the
    VM but does **not** regenerate this file, since `local_file.
    kubespray_inventory` is a sibling resource, not a dependent of the VM
    resource. Check `terraform plan -target=local_file.kubespray_inventory`
    before running `cluster.yml` against a freshly-added node — this has
    bitten real runs more than once, it's a repeatable footgun, not a
    one-off (see `docs/bootstrap-test-notes.md`'s 2026-07-28 and
    2026-07-30 entries).
- **Pigsty** — vendored in `pigsty/`, its own playbooks (`deploy.yml`,
  `pgsql.yml`, `node.yml`, etc.) and its own `pigsty/CLAUDE.md`/
  `pigsty/README.md`. For Pigsty-specific flag or playbook questions,
  defer to Pigsty's own docs rather than re-deriving them here.
- **Custom playbooks** (`ansible/playbooks/*.yml`) — drafted and in real
  use: `register-repos.yml`, `pve-postinstall.yml`, `garage-configure.yml`,
  `nfs-configure.yml`, `k9s-dashboard-configure.yml`,
  `pihole-configure.yml` (see `ansible/README.md` for what each does and
  its own inventory/prerequisites). Still not drafted: `vm-provision.yml`,
  `k8s-node-prereqs.yml` — don't reference those as if they exist; offer
  to draft them instead (separate task).
  - Physical, non-Terraform-provisioned hosts (currently: the Pi 4) have
    no locally-generated dedicated keypair the way Terraform-provisioned
    VMs/LXCs do (`id_garage`, `id_nfs`, etc.) — access is via Infisical's
    `SSH_<HOST>_KEY`, fetched at run time and passed via
    `-e ansible_ssh_private_key_file=<path>`, not assumed to already exist
    locally under a guessed filename.

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
what it will do and what `DECISION.md` constraint it touches, and stop. Only
proceed if the user explicitly says to run it now in this session.
