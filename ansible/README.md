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
| `playbooks/k9s-dashboard-configure.yml` | Install kubectl/k9s + write a cluster-admin kubeconfig on the bare k9s-dashboard LXC terraform/k9s-dashboard.tf creates — drafted, see below |
| `playbooks/pihole-configure.yml` | Install/configure Pi-hole on the Pi 4, authoritative for `bnei.lan` — drafted, see below |
| `playbooks/drain-165-configure.yml` | Install a pre-shutdown drain automation on `.165` (cordons/evicts k8s-cp-01/k8s-worker-01 before a graceful reboot) — drafted and run, see below |
| `inventories/proxmox/hosts.yml` | Proxmox host inventory for `pve-postinstall.yml` (`.200`/`.161`) and now also `drain-165-configure.yml` (`.165`, `-l proxmox`) |
| `inventories/garage/hosts.yml` | Single-host inventory for `garage-configure.yml` (`garage-storage` LXC) |
| `inventories/nfs/hosts.yml` | Single-host inventory for `nfs-configure.yml` (`nfs-storage` VM) |
| `inventories/k9s-dashboard/hosts.yml` | Single-host inventory for `k9s-dashboard-configure.yml` (`k9s-dashboard` LXC) |
| `inventories/pihole/hosts.yml` | Single-host inventory for `pihole-configure.yml` (Pi 4, physical hardware) |
| `requirements.yml` | Ansible collections needed by these playbooks (`ansible-galaxy collection install -r ansible/requirements.yml`) |

## Status

- [x] `register-repos.yml` drafted — first playbook in this repo
- [x] `pve-postinstall.yml` drafted — see below
- [x] `garage-configure.yml` drafted — see below
- [x] `nfs-configure.yml` drafted — see below
- [x] `k9s-dashboard-configure.yml` drafted — see below
- [x] `pihole-configure.yml` drafted — see below
- [x] `drain-165-configure.yml` drafted and run (2026-07-30) — see below
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

## `playbooks/k9s-dashboard-configure.yml`

Installs `kubectl` + `k9s` and writes a cluster-admin-scoped kubeconfig on
the bare `k9s-dashboard` LXC `terraform/k9s-dashboard.tf` creates — a
human SSHes into this box and runs `k9s` against the live `ukubi-cluster`
instead of SSHing to `k8s-cp-01` and running one-off `kubectl` commands.

