---
name: mission-drift
description: Audit the working tree against MISSION.md's locked decisions, forbidden patterns, and known-drift log. Use when the user asks to check for drift, verify MISSION.md is still accurate, or audit the repo against its own rules before a cluster.yml/pigsty run.
user-invocable: true
allowed-tools:
  - Read
  - Grep
  - Bash(git status *)
  - Bash(git diff *)
---

# /mission-drift — audit working tree vs MISSION.md

Report-only. Per MISSION.md §16, locked decisions get updated in
MISSION.md *first*, deliberately — this skill's job is to surface
contradictions between MISSION.md and the working tree (in **either**
direction — MISSION.md's own drift notes can go stale too), not to
silently resolve them.

## Checks

Run all of these; report every check even if clean, so the output doubles
as a "yes this was actually verified" record, not just a list of problems.

1. **cert-manager toggle** — read
   `inventory/ukubi/group_vars/k8s_cluster/addons.yml`, check
   `cert_manager_enabled`. MISSION.md §14 currently claims this is `true`
   and needs fixing to `false` — verify against the actual file value and
   report whichever is stale (the code or the MISSION.md note).

2. **Kubespray version alignment** — MISSION.md §4 says the inventory is
   still authored against kubespray v2.23 var names and blocks running
   `cluster.yml` until ported to v2.31.0. `inventory/ukubi/README.md`
   "Current status" claims this port is already done ("Q-D resolved").
   Report this contradiction explicitly; don't assume either is correct —
   spot-check a few `group_vars/k8s_cluster/*.yml` keys against what
   kubespray v2.31.0's `contrib/inventory_builder`/sample inventory expects
   if unsure, and say so if you can't fully confirm from static reading
   alone.

3. **Legacy inventory** — does `inventory/mycluster/` still exist? MISSION
   §14 flags it for deletion. Report presence/absence, don't delete it.

4. **Registry ↔ ApplicationSet parity** — diff every entry in
   `gitops/apps/registry.yaml` against
   `gitops/bootstrap/apps.applicationset.yaml`'s
   `spec.generators[0].list.elements` (name/namespace/syncWave/repoURL/
   valuesPath/hostname). Same check as `add-app`'s step 0 — reuse it
   rather than re-deriving the comparison logic.

5. **Forbidden-pattern grep** — search the working tree (excluding
   `kubespray/`, `pigsty/`, `k8s-cluster/` submodules/vendored dirs, which
   have their own upstream content) for signals of MISSION.md §13's
   forbidden list: `cert-manager`, `IngressRoute`, `kind: Ingress`,
   `ingress-nginx`, `wireguard`, `tailscale`, a second `Chart.yaml` outside
   `gitops/platform/common-app-chart` under `gitops/`, an app-of-apps
   `root.yaml`. A hit isn't automatically a violation (could be a comment
   explaining why something is forbidden) — read the context before
   flagging.

6. **Open questions** — list MISSION.md §15's Q-B through Q-G verbatim as
   a reminder checklist; don't try to answer them, they're explicitly
   "under decision, do not commit without greenlight."

## Output format

One line per check: ✅ clean / ⚠️ drift found — with the file(s) and
MISSION.md section involved. End with a short punch list of anything that
needs a MISSION.md update or a working-tree fix, and which direction
(MISSION.md is wrong vs. working tree is wrong) — leave the actual edit to
the user.
