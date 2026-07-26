# ADR-0020: PVE corosync cluster (not 3 independent standalone hosts)

**Status:** Accepted

## Context

`DECISION.md` §2 already locks that `.200` and `.161` are added as PVE
hosts alongside `.165` — but not *how* the 3 PVE instances relate to each
other. No prior ADR addressed this. Terraform's `bpg/proxmox` provider
currently talks to a single PVE API endpoint (`.165`); how it reaches
`.200`/`.161` depends entirely on this choice.

Two options:
- **3 independent standalone PVE hosts.** Each keeps its own API/token
  (matching `ARCHITECTURE.md` §8's "API tokens per host" phrasing).
  Terraform would need a `provider "proxmox"` alias per host (3 endpoints).
  No live migration between hosts, no shared quorum/corosync concerns —
  `.161`'s sleep risk (ADR-0013) only ever affects its own VMs.
- **One corosync-clustered PVE datacenter.** `.165`/`.200`/`.161` join via
  `pvecm`, sharing one API surface — Terraform keeps a single provider
  block; only `node_name` (per-resource) varies. Live migration works via
  `qm migrate --with-local-disks` (no shared storage needed — orthogonal
  to ADR-0002's Ceph rejection). `.161` becomes a quorum-voting member: 3
  nodes tolerates 1 offline (2/3 still quorate), so a sleeping laptop
  doesn't sink cluster quorum on its own.

## Decision

Join as one corosync cluster. `.165` stays the founding member; `.200`
and `.161` `pvecm add` onto it (`docs/runbook-pve-postinstall.md`,
`ansible/playbooks/pve-postinstall.yml`), sequentially, one at a time.

This does **not** imply Ceph or any shared storage — clustering and
storage are orthogonal, and ADR-0002 (Longhorn over Ceph) stays as-is.
It does **not** imply a multi-master K8s control plane either —
ADR-0017 (2nd control-plane/etcd member) remains a separate, still-open
question.

## Consequences

- Terraform's `k8s_nodes` variable (`terraform/variables.tf`) gains
  optional `node_name`/`datastore_id` fields per entry, defaulting (via
  `coalesce`) to the existing single-host variables so `.165`-only usage
  is unaffected.
- Corosync rides the existing flat-LAN NIC — no dedicated ring network at
  this scale; accepted homelab risk, not a blocker.
- `.161` sleeping no longer risks losing PVE quorum outright (2-of-3
  majority survives), but ADR-0013's suspend-disable mitigation still
  applies for its own VM availability.
