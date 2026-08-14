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
| `playbooks/nfs-configure.yml` | Format + export NFS on the bare VM terraform/nfs.tf creates — two exports since ADR-0036, see below |
| `playbooks/k9s-dashboard-configure.yml` | Install kubectl/k9s + write a cluster-admin kubeconfig on the bare k9s-dashboard LXC terraform/k9s-dashboard.tf creates — drafted, see below |
| `playbooks/build-runner-configure.yml` | Install podman/buildah + register the GitHub Actions build runner on the bare LXC terraform/build-runner.tf creates (ADR-0034) — an LXC rather than a pod because buildah cannot extract image layers unprivileged |
| `playbooks/pihole-configure.yml` | Install/configure Pi-hole on the Pi 4, authoritative for `bnei.lan` — drafted, see below |
| `playbooks/self-drain-configure.yml` | Configure k8s-cp-01/k8s-worker-01 to drain + uncordon themselves around their own graceful reboot — drafted and run, see below |
| `inventories/proxmox/hosts.yml` | Proxmox host inventory for `pve-postinstall.yml` (`.200`/`.161` — `.165` is a delegation target only) |
| `inventories/garage/hosts.yml` | Single-host inventory for `garage-configure.yml` (`garage-storage` LXC) |
| `inventories/nfs/hosts.yml` | Single-host inventory for `nfs-configure.yml` (`nfs-storage` VM) |
| `inventories/k9s-dashboard/hosts.yml` | Single-host inventory for `k9s-dashboard-configure.yml` (`k9s-dashboard` LXC) |
| `inventories/build-runner/hosts.yml` | Single-host inventory for `build-runner-configure.yml` (`build-runner` LXC) |
| `inventories/pihole/hosts.yml` | Single-host inventory for `pihole-configure.yml` (Pi 4, physical hardware) |
| `requirements.yml` | Ansible collections needed by these playbooks (`ansible-galaxy collection install -r ansible/requirements.yml`) |

## Status

- [x] `register-repos.yml` drafted — first playbook in this repo
- [x] `pve-postinstall.yml` drafted — see below
- [x] `garage-configure.yml` drafted — see below
- [x] `nfs-configure.yml` drafted — see below
- [x] `k9s-dashboard-configure.yml` drafted — see below
- [x] `pihole-configure.yml` drafted — see below
- [x] `self-drain-configure.yml` drafted and run (2026-07-30) — see below
- [x] `build-runner-configure.yml` drafted and run (2026-08-13) — image build LXC, ADR-0034
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

**Adding just a bucket** (e.g. onboarding a new app) doesn't need the full
install-capable run — `--tags bucket_ops` (added after a real re-run for
Ente's bucket felt like it was carrying unnecessary install-path risk)
skips straight to buckets/keys/Infisical-write, no `GARAGE_VERSION`/
`GARAGE_SHA256` needed, no binary download, no `garage.toml` rewrite, no
systemd restart, no layout re-assignment. Requires Garage to already be
installed (fails loudly rather than silently regenerating `rpc_secret` if
not):

```bash
source ~/.hermes/cache/inf-env.sh
ansible-playbook -i ansible/inventories/garage/hosts.yml \
  ansible/playbooks/garage-configure.yml --tags bucket_ops
```

**CORS** (optional per bucket, `garage_buckets[].cors`) — needed for any
bucket a browser uploads to *directly* via a presigned URL (Ente's
`ente-photos`, for example): the browser enforces CORS on that
cross-origin request regardless of whether the presigned URL itself is
valid, and museum/the app server is never involved so it never sees the
failure. Applied via Garage's admin API (`127.0.0.1:3903`, called from
`garage-storage` itself — never exposed remotely) using `admin_token`,
since a bucket's own read+write key deliberately can't do `--owner`-level
operations like this. Also covered by `--tags bucket_ops`, same command as
above.

## `playbooks/nfs-configure.yml`

Formats and exports NFS on the bare `nfs-storage` VM `terraform/nfs.tf`
creates — shared PVE storage so cross-host VM template cloning takes a
direct-clone path instead of an automatic clone-then-migrate (see
[ADR-0026](../docs/adr/0026-nfs-shared-pve-storage-cross-host-clone.md)).
Much smaller scope than `garage-configure.yml`: no Infisical writes, no
application state — just format the raw extra disks, install
`nfs-kernel-server`, write `/etc/exports`, and start the service.

Since [ADR-0036](../docs/adr/0036-nfs-storage-class-for-k8s.md) the
playbook loops over an `nfs_exports` list of **two** independent exports on
**two** disks, both `no_root_squash`:

| Export | Disk | Clients | Purpose |
|---|---|---|---|
| `/export/templates` | `/dev/sdb` | the 3 PVE hosts, by IP | Shared PVE storage, ADR-0026. Untouched by ADR-0036 |
| `/export/k8s` | `/dev/sdc` | the 5 K8s nodes, by `*.bnei.lan` name | Backs the unreplicated `nfs` StorageClass, ADR-0036. **Not** a PVE pool |