**Why this doesn't violate the `k8s-ops` skill's hard rule:** that rule
says a cluster kubeconfig/`admin.conf` must never be materialized on the
*operator's* machine — every ad-hoc `kubectl` call goes over SSH to
`k8s-cp-01` instead. `k9s-dashboard` isn't the operator's machine, it's
the purpose-built box this kubeconfig is meant to live on (k9s needs
continuous API access, which the SSH-per-command pattern can't give it).
The playbook never writes a cluster credential anywhere else.

**Execution model:** two plays in one file. Play 1 targets `k8s-cp-01`
(from `inventory/ukubi/hosts.yaml`): creates a dedicated `k9s-dashboard`
ServiceAccount + a `cluster-admin` ClusterRoleBinding (same precedent as
the existing `K8S_BREAK_GLASS_TOKEN`, see `docs/secrets.md`) — manifests
rendered locally via `--dry-run=client`, applied remotely via stdin, same
pattern as `register-repos.yml` — then mints a long-lived token and reads
the cluster's API server URL/CA data, all over the existing SSH connection
(these can't be dry-run'd). Play 2 targets `k9s-dashboard` (from
`ansible/inventories/k9s-dashboard/hosts.yml`): reads Play 1's registered
facts via `hostvars['k8s-cp-01'][...]` (facts persist across plays in one
playbook run), installs `kubectl`/`k9s`, and writes the resulting
kubeconfig to `/root/.kube/config`. Root user, dedicated SSH keypair
(`~/.ssh/id_k9s_dashboard`, seeded into the LXC by
`terraform/k9s-dashboard.tf` via `k9s_dashboard_ssh_public_key_file`).

### Prerequisites

- `k9s-dashboard` LXC already created and reachable (`terraform apply
  -target=...` per `terraform/README.md`)
- `~/.ssh/id_k9s_dashboard` keypair generated and its public half already
  applied (baked in at LXC creation time via cloud-init)
- `ansible/inventories/k9s-dashboard/hosts.yml`'s `ansible_host` filled in
- `KUBECTL_VERSION` (match `inventory/ukubi/group_vars/k8s_cluster/
  k8s-cluster.yml`'s `kube_version`) and `K9S_VERSION`/`K9S_SHA256` (check
  https://github.com/derailed/k9s/releases for the current release and the
  sha256 of `k9s_linux_amd64.tar.gz`) env vars set — not hardcoded in the
  playbook, same "confirm, don't guess" discipline as `garage-configure.yml`'s
  `GARAGE_VERSION`/`GARAGE_SHA256`

### How to run

```bash
# fill in ansible/inventories/k9s-dashboard/hosts.yml's ansible_host first
export KUBECTL_VERSION=v1.35.4   # match inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml's kube_version
export K9S_VERSION=v0.50.6       # check https://github.com/derailed/k9s/releases for current
export K9S_SHA256=<sha256 of k9s_linux_amd64.tar.gz for that release>
ansible-playbook -i inventory/ukubi/hosts.yaml \
  -i ansible/inventories/k9s-dashboard/hosts.yml \
  ansible/playbooks/k9s-dashboard-configure.yml
```

Safe to re-run: ServiceAccount/ClusterRoleBinding creation is
`apply`-based, `kubectl`/`k9s` installs are checksum-gated. Token minting
mints a fresh token every run (rotates, not a bug) and the kubeconfig is
overwritten to match.

## `playbooks/pihole-configure.yml`

Installs Pi-hole on the Pi 4 (`192.168.1.55`) and makes it authoritative
for `bnei.lan` (`DECISION.md` §2), triggered once there were enough real
internal hostnames (kube-vip's `k8s.bnei.lan`, the pg/garage/nfs/
k9s-dashboard VMs) that raw IPs stopped being convenient.

**Unattended install, the hard way it actually works:** Pi-hole v6's
installer shows interactive whiptail dialogs (interface, upstream DNS,
blocklists, logging, privacy level) whenever it detects a fresh install —
gated purely on `/etc/pihole/setupVars.conf`/`pihole.toml` not existing
yet, with no env var to skip them once that branch is taken (confirmed
against `pi-hole/pi-hole`'s actual installer source, not just docs, which
were thin/inconsistent for v6). So this playbook pre-touches an empty
`setupVars.conf` first — that flips the installer onto its "already
configured, just migrate to v6 defaults" path, skipping every dialog —
then explicitly sets everything we actually want afterward via the real
v6 CLI: `pihole-FTL --config <key> <value>` (confirmed keys: `dns.hosts`
for local A records — format `"IP HOSTNAME"`, a JSON string array, per
`pi-hole/FTL`'s `config.c` — plus `dns.upstreams`, `dns.interface`,
`dns.queryLogging`, `misc.privacylevel`) and `pihole setpassword`.

The `bnei.lan` record set (`pihole_hosts_records` var) mirrors
`ARCHITECTURE.md` §3's target list, filled in with real currently-assigned
IPs. Add a line there as each new host actually gets provisioned — it's a
declared, reconciled-every-run list, not a one-time seed.

**Static IP:** the Pi's `192.168.1.55` was confirmed live (2026-07-30) to
be a DHCP-dynamic lease, not static — a real risk once the whole LAN's DNS
depends on that address staying put. Pinned self-contained on the Pi
itself (not a Freebox DHCP reservation) via `community.general.nmcli`,
targeting the `netplan-eth0` NetworkManager connection profile — confirmed
live that NetworkManager is the actual renderer here (the on-disk netplan
YAML is just NM's own passthrough dump, not the source of truth), so
`nmcli` is the correct tool rather than hand-editing netplan files.

### Prerequisites

- Pi 4 freshly reinstalled (Debian 13 trixie) and reachable at
  `ansible/inventories/pihole/hosts.yml`'s `ansible_host`. Unlike garage/
  nfs, there's no local Terraform-generated keypair for physical
  hardware — fetch `SSH_PI4_KEY` from Infisical first (see the inventory
  file's header comment for the exact commands)
- Infisical CLI session authenticated (`source ~/.hermes/cache/inf-env.sh`)
  — writes `PIHOLE_WEBPASSWORD` there on first install
- `ansible-galaxy collection install -r ansible/requirements.yml`
  (`community.general`, for the `nmcli` static-IP task)

### How to run

```bash
infisical secrets get SSH_PI4_KEY --projectId=<infra-bootstrap-project-id> --env=dev --plain > /tmp/pi4_key
chmod 600 /tmp/pi4_key
ansible-playbook -i ansible/inventories/pihole/hosts.yml \
  -e ansible_ssh_private_key_file=/tmp/pi4_key \
  ansible/playbooks/pihole-configure.yml
```

Safe to re-run: install itself only happens once (`pihole.toml` existence
check). Password is only generated/set on that same first-install branch
— v6 stores it as a one-way hash, nothing to recover from config on a
later run, so re-runs deliberately leave an already-set password alone.
`dns.hosts`/`dns.upstreams` are set unconditionally every run (re-setting
an unchanged value is harmless — `pihole-FTL --config -q` doesn't emit
real JSON for arrays, so a read-then-compare isn't worth the parsing).

**Not automated here:** pointing LAN devices/DHCP at `192.168.1.55` for
DNS — that's a Freebox router config change, no API access assumed.

### Other playbooks (not yet drafted)

```bash
infisical run --projectId=<infra-bootstrap-project-id> --env=dev -- \
  ansible-playbook -i ansible/inventories/proxmox/hosts.yml \
    ansible/playbooks/vm-provision.yml
```

## `playbooks/drain-165-configure.yml`

Installs a pre-shutdown drain automation on `.165` — the PVE host that
dual-boots into Windows for gaming. A systemd oneshot service
(`drain-165.service`) fires `kubectl drain k8s-cp-01 k8s-worker-01` on
every graceful shutdown/reboot, using a dedicated, scoped (not
cluster-admin) kubeconfig at `/etc/k8s-drain/kubeconfig`.

**Why this exists**: confirmed live 2026-07-30 (`docs/bootstrap-test-notes.md`)
— an ungraceful `.165` outage left a Longhorn-backed Grafana pod stuck
`Multi-Attach error`, because Kubernetes' default node-eviction timer
reschedules *pods* but never force-detaches CSI volumes from a node it
can't confirm is gone. Draining *before* the node disappears sidesteps
this: pods get evicted and volumes cleanly detached while the node is
still reachable.

**Why a systemd service, not a `/usr/lib/systemd/system-shutdown/`
script**: those run after the network is already torn down — too late
to reach the cluster. This unit is ordered `Before=shutdown.target` +
`After=network-online.target`, so its `ExecStop` (the actual drain)
fires *during* the shutdown sequence, before networking goes away.
`TimeoutStopSec=90` bounds how long systemd waits, so a hung drain can't
block a real shutdown — worst case it times out and shutdown proceeds
anyway, no worse than not draining at all.

**Known limitation, accepted**: only fires on a graceful, systemd-initiated
shutdown/reboot, not a hard power-cut — acceptable since switching to
Windows on this host normally goes through a real `reboot`, not a cold
power-off.

**Credential scope**: the kubeconfig uses a dedicated `node-drainer`
ServiceAccount (`gitops/bootstrap/node-drainer-rbac.yaml`) scoped to just
`nodes: get/list/patch/update`, `pods: get/list`, `pods/eviction: create`,
`poddisruptionbudgets: get/list` — never cluster-admin, since this
credential lives on a dual-boot consumer OS, more exposed than the other
infra hosts. The bearer token is minted live via `kubectl create token`
and never committed to git or printed to a terminal.

### Prerequisites

- `gitops/bootstrap/node-drainer-rbac.yaml` already applied (self-syncs
  via ADR-0021's bootstrap Application once merged to `main`).
- Root SSH to `.165` (`PVE_SSH_PRIVATE_KEY` from Infisical) **and** a
  reachable K8s control-plane node's key (`~/.ssh/id_k8s_vms`, user
  `core`) available simultaneously — two different credentials, so run
  via an `ssh-agent` with both loaded rather than a single
  `ANSIBLE_PRIVATE_KEY_FILE`.

### How to run

```bash
infisical secrets get PVE_SSH_PRIVATE_KEY --projectId=<infra-bootstrap-project-id> --env=dev --plain --domain=<infisical-domain> > /tmp/pve_root_key
chmod 600 /tmp/pve_root_key
eval "$(ssh-agent -s)"
ssh-add /tmp/pve_root_key
ssh-add ~/.ssh/id_k8s_vms
ansible-playbook -i ansible/inventories/proxmox/hosts.yml -l proxmox \
  ansible/playbooks/drain-165-configure.yml
```

### Verify / test

```bash
ssh -i /tmp/pve_root_key root@192.168.1.165 systemctl status drain-165.service
# Trigger a real drain without actually rebooting the host:
ssh -i /tmp/pve_root_key root@192.168.1.165 systemctl stop drain-165.service
# ... confirm k8s-cp-01/k8s-worker-01 cordoned + pods evicted, then:
ssh -i /tmp/pve_root_key root@192.168.1.165 systemctl start drain-165.service
kubectl uncordon k8s-cp-01 k8s-worker-01   # drain-165.service doesn't uncordon on its own
```

## See also

- [docs/runbook-pve-postinstall.md](../docs/runbook-pve-postinstall.md)
- [gitops/README.md](../gitops/README.md) — full bootstrap sequence, of which `register-repos.yml` is Step 2
