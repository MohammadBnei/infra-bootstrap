# Ansible playbooks

Custom playbooks for things kubespray and pigsty don't cover:
- PVE post-install (after a fresh PVE install, before any VMs)
- VM provisioning on PVE (create VMs/LXCs from inventory)
- K8s node prereqs (kernel modules, sysctl, containerd) — usually handled by kubespray but useful to have standalone for ad-hoc nodes

## Layout

| Path | Contents |
|---|---|
| `playbooks/register-repos.yml` | Create the manual K8s Secrets ArgoCD needs before it can bootstrap the rest of the cluster (drafted — see below) |
| `playbooks/pve-postinstall.yml` | Configure a fresh PVE host (repos, NTP, ZFS pool, corosync join, SSH keys) — drafted, see below |
| `playbooks/vm-provision.yml` | Create QEMU VMs and LXC containers from a host_vars-driven spec |
| `playbooks/k8s-node-prereqs.yml` | Standalone K8s-node prereq setup (kernel modules, cgroup, containerd) |
| `playbooks/garage-configure.yml` | Install/configure Garage on the bare LXC terraform/garage.tf creates — drafted, see below |
| `playbooks/nfs-configure.yml` | Format + export NFS on the bare VM terraform/nfs.tf creates — drafted, see below |
| `inventories/proxmox/hosts.yml` | Proxmox host inventory for `pve-postinstall.yml` (`.200`/`.161` — `.165` is a delegation target only) |
| `inventories/garage/hosts.yml` | Single-host inventory for `garage-configure.yml` (`garage-storage` LXC) |
| `inventories/nfs/hosts.yml` | Single-host inventory for `nfs-configure.yml` (`nfs-storage` VM) |
| `requirements.yml` | Ansible collections needed by these playbooks (`ansible-galaxy collection install -r ansible/requirements.yml`) |

## Status

- [x] `register-repos.yml` drafted — first playbook in this repo
- [x] `pve-postinstall.yml` drafted — see below
- [x] `garage-configure.yml` drafted — see below
- [x] `nfs-configure.yml` drafted — see below
- [ ] `vm-provision.yml` drafted
- [ ] `k8s-node-prereqs.yml` drafted (may not be needed if kubespray covers it)

## `playbooks/register-repos.yml`

Replaces the old `gitops/bootstrap/register-repos.sh` bash script. Creates
the 3 manual K8s Secrets ArgoCD needs before it can sync the rest of the
cluster:

| Secret | Namespace | Purpose |
|---|---|---|
| `repo-infra-bootstrap` | `argocd` | Git SSH credential — lets ArgoCD pull this repo's own values at wave 1 |
| `infisical-secrets` | `infisical` | Infisical's own DB/encryption/SMTP bootstrap secrets (feeds the Helm chart's `kubeSecretRef`) |
| `universal-auth-credentials` | `infisical` | Machine-identity credentials the in-cluster Infisical Operator uses to authenticate and pull every other app's secrets |

**Why these three stay local instead of coming from Infisical:** all three
exist to bring Infisical itself up (wave 1). At that point in a
from-scratch rebuild there's no independent, already-running Infisical to
fetch them from — `infisical.bnei.dev` *is* the instance being bootstrapped
here. Keeping them local is what makes a full disaster-recovery rebuild
possible at all.

**Execution model:** targets `k8s-cp-01` from `inventory/ukubi/hosts.yaml`
(not `ansible/inventories/proxmox/` — that inventory is for PVE-host
playbooks, a different target). `kubectl --dry-run=client` never contacts
the API server, so every Secret/Namespace manifest is rendered locally; only
the final `kubectl apply -f -` runs on `k8s-cp-01` (over the same SSH
connection already used for kubespray), fed the rendered YAML via stdin. No
kubeconfig is ever materialized on the operator's machine, per the
`k8s-ops` skill's hard rule.

### Prerequisites

- `kubectl` installed locally (used for local manifest rendering only)
- SSH access to `k8s-cp-01` (already configured in `inventory/ukubi/hosts.yaml`)
- `ansible/playbooks/register-repos.env` filled in (see below)

### How to run

