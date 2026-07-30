# Runbook — Pigsty CA rotation + 3-node etcd DCS quorum

Follow-on to `ADR-0029`. Two problems forced this to be one combined
runbook: adding a new etcd member requires issuing it a cert from the
*same* CA every existing member already trusts, and that CA's private key
(`files/pki/ca/ca.key`) was never backed up anywhere — not in git
(`pigsty/.gitignore` excludes `files/pki/*` by design), not in Infisical.
It only ever existed on whatever machine originally ran Pigsty's install,
which isn't this checkout. See `docs/bootstrap-test-notes.md`'s
2026-07-30 entries for how this was discovered (a live incident during an
unrelated guest-agent install, then a failed `bin/etcd-add` run).

> ⚠️ Same confirmation gate as `docs/runbook-pg-bootstrap.md`:
> `pigsty/CLAUDE.md` classifies playbook execution, Patroni config
> changes, and service restarts as **requires explicit user confirmation,
> even in an otherwise-permissive mode**. This runbook is written for a
> human operator to run directly. If an agent is walking through it,
> that gate still applies at every phase below — "the runbook says so"
> is not a substitute for the "yes, I confirm."

## 1. Goal

1. Generate a fresh Pigsty CA (the old one's private key is unrecoverable
   — cryptographically impossible to reconstruct from a running server,
   confirmed against `pigsty/roles/ca/README.md`'s own docs) and back it
   up to Infisical this time.
2. Re-issue etcd's and Postgres's server certs on the existing cluster
   (`.207` primary, `.205` replica) from the new CA, with minimal
   disruption.
3. Extend etcd's DCS from its current single-node state to a real
   3-node quorum: `.207` (existing) + `.205` (pg01, the replica —
   already live, no new VM) + `pg-etcd-witness` (`.197`, ex-laptop — new
   VM, `terraform/pg-etcd-witness.tf`).

## 2. Prereqs

- Infisical project `8a3fa54f-be22-488a-bf51-55158f65c0f2`, env `dev`.
- `SSH_OLDPG_KEY`/`SSH_OLDPG_USER=vagrant` — works against `.205`/`.207`
  despite the name (see `docs/secrets.md`'s note on that row).
- `pigsty/ansible.cfg`'s `private_key_file` (`/home/mohammad/...`) is
  stale/unreachable from an operator Mac — override per-invocation with
  `ANSIBLE_PRIVATE_KEY_FILE=<materialized key path>` (env var, confirmed
  via `ansible-config list` against the actual `ansible-core 2.21.1`
  pigsty's own `ansible.cfg` resolves to — not kubespray's separate,
  differently-pinned venv).
- `pg-etcd-witness` VM not yet applied — `terraform/pg-etcd-witness.tf`
  is ready, `terraform apply -target=proxmox_virtual_environment_vm.pg_etcd_witness`
  is a separate step below.
- **Do this during a low-traffic window.** Phase 4 (etcd restart on the
  primary's sole DCS node) is a brief, expected DCS blip — same category
  of event as the incident that motivated this runbook, just planned.

## 3. Steps

All commands run from `pigsty/` on the operator machine. `<key>` below
means: materialize the relevant Infisical secret to a temp file first,
e.g. `echo "$SSH_OLDPG_KEY" > /tmp/oldpg_key && chmod 600 /tmp/oldpg_key`,
then delete it when done.

### 3.0 — Safety net: back up the *currently deployed* certs first

The old CA's private key is gone either way, but the individual
already-issued server certs on disk right now are still valid — back
them up so there's a path back to "what was already working" if
anything below goes sideways, even without the old CA key:

```bash
for ip in 192.168.1.205 192.168.1.207; do
  ssh -i <oldpg_key> vagrant@$ip \
    "sudo tar czf /tmp/cert-backup-$ip.tgz /etc/etcd /pg/cert 2>/dev/null"
  scp -i <oldpg_key> vagrant@$ip:/tmp/cert-backup-$ip.tgz ./
done
```
Keep these tarballs until Phase 3.4's verification passes.

### 3.1 — Generate the new CA (100% local, touches nothing remote)

```bash
./infra.yml -t ca
```
`infra.yml`'s `CA` play targets `hosts: localhost` — confirmed via the
playbook source, not assumed. Creates `files/pki/{ca,csr,etcd,pgsql,...}/`
fresh since none of it exists in this checkout.

**Back it up immediately** — this exact gap is why this runbook exists:
```bash
infisical secrets set --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev \
  CA_PIGSTY_KEY="$(cat files/pki/ca/ca.key)" \
  CA_PIGSTY_CRT="$(cat files/pki/ca/ca.crt)"
```
(Add both to `docs/secrets.md`'s schema once confirmed working.)

### 3.2 — Re-issue + push certs everywhere, no restarts yet

```bash
# etcd's server cert on .207 — issues + copies, does NOT restart etcd
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./etcd.yml -l 192.168.1.207 -t etcd_cert

# postgres's server cert on both .205 and .207 (pg-proxmox group)
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./pgsql.yml -l pg-proxmox -t pg_cert

# reload postgres + patroni on both — `patroni_reload` is a systemd
# *reload* (SIGHUP-style), not a restart; `pg_reload: true` is already
# the role default, no -e override needed (confirmed against
# roles/pgsql/defaults/main.yml)
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./pgsql.yml -l pg-proxmox -t pg_reload,patroni_reload
```
Low risk: a running TLS connection isn't affected by the server rotating
its on-disk cert + reloading — only new connections after the reload see
the new cert. `.207`'s etcd process is still running with the *old* cert
in memory at this point; nothing is broken yet, this is staging.

### 3.3 — The one real risk: restart etcd on `.207`

```bash
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./etcd.yml -l 192.168.1.207 -t etcd_launch
```
A `systemd restart` on the *sole* DCS node — same category as the earlier
incident, but planned and quick (a service restart, not a full VM
stop/start).

**Verify before continuing** (do not proceed to 3.4 until all pass):
```bash
ssh -i <oldpg_key> vagrant@192.168.1.207 "sudo patronictl -c /etc/patroni/patroni.yml list"
ping -c2 192.168.1.232   # VIP still responds
ssh -i <oldpg_key> vagrant@192.168.1.207 "sudo etcdctl member list"
```

### 3.4 — Add `.205` to etcd, using the now-consistent new CA

> ⚠️ **If `.205` (or any joining host) has a previous failed/partial
> join attempt behind it**, its `/data/etcd` may already hold a stale
> WAL from that attempt, with a self-generated cluster ID baked in.
> etcd only performs real join/discovery against `--initial-cluster`
> when the data directory is empty — a non-empty one just resumes
> whatever identity is already on disk, silently ignoring the flags,
> and every retry fails the same way (`cluster ID mismatch`, discovered
> the hard way 2026-07-30, see ADR-0029). Confirm first
> (`ls /data/etcd/member` on the target), and if anything is there:
> `systemctl stop etcd && rm -rf /data/etcd/member` before proceeding.

```bash
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./etcd.yml -l 192.168.1.205 -t etcd_cert
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> bin/etcd-add 192.168.1.205
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./etcd.yml -l 'etcd,!192.168.1.205' --tags=etcd_config,etcd_launch -f 1
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./pgsql.yml -l pg-proxmox -t pg_conf,patroni_reload
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./pgsql.yml -l pg-proxmox -t pg_vip
```

**Verify**: `etcdctl member list` shows 2 members, `patronictl list` shows
both PG nodes healthy. This is the fragile 2-member state (quorum =
`floor(2/2)+1` = 2, no better than 1) — don't linger here, move to 3.5
promptly.

> ⚠️ **Monitoring will show false-`down` for etcd targets unless you
> also refresh two more certs the CA-rotation phases above didn't
> touch** (found 2026-07-30, see ADR-0029) — both are monitoring-only,
> no etcd/Postgres impact, but worth doing right after 3.4 so dashboards
> aren't misleading during 3.5:
> ```bash
> ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./infra.yml -l 192.168.1.205 -t infra_cert
> ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key> ./node.yml -l 192.168.1.205,192.168.1.207 -t node_ca
> ssh -i <oldpg_key> vagrant@192.168.1.205 "sudo systemctl restart vmetrics vmalert"
> ```
> `infra_cert` reissues the infra/monitoring node's own mTLS client cert
> (`/etc/pki/infra.crt`); `node_ca` refreshes the node-wide CA trust
> bundle (`/etc/pki/ca.crt`, a separate file from `/etc/etcd/ca.crt`)
> that VictoriaMetrics uses to verify etcd's server cert. Repeat both
> after 3.5 joins `.197`, for the same reason.

### 3.5 — Provision + join `pg-etcd-witness` (ex-laptop)

```bash
# provision the bare VM
infisical run --projectId=8a3fa54f-be22-488a-bf51-55158f65c0f2 --env=dev -- \
  bash -c 'PROXMOX_VE_API_TOKEN="$PVE_API_TOKEN" PROXMOX_VE_SSH_PRIVATE_KEY="$PVE_SSH_PRIVATE_KEY" \
           TF_VAR_pve_ssh_private_key="$PVE_SSH_PRIVATE_KEY" \
           terraform -chdir=terraform apply -target=proxmox_virtual_environment_vm.pg_etcd_witness'

# bootstrap it as a pigsty-managed node (ansible_user: core is already
# set on this host's pigsty.yml entry — see the inventory comment there)
ANSIBLE_PRIVATE_KEY_FILE=<witness_key> ./node.yml -l 192.168.1.197

# issue its cert (new CA, already consistent with .205/.207) and join
ANSIBLE_PRIVATE_KEY_FILE=<witness_key> ./etcd.yml -l 192.168.1.197 -t etcd_cert
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key>   bin/etcd-add 192.168.1.197
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key>   ./etcd.yml -l 'etcd,!192.168.1.197' --tags=etcd_config,etcd_launch -f 1
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key>   ./pgsql.yml -l pg-proxmox -t pg_conf,patroni_reload
ANSIBLE_PRIVATE_KEY_FILE=<oldpg_key>   ./pgsql.yml -l pg-proxmox -t pg_vip
```
`<witness_key>` is whatever `terraform/variables.tf`'s
`pg_etcd_witness_ssh_public_key_file` points at locally — store its
private half in Infisical as `SSH_PG_ETCD_WITNESS_KEY` per
`docs/secrets.md`'s placeholder row, once it actually exists.

## 4. Verification

```bash
ssh -i <oldpg_key> vagrant@192.168.1.207 "sudo etcdctl member list"
# → 3 members

ssh -i <oldpg_key> vagrant@192.168.1.207 "sudo patronictl -c /etc/patroni/patroni.yml list"
# → both pg-proxmox-1/-2 healthy, streaming, lag 0
```

**The real test** (this is what this whole runbook exists to enable):
stop `.207` again and confirm `.205` promotes automatically *and* the
VIP (`.232`) follows — unlike the 2026-07-30 incident, this time DCS
quorum (2 of 3: `.205` + witness) should survive `.207` going down.

## 5. Rollback

- **Before 3.3 (etcd restart)**: nothing remote is broken yet — the old
  cert is still loaded in etcd's memory. Safe to stop and reassess at
  any point in 3.1/3.2.
- **After 3.3, if etcd fails to come back healthy**: restore from the
  3.0 backup tarballs (`tar xzf cert-backup-$ip.tgz -C /` on each host),
  then `./etcd.yml -l 192.168.1.207 -t etcd_launch` again to restart with
  the restored old certs. This works even without the old CA's private
  key — you're restoring already-issued, still-valid cert *files*, not
  re-deriving them.
- **After 3.4/3.5, if a new member won't join cleanly**: `pigsty/etcd-rm.yml`
  removes a member (`-l <ip>` scoped) without touching the others —
  requires the same explicit-confirmation treatment as any other
  `*-rm.yml` playbook per `pigsty/CLAUDE.md`.

## Previous

Postgres/Pigsty bootstrap: [`docs/runbook-pg-bootstrap.md`](runbook-pg-bootstrap.md).
K8s HA design this mirrors: [`ADR-0017`](adr/0017-second-control-plane-member.md).
