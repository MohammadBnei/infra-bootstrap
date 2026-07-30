# ADR-0017: Second and third control-plane / etcd member

**Status:** Accepted

## Context

Original design was single control-plane + single etcd, stacked
(`etcd_deployment_type: kubeadm`, static pod managed by kubelet). Adding
more CP/etcd members became a real option once `.200`/`.161` joined the
PVE corosync cluster (ADR-0020).

The forcing function: `k8s-cp-01` lives on `.165`, the one PVE host that
gets deliberately rebooted (dual-boot Windows for gaming) — a single-CP
design means every such reboot is a full control-plane (and API) outage.
`server1`/`ex-laptop` don't carry that risk.

## Decision

Go straight to **3** CP/etcd members, not 2 — etcd quorum is
`floor(N/2)+1`; at N=2 that's still 2, meaning *both* have to be up,
strictly worse than the current single member. 3 tolerates losing any
one. Placement is deliberate, not arbitrary: 2 members on the stable
hosts, `k8s-cp-01` (.165) as the 3rd, minority member — so losing `.165`
specifically never costs quorum.

| Node | Host | Spec |
|---|---|---|
| `k8s-cp-01` (existing) | `.165` | 2 vCPU / 4GB |
| `k8s-cp-02` (new) | server1 | 2 vCPU / 4GB |
| `k8s-cp-03` (new) | ex-laptop | 2 vCPU / 4GB |

Adding these means **re-running `cluster.yml` against the updated
inventory — not `scale.yml`**, since `scale.yml` doesn't include the
control-plane join role.

Paired with this: a kube-vip floating VIP across all 3 (ADR-0016) so
external `kubectl`/CI access survives `.165` being down too — internal
traffic (kubelets, ArgoCD) already fails over on its own via kubespray's
per-node apiserver proxy and standard k8s Service endpoints.

## Consequences

- `terraform.tfvars`'s `k8s_nodes` map gains `k8s-cp-02`/`k8s-cp-03`.
  `k8s-cp-03`'s `datastore_id` is `local-lvm` (ADR-0028 — no dedicated
  ZFS pool on ex-laptop after all); both new entries' `node_name`s should
  be confirmed live via `pvesh get /nodes` before `terraform apply`,
  per this repo's usual discipline.
- `ARCHITECTURE.md` §2's node table needs these 2 rows added.
- Real rollout requires a `cluster.yml` run against the 3-CP inventory —
  the user's own action, not something run unattended from this repo's
  agent sessions.