```bash
cp ansible/playbooks/register-repos.env.example ansible/playbooks/register-repos.env
# ...fill in register-repos.env — see the comments in the file for where
# each value comes from today (the running k8s-cluster/infisical/ deployment
# and the infra-bootstrap SSH keypair)...

set -a && source ansible/playbooks/register-repos.env && set +a
ansible-playbook -i inventory/ukubi/hosts.yaml ansible/playbooks/register-repos.yml
```

Safe to re-run: every `kubectl` call is `apply`, not `create`.

### Extending it

Adding another manually-injected repo credential (rare — almost everything
else flows through Infisical via `InfisicalSecret` CRDs once wave 1 is up)
follows the same three-step pattern as the `repo-infra-bootstrap` task:
render the Secret YAML locally with `kubectl create secret ... --dry-run=client
-o yaml` (`delegate_to: localhost`), then apply it with `kubectl apply -f -`
on `k8s-cp-01` (`become: true`) with the rendered YAML passed via the
`command` module's `stdin` argument.

## `playbooks/pve-postinstall.yml`

Prepares `.200` (server1) and `.161` (ex-laptop) to join `.165` as a single
corosync-clustered PVE datacenter (`docs/adr/0020-pve-corosync-cluster.md`):
lid/suspend disable on `.161` (ADR-0013), repo/NTP prep, a dedicated ZFS
pool per host (ADR-0014), and the corosync join itself. No template
pre-staging step — clustering already lets any node clone the golden
K8s template (VMID 9001, stays on proxmox) directly onto another node on
demand (`qm clone --target <node> --full`), so a future `vm-provision.yml`
does that at VM-creation time instead.

Targets `ansible/inventories/proxmox/hosts.yml` (root SSH, not the K8s VM
inventory). Full sequencing (the corosync join must run one host at a time)
lives in [`docs/runbook-pve-postinstall.md`](../docs/runbook-pve-postinstall.md) —
not repeated here.

**Status:** run and verified against both hosts — `.200` (server1) and
`.161` (ex-laptop) are both reinstalled to PVE and joined `.165`'s
corosync cluster (fixes along the way: `pvecm add --use_ssh 1` to force
the SSH trust, a wait-for-quorum retry after bootstrapping the cluster).
`.200` ended up single-disk (its second disk was removed pre-reinstall),
so its ZFS-pool play is a no-op there — see
[ADR-0024](../docs/adr/0024-server1-single-disk-ext4-no-dedicated-zfs.md).
`.161` kept its dedicated `zfs-exlaptop` pool per ADR-0014.

## `playbooks/garage-configure.yml`

Installs and configures Garage (S3-compatible object storage) on the bare
`garage-storage` LXC `terraform/garage.tf` creates — replaces what used to
be a broken community-scripts.org installer (dropped into an interactive
`whiptail` menu, hung forever under Terraform's non-interactive SSH
provisioner) plus an entirely manual, unscripted "run `garage layout`/
`bucket`/`key` by hand" step. This playbook does all of it: installs the
pinned Garage binary, writes `/etc/garage.toml` and a systemd unit,
assigns single-node cluster layout, creates the `k8s-longhorn-backup`
(Longhorn) and `pg-backup` (pgBackRest, provisional name) buckets, issues
one S3 key per bucket, and writes `GARAGE_ROOT_TOKEN`,
`LONGHORN_S3_ACCESS_KEY`/`_SECRET`, `PGBACKREST_S3_ACCESS_KEY`/`_SECRET` to
Infisical directly (`infisical secrets set` — no K8s cluster is involved
here, unlike `register-repos.yml`).

