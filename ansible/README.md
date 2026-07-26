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
| `inventories/proxmox/hosts.yml` | Proxmox host inventory for `pve-postinstall.yml` (`.200`/`.161` — `.165` is a delegation target only) |
| `requirements.yml` | Ansible collections needed by these playbooks (`ansible-galaxy collection install -r ansible/requirements.yml`) |

## Status

- [x] `register-repos.yml` drafted — first playbook in this repo
- [x] `pve-postinstall.yml` drafted — see below
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
pool per host (ADR-0014), the corosync join itself, and propagating the
golden K8s template (VMID 9001) so Terraform can place worker VMs there.

Targets `ansible/inventories/proxmox/hosts.yml` (root SSH, not the K8s VM
inventory). Full sequencing (the corosync join must run one host at a time)
lives in [`docs/runbook-pve-postinstall.md`](../docs/runbook-pve-postinstall.md) —
not repeated here.

**Status:** authored, not yet run — `.200`/`.161` don't have PVE installed
or a network path to them yet. Safe to `--syntax-check` today; the real run
is a later, human-driven session once both hosts exist and are reachable.

### Other playbooks (not yet drafted)

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
    ansible/playbooks/vm-provision.yml
```

## See also

- [docs/runbook-pve-postinstall.md](../docs/runbook-pve-postinstall.md)
- [gitops/README.md](../gitops/README.md) — full bootstrap sequence, of which `register-repos.yml` is Step 2
