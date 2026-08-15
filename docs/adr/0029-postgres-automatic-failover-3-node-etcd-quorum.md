# ADR-0029: Postgres automatic failover accepted; 3-node etcd DCS quorum

**Status:** Accepted

## Context

`DECISION.md` §2 originally locked "Postgres has no witness node and no
automatic failover — 2 data VMs in primary/replica mode only, no 3-node
Patroni quorum. Simplicity over full HA at this scale." §4 flagged this as
possibly contradicted by `pigsty.yml`'s unmodified `patroni_mode: default`,
but left it unresolved pending a live check.

That live check happened 2026-07-30: `patronictl list` against the running
`pg-proxmox` cluster shows `192.168.1.207` (documented everywhere as
"pg02", the replica) as the current **Leader**, and `192.168.1.205`
(documented as "pg01", the primary) as the current **Replica** — the
opposite of every doc. No pause/maintenance mode is set; normal
`ttl`/`loop_wait`/`maximum_lag_on_failover` are active. Automatic failover
is not a config-file relic, it already ran for real at some point and
promoted the replica — that's how the roles flipped.

Separately, both PG data VMs and the sole etcd DCS node (`.207`, a single
member) are still physically on `.165` — the same dual-boot
Windows/gaming host that forced the k8s control-plane to a deliberately
placed 3-CP/etcd design (ADR-0017). Today, a `.165` shutdown takes out the
primary, the replica, and the only DCS node simultaneously: total outage,
not a graceful degrade.

## Decision

1. **Accept automatic failover as the real, intended behavior.** It
   already saved the cluster once. Supersedes §2's old "no automatic
   failover" line — Patroni + etcd continue to manage promotion, no
   `patronictl pause`.
2. **Target PG data-node placement:** whichever data VM is presently the
   Leader (`.207`) stays on `.165`; the current Replica (`.205`) migrates
   to server1 (`.200`) — mirrors the reserved headroom already noted in
   `terraform.tfvars`' `k8s-worker-02` entry. This is the opposite
   assignment from the original pg01(.165)/pg02(server1) plan, because the
   roles already flipped live before the migration happened — placement
   follows current reality, not the old static labels.
3. **3-node etcd DCS quorum**, mirroring ADR-0017's reasoning exactly:
   `floor(N/2)+1` means a 1-node DCS has zero tolerance and a 2-node DCS is
   strictly worse (both must be up). Add a 3rd etcd-only member on
   ex-laptop as a **new, dedicated small VM** — not co-located on the
   existing `k8s-cp-03` VM there, to keep Patroni's DCS availability
   decoupled from k8s control-plane lifecycle (kubeadm upgrades, CP
   restarts) on the same host.

| Node | Host | Role after migration |
|---|---|---|
| `.207` (existing) | `.165` | PG primary (current Leader, stays put) |
| `.205` (existing) | server1 → migrates here | PG replica |
| `.207` etcd (existing) | `.165` | etcd DCS member |
| `.205` or new host's etcd | server1 | etcd DCS member (moves with the replica) |
| new witness VM | ex-laptop | etcd DCS member only (no PG data) |

## Consequences

- `pigsty.yml`'s `etcd:` hosts block gains the new ex-laptop witness IP.
  Actually adding it as a live etcd member is a real DCS operation
  (`etcd.yml`/`node.yml` equivalent) — the user's own action, gated per
  `pigsty/CLAUDE.md`'s confirmation rules, not run unattended from this
  repo's agent sessions.
- `terraform/pg-etcd-witness.tf` (new) provisions the bare witness VM on
  ex-laptop, same "Terraform creates bare VM, Ansible/Pigsty configures
  it" split as `nfs.tf`/`garage.tf`.
- **`.205` migration: done (2026-07-30).** Ended up simpler than the
  add-replica/switchover/remove plan originally sketched here — a direct
  Proxmox live migration of the replica VM (not the primary, so no
  Patroni coordination needed). Confirmed via the PVE task log
  (`qmigrate OK`) and `patronictl list` (streaming, timeline matches
  leader, lag 0). Hit one real snag: a kernel panic on first boot on
  server1 (old hand-built VM, not one of this repo's cloud-init clones —
  live migration doesn't give the guest a fresh-boot reset the way a
  stop/move/restart would), recovered cleanly with a plain reboot. See
  `docs/bootstrap-test-notes.md`'s 2026-07-30 entry.
- **Still open:** DCS is still single-node (`.207` only) until both the
  witness VM is actually applied/joined *and* `.205`'s new host (server1)
  gets its own etcd instance added. Real 3-node quorum needs both; a
  `.165` reboot today would still lose DCS, even though the PG replica
  itself now survives the same event.
