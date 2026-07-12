---
name: mission-drift
description: Audit the working tree against DECISION.md's locked decisions, docs/adr/ statuses, and the known-drift log. Use when the user asks to check for drift, verify DECISION.md/ARCHITECTURE.md are still accurate, or audit the repo against its own rules before a cluster.yml/pigsty run.
user-invocable: true
allowed-tools:
  - Read
  - Grep
  - Bash(git status *)
  - Bash(git diff *)
---

# /mission-drift — audit working tree vs DECISION.md + docs/adr/

Report-only. Per `DECISION.md` §5, locked decisions get updated in
`DECISION.md`/`docs/adr/` *first*, deliberately — this skill's job is to
surface contradictions between those files and the working tree (in
**either** direction — their own drift notes can go stale too), not to
silently resolve them.

## Checks

Run all of these; report every check even if clean, so the output doubles
as a "yes this was actually verified" record, not just a list of problems.

1. **cert-manager toggle** — read
   `inventory/ukubi/group_vars/k8s_cluster/addons.yml`, check
   `cert_manager_enabled`. `DECISION.md` §4 currently claims this is `true`
   and needs fixing to `false` — verify against the actual file value and
   report whichever is stale (the code or the `DECISION.md` note).

2. **Kubespray version alignment** — [ADR-0015](../../../docs/adr/0015-kubespray-inventory-submodule-version-alignment.md)
   says the inventory is still authored against kubespray v2.23 var names
   and blocks running `cluster.yml` until ported to v2.31.0.
   `inventory/ukubi/README.md` "Current status" may claim this port is
   already done. Report any contradiction explicitly; don't assume either
   is correct — spot-check a few `group_vars/k8s_cluster/*.yml` keys
   against what kubespray v2.31.0's `contrib/inventory_builder`/sample
   inventory expects if unsure, and say so if you can't fully confirm from
   static reading alone. If resolved, the ADR's status should move from
   `Proposed` to `Accepted` and get picked up by `DECISION.md`.

3. **Legacy inventory** — does `inventory/mycluster/` still exist?
   `DECISION.md` §4 flags it for deletion. Report presence/absence, don't
   delete it.

4. **Registry ↔ ApplicationSet parity** — diff every entry in
   `gitops/apps/registry.yaml` against
   `gitops/bootstrap/apps.applicationset.yaml`'s
   `spec.generators[0].list.elements` (name/namespace/syncWave/repoURL/
   valuesPath/hostname). Same check as `add-app`'s step 0 — reuse it
   rather than re-deriving the comparison logic.

5. **Forbidden-pattern grep** — search the working tree (excluding
   `kubespray/`, `pigsty/`, `k8s-cluster/` submodules/vendored dirs, which
   have their own upstream content) for signals from `DECISION.md` §3's
   "do not propose" list: `cert-manager`, `kind: Ingress` (plain, not
   `IngressRoute`), `ingress-nginx`, `HTTPRoute` / Gateway API resources
   for app routing (rejected per
   [ADR-0001](../../../docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md) —
   note `IngressRoute` itself is the *accepted* pattern, don't flag it),
   `wireguard`, `tailscale`, a second `Chart.yaml` outside
   `gitops/platform/common-app-chart` under `gitops/`, an app-of-apps
   `root.yaml`. A hit isn't automatically a violation (could be a comment
   explaining why something is forbidden) — read the context before
   flagging.

6. **Open questions** — list every ADR under `docs/adr/` whose `Status` is
   `Proposed` (read `docs/adr/README.md`'s index table, or grep each file's
   `**Status:**` line) as a reminder checklist; don't try to resolve them,
   they're explicitly open until a fresh ADR status change lands.

## Output format

One line per check: ✅ clean / ⚠️ drift found — with the file(s) and
`DECISION.md` section or ADR number involved. End with a short punch list
of anything that needs a `DECISION.md`/ADR update or a working-tree fix,
and which direction (the doc is wrong vs. working tree is wrong) — leave
the actual edit to the user.