The hostname clients mean this VM must resolve `bnei.lan` via Pi-hole —
`terraform/nfs.tf` declares that, but on an already-running VM it needs a
reboot to land, so the playbook asserts resolution before writing
`/etc/exports` rather than letting `exportfs` silently deny every node.

A second play then
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

## `playbooks/self-drain-configure.yml`

Configures `k8s-cp-01`/`k8s-worker-01` (both hosted on `.165`, the PVE
host that dual-boots into Windows for gaming) to drain and uncordon
**themselves** around their own graceful shutdown/reboot — two systemd
units per node, `drain-self.service` (fires on shutdown) and
`uncordon-self.service` (fires on boot).

**Why this exists**: confirmed live 2026-07-30 (`docs/bootstrap-test-notes.md`)
— an ungraceful `.165` outage left a Longhorn-backed Grafana pod stuck
`Multi-Attach error`, because Kubernetes' default node-eviction timer
reschedules pods but never force-detaches CSI volumes from a node it
can't confirm is gone. Draining *before* the node disappears sidesteps
this entirely.

**Superseded `drain-165-configure.yml`** (deleted), which ran a single
credential on `.165` itself draining both nodes from outside. Abandoned
after two real test failures:
1. Ordering `.165`'s unit `Before=pve-guests.service` (Proxmox's own
   guest-shutdown service) was backwards — systemd stops units in the
   *reverse* of their start order, so `Before=X` means "stop *after* X,"
   the opposite of what was intended. Confirmed in the journal:
   `pve-guests.service` fully stopped (all VMs powered off) *before*
   the drain script's `ExecStop` even ran.
2. Even with correct ordering, coordinating against a host-level Proxmox
   service is more fragile than necessary. Proxmox's own `qmshutdown`
   already sends each guest an ACPI shutdown signal and waits per-VM
   (confirmed 180s timeout) for a graceful shutdown — a far more natural
   trigger than fighting `pve-guests.service`'s ordering from outside.
   Each node now drains itself using that same signal, via the same
   `Before=shutdown.target`/`After=network-online.target` idiom as
   before, just inside the guest's own systemd instead of the
   hypervisor's.

**Credential scope**: same `node-drainer` ServiceAccount as before
(`gitops/bootstrap/node-drainer-rbac.yaml`) — cordon + evict only, never
cluster-admin, even though `k8s-cp-01` already has
`/etc/kubernetes/admin.conf` sitting there. Smaller blast radius, and one
consistent identity across both nodes rather than "CP uses full admin,
worker uses scoped" (`k8s-worker-01` has no admin-level credential
locally at all). The RBAC's first version was also missing
`daemonsets: get/list` — `kubectl drain --ignore-daemonsets` needs that
just to recognize and skip DaemonSet-owned pods; without it every node
failed `"cannot get resource daemonsets... forbidden"`.

### Prerequisites

- `gitops/bootstrap/node-drainer-rbac.yaml` already applied (self-syncs
  via ADR-0021's bootstrap Application once merged to `main`).
- `inventory/ukubi/hosts.yaml` (the K8s VM inventory, `~/.ssh/id_k8s_vms`,
  user `core`) — not `ansible/inventories/proxmox/` (that's for the PVE
  hosts themselves).

### How to run

```bash
ansible-playbook -i inventory/ukubi/hosts.yaml -l k8s-cp-01,k8s-worker-01 \
  ansible/playbooks/self-drain-configure.yml
```

Safe to re-run: idempotent, and a re-run's `state: started` on
`uncordon-self.service` immediately tries to uncordon a node that's
currently cordoned-but-Ready — useful right after a botched manual test.

### Verify / test

```bash
# from either node, or via ansible ad-hoc:
ansible k8s-cp-01,k8s-worker-01 -i inventory/ukubi/hosts.yaml --become \
  -m shell -a "systemctl status drain-self.service uncordon-self.service"

# trigger a real drain without a real reboot (run ON the target node):
sudo systemctl stop drain-self.service    # fires ExecStop — the actual drain
sudo systemctl start drain-self.service   # re-arm for the next real shutdown

# trigger the uncordon (safe any time, no-op if already schedulable):
sudo systemctl restart uncordon-self.service
```

**Not yet extended to future/replacement nodes**: this only configures
the 2 existing VMs — a brand-new K8s node (from Terraform) doesn't get
this automatically. Considered baking it into the shared cloud-init
snippet (`terraform/cloud-init.tf`) for true zero-touch automation, but
that needs a pre-minted, long-lived token threaded through as a
Terraform variable (cloud-init can't call `kubectl create token` against
a live cluster at first-boot time) — deferred; run this playbook by hand
against any new node instead, same as today.

## See also

- [docs/runbook-pve-postinstall.md](../docs/runbook-pve-postinstall.md)
- [gitops/README.md](../gitops/README.md) — full bootstrap sequence, of which `register-repos.yml` is Step 2