**Execution model:** targets `garage-storage` from
`ansible/inventories/garage/hosts.yml` (a single hand-maintained host — fill
in `ansible_host` with the LXC's real IP after `terraform apply`, matching
`terraform.tfvars`' `garage_ip`). SSH access is via a dedicated keypair
(`~/.ssh/id_garage`, seeded into the LXC by `terraform/garage.tf` via
`garage_ssh_public_key_file`), root user — not the PVE-host or k8s-VM keys.

### Prerequisites

- `garage-storage` LXC already created and reachable (`terraform apply
  -target=...` per `terraform/README.md`)
- `~/.ssh/id_garage` keypair generated and its public half already applied
  (it's baked in at LXC creation time via cloud-init, nothing to do after
  the fact)
- Infisical CLI session already authenticated (`source
  ~/.hermes/cache/inf-env.sh`) — this playbook writes secrets directly, so
  the session needs write access to the `infra-bootstrap` project
- `GARAGE_VERSION` / `GARAGE_SHA256` env vars set — check
  https://garagehq.deuxfleurs.fr/download/ for the current stable release
  and the sha256 of the `x86_64-unknown-linux-musl` static binary; not
  hardcoded in the playbook on purpose (same "confirm, don't guess"
  discipline as `terraform/variables.tf`'s `pve_node_name`)

### How to run

```bash
# fill in ansible/inventories/garage/hosts.yml's ansible_host first
export GARAGE_VERSION=v2.3.0        # check the download page for current
export GARAGE_SHA256=<sha256 of the x86_64-unknown-linux-musl binary>
source ~/.hermes/cache/inf-env.sh
ansible-playbook -i ansible/inventories/garage/hosts.yml ansible/playbooks/garage-configure.yml
```

Safe to re-run: every mutating step checks current state first (layout,
buckets, keys) or is naturally idempotent (checksum-gated download, secret
extraction instead of regeneration when `garage.toml` already exists,
`infisical secrets set` upserts). One caveat: re-running against a
*destroyed-and-recreated* LXC (not just a live re-run) generates a new
`rpc_secret`/keys and overwrites Infisical with them — correct, but any
prior bucket data is gone with the old container.

## `playbooks/nfs-configure.yml`

Formats and exports NFS on the bare `nfs-storage` VM `terraform/nfs.tf`
creates — shared PVE storage so cross-host VM template cloning takes a
direct-clone path instead of an automatic clone-then-migrate (see
[ADR-0026](../docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md)).
Much smaller scope than `garage-configure.yml`: no Infisical writes, no
application state — just format the raw second disk, install
`nfs-kernel-server`, write `/etc/exports` restricted to the 3 PVE cluster
members with `no_root_squash`, and start the service. A second play then
registers the export as a PVE storage pool (`pvesm add nfs ...`) against
the `proxmox` host alias — idempotent (only runs if not already present),
and only needed once since `storage.cfg` is cluster-shared (ADR-0020).

**Execution model:** the first play targets `nfs-storage` from
`ansible/inventories/nfs/hosts.yml` (a single hand-maintained host — fill
in `ansible_host` with the VM's real IP after `terraform apply`, matching
`terraform.tfvars`' `nfs_ip`); SSH access is via a dedicated keypair
(`~/.ssh/id_nfs`, seeded into the VM by `terraform/nfs.tf` via
`nfs_ssh_public_key_file`), `core` user + sudo — same pattern as the K8s
VMs, unlike `garage-storage`'s root-user LXC. The second play targets
`proxmox` from `ansible/inventories/proxmox/hosts.yml` (root SSH, same
alias `pve-postinstall.yml` uses) — both inventories must be passed.

### Prerequisites

- `nfs-storage` VM already created and reachable (`terraform apply
  -target=...` per `terraform/README.md`, including the
  `nfs_vm_vendor_data` snippet — `agent.enabled = true` makes `apply`
  hang without it, confirmed by testing)
- `~/.ssh/id_nfs` keypair generated and its public half already applied
  (baked in at VM creation time via cloud-init)

### How to run

```bash
# fill in ansible/inventories/nfs/hosts.yml's ansible_host first
ansible-playbook -i ansible/inventories/nfs/hosts.yml \
  -i ansible/inventories/proxmox/hosts.yml \
  ansible/playbooks/nfs-configure.yml
```

Safe to re-run: the format step is `blkid`-guarded, the mount/exports are
declarative, `exportfs -ra` just re-reads current state.

### Other playbooks (not yet drafted)

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
    ansible/playbooks/vm-provision.yml
```

## See also

- [docs/runbook-pve-postinstall.md](../docs/runbook-pve-postinstall.md)
- [gitops/README.md](../gitops/README.md) — full bootstrap sequence, of which `register-repos.yml` is Step 2