- `terraform/imported.tf`'s `pg01` resource `node_name` is now `"server1"`
  (was `var.pve_node_name`/`.165`) — confirmed zero-diff via
  `terraform plan -target=proxmox_virtual_environment_vm.pg01` after the
  live migration.
- **New blocker found mid-rollout**: `bin/etcd-add`'s first attempt
  failed — `pigsty/files/pki/` (including the CA's private key) doesn't
  exist in this checkout, isn't in git (gitignored by design), and isn't
  in Infisical. Unrecoverable from any running server (the private key
  is never deployed there, only server certs signed by it). Forces a CA
  rotation before the quorum work can proceed at all — full sequence,
  including the Postgres-side certs and a proper Infisical backup this
  time, in
  [`docs/runbook-pg-ca-rotation-etcd-quorum.md`](../runbook-pg-ca-rotation-etcd-quorum.md).
  CA rotation itself (phases 3.0–3.3) completed successfully.
- **`.205` etcd join: resolved (2026-07-30, 3rd attempt).** The first two
  attempts failed identically (`cluster ID mismatch`, real quorum-loss
  incident on `.207` both times, recovered via `etcdutl snapshot
  restore`), and were paused pending research rather than a 3rd guess.
  **Actual root cause, confirmed by directly inspecting `.205`'s etcd
  journal and data directory**: `/data/etcd/member/{wal,snap}` on `.205`
  still held real, persisted data from the earlier botched bootstrap
  (the one that regenerated with `initial-cluster-state: new`) —
  `local-member-cluster-id` baked in at that first bad boot, permanently
  different from `.207`'s real cluster ID. etcd only performs genuine
  join/discovery logic against `--initial-cluster`/
  `--initial-cluster-state` when the data directory is empty; once a WAL
  exists on disk, every subsequent restart just resumes that persisted
  identity, regardless of what flags or config say. Both retries used
  correct flags but neither ever wiped the stale data first, so both
  were doomed to replay the same wrong cluster ID. Fix: `systemctl stop
  etcd` + `rm -rf /data/etcd/member` on `.205`, then re-run `bin/etcd-add
  192.168.1.205` against a truly empty data dir — joined clean on the
  first retry, no incident this time. `etcdctl member list` now shows 2
  started members, `patronictl list` unchanged throughout (same leader,
  same timeline 25, lag 0).
- **Two more runbook gaps found and fixed during this same rollout**,
  both monitoring-only (no etcd/Postgres impact), both root-caused by
  the CA rotation runbook only having reissued `etcd_cert`/`pg_cert`:
  1. `/etc/pki/infra.crt` (the infra/monitoring node's own mTLS client
     cert, `roles/infra/tasks/cert.yml`, tag `infra_cert`) was never
     reissued from the new CA — fixed with `./infra.yml -l 192.168.1.205
     -t infra_cert`.
  2. `/etc/pki/ca.crt` (the node-wide CA trust bundle deployed by
     `roles/node/tasks/cert.yml`, tag `node_ca` — a separate file from
     `/etc/etcd/ca.crt`) was still the pre-rotation CA on both `.205`/
     `.207`, so VictoriaMetrics' scrape client didn't trust etcd's
     now-new-CA-signed server cert and rejected the TLS handshake
     (visible in etcd's own log as `rejected connection ... remote
     error: tls: bad certificate`, and in Grafana as both etcd targets
     showing `down` despite etcd being genuinely healthy). Fixed with
     `./node.yml -l 192.168.1.205,192.168.1.207 -t node_ca` +
     `systemctl restart vmetrics vmalert` on `.205` to pick up the
     refreshed trust bundle.
  `docs/runbook-pg-ca-rotation-etcd-quorum.md` should gain both tags in
  its Phase 3.2 the next time this runbook is written from scratch (the
  witness VM join in Phase 3.5 will need the same two steps, since
  `.197` is new but `.205`/`.207` picking up `.197`'s membership change
  doesn't re-trigger them automatically).
- **`pg-etcd-witness` provisioned + joined (2026-07-30, same session).**
  `terraform/pg-etcd-witness.tf` applied clean (`vm_id=303`, cross-host
  clone from `.165`'s template to `ex-laptop`, 7m14s, 0 unexpected diffs)
  — confirmed reachable via its own dedicated keypair
  (`~/.ssh/id_pg_etcd_witness`, backed up to Infisical as
  `SSH_PG_ETCD_WITNESS_KEY` per `docs/secrets.md`). `./node.yml -l
  192.168.1.197` bootstrapped it as a Pigsty node; `etcd.yml -t
  etcd_cert` + `bin/etcd-add 192.168.1.197` joined it clean on the first
  try (no incident — unlike `.205`, this is a brand-new node with no
  stale data directory to trip over). **Real 3-node etcd quorum is now
  live**: `etcd-1`/`etcd-2`/`etcd-3` all `started`, all 3
  `etcdctl endpoint health` true, Patroni/VIP unaffected throughout
  (same leader, same timeline, lag 0). `floor(3/2)+1` = 2 — tolerates
  any single member going down, the actual goal of this whole ADR.
  Confirmed the CA rotation propagated correctly to the new node without
  the `infra_cert`/`node_ca` gap (fresh node bootstraps get the current
  CA automatically — that gap only affected already-existing nodes that
  predated the rotation).
- **Two incidental fixes made along the way**, both in
  `pigsty/roles/node_monitor/`, not `pigsty.yml` config:
  1. `roles/node_monitor/templates/vector.env` didn't exist in this
     checkout — swallowed by `pigsty/.gitignore`'s blanket `*.env` rule,
     even though it's a static, non-secret asset that ships with
     upstream Pigsty and was already deployed (out-of-band) on
     `.205`/`.207`. Broke `node.yml` for any *new* node (never hit
     before since `.205`/`.207` were never bootstrapped through this
     checkout). Recreated locally with the same content already live on
     `.207` (`VECTOR_OPTS="--config-dir /etc/vector"`) — not committed
     to git (still gitignored), matches how `files/pki/ca/ca.key` is
     also present-locally-but-ignored by design.
  2. Multi-host Ansible runs spanning both `.197` (key: `SSH_PG_ETCD_WITNESS_KEY`,
     user `core`) and `.205`/`.207` (key: `SSH_OLDPG_KEY`, user `vagrant`)
     can't work through a single `ANSIBLE_PRIVATE_KEY_FILE` env var —
     some tasks delegate cross-host (e.g. `node_monitor`'s ping/vector
     registration delegates to the `infra` group host). Fixed by running
     an `ssh-agent` with both keys loaded (`ssh-add`) instead, letting
     ansible/ssh pick whichever identity the target host accepts.
- **Proven 2026-08-15 — unplanned, and it passed.** The end-to-end test
  this ADR exists to enable never had to be scheduled: `.165` went down
  while its room network switch was being replaced, taking the
  then-Leader `.207` and `etcd-1` with it. Outcome:
  - **`.205` promoted automatically** to Leader. Confirmed by the user
    via `patronictl` after recovery.
  - **The `.232` VIP followed** — `arp -a` from a LAN workstation showed
    `.232` resolving to `pg01`/`.205`'s MAC (`bc:24:11:e8:da:d9`), with
    no cluster access needed to see it.
  - **DCS quorum survived** on `etcd-2` (`.205`) / `etcd-3` (`.197`) —
    `floor(3/2)+1` = 2, exactly as designed.

  This is the real proof the rollout worked, obtained from a genuine
  ungraceful host loss rather than a controlled `systemctl stop`, which
  makes it stronger evidence than the planned test would have been.

  **The rejoin was not automatic** and took two manual steps the same day.
  `.207` came back on timeline 27 against the leader's 30 and sat there:
  `remove_data_directory_on_diverged_timelines: false` (a Pigsty default)
  forbids the only recovery Patroni has for a diverged timeline, so it
  logged `no action ... following a leader` indefinitely while the cluster
  ran with **no working standby**. `patronictl reinit` restored the data,
  but replication stayed dead — reinit reuses the existing slot, and
  `pg_proxmox_2` was already `wal_status=lost` from the 61 GiB divergence.
  Dropping the slot let Patroni recreate it; now `streaming`,
  `wal_status=reserved`, lag 0, verified.

  **Operational consequence for this ADR's HA claim:** automatic failover
  works, but automatic *recovery of the demoted node* does not. Every
  ungraceful failover with timeline divergence needs a human to reinit and
  to check the slot afterwards. Until that is done the cluster is
  single-node, and `patronictl list` will not say so — it reported
  `Replica / running` at lag 4 KB the entire time it was disconnected.

  No failback was performed, and none is planned: Patroni is symmetric,
  and `.165` is the host that gets rebooted for gaming (§2), making it
  the *worse* home for the Leader. See `docs/bootstrap-test-notes.md`'s
  2026-08-15 entry for the switch-replacement incident itself.
