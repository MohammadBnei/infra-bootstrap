# ADR-0032: `thot`'s cluster-wide RBAC scope and Alertmanager routing

**Status:** Accepted

## Context

`agent-fleet`'s own ADR-0035 (`agent-fleet/docs/adr/0035-thot-cluster-agent.md`)
made the design decision to add `thot`, a standing cluster agent with its
own Kubernetes RBAC — the *why* is recorded there and not re-derived here
(a second, independently-deployed RBAC holder alongside `provisioner`, a
deliberate, accepted reopening of the trust-domain-separation principle
`agent-fleet`'s own ADR-0012 established, mitigated by live per-call
human confirmation). That ADR explicitly deferred the concrete RBAC verb/
resource enumeration and the Alertmanager wiring to an infra-bootstrap-
side decision, since both are genuinely this repo's own trade-offs to
make — same split `actions-runner` (ADR-0022) needed and
`e2e-provisioner`/`provisioner` didn't (their infra-bootstrap footprint
was purely mechanical, no independent alternatives worth recording here).

Unlike `actions-runner` (namespaced `Role`s, `vos`/`vos-dev` only) or
`node-drainer` (a `ClusterRole` scoped to exactly `kubectl drain`'s
verbs), `thot` genuinely needs to read across the whole cluster — its job
is answering "why did this break" for *any* namespace, not one
known-in-advance target. That's a materially wider standing grant than
anything else in this cluster, which is exactly why it needs its own ADR
rather than a quick copy of an existing manifest.

## Decision

**Namespace:** `thot` gets its own namespace (not `agent-fleet`'s,
unlike `provisioner` which shares it) — it holds a distinct standing
credential, its own Discord bot identity, and its own git identity, none
of which belong under `agent-fleet`'s existing footprint.

**RBAC — one `ClusterRole`, two grants, deployed via
`gitops/platform/thot/rbac.yaml`:**

| Verbs | Resources | Why |
|---|---|---|
| `get`, `list`, `watch` | `pods`, `deployments`, `statefulsets`, `daemonsets`, `replicasets`, `jobs`, `cronjobs`, `services`, `events`, `nodes`, `configmaps`, `persistentvolumeclaims`, `ingressroutes.traefik.io`, `middlewares.traefik.io`, `applications.argoproj.io` | Diagnostic read, cluster-wide — this is the actual "inspect state, answer why did this break" capability |
| `patch` | `deployments`, `statefulsets`, `daemonsets` | Covers `kubectl rollout restart`'s real mechanism (a template-annotation patch — there is no separate "restart" verb in the Kubernetes API) |
| `delete` | `pods` | Covers "delete a crashlooping pod" |

**Explicitly excluded, as a manifest boundary, not just prose** (restates
agent-fleet ADR-0035's constraint as the actual RBAC object, the thing
that's checkable, not just documented intent):

- No `rbac.authorization.k8s.io` API group in any verb (`roles`,
  `clusterroles`, `rolebindings`, `clusterrolebindings`) — no
  self-escalation path for a component that already holds unusually
  broad standing access.
- No `secrets` in any verb, any resource.
- No `nodes` `patch`/`update`/`delete`, no `pods/eviction` — both stay
  exclusively `node-drainer`'s territory; `thot` can *read* node state
  (already in the read grant above, for diagnosis) but never mutates it.

This mirrors `node-drainer`'s own precedent (deliberately not
cluster-admin despite broader access being available on the host it runs
on, narrowly scoped to exactly the verbs its one job needs) — `thot`'s
grant is wider because its job is wider (diagnose *anything*, not drain
one node), but the same "narrow and explicit, not broad-because-easier"
discipline applies.

**Alertmanager routing** (`gitops/platform/values/prometheus/values.yaml`):
add a new `webhook_configs` receiver (`thot`, pointing at
`http://thot.thot.svc.cluster.local:<port>/alertmanager-webhook`) and a
`route.routes[]` entry with `continue: true` so the existing `discord`
receiver keeps receiving every alert unchanged — `thot` is additive
fan-out, not a replacement or a filter. (`receivers:` list-replaces the
chart's own defaults; `"null"` stays redeclared, same gotcha this file's
existing `discord` receiver already documents.) Refine to
severity-based routing later only if the unfiltered fan-out proves
noisy in practice — not designed preemptively for a problem that hasn't
been observed yet.

**NetworkPolicy** (`gitops/platform/thot/networkpolicy.yaml`): ingress
scoped to exactly `agent-fleet`'s namespace (worker sidecars dialing
`thot`'s gRPC port directly) and, once the Alertmanager receiver above
is wired, the `monitoring` namespace (Alertmanager's webhook POST) — no
broader ingress than those two callers.

## Alternatives considered

- **Namespaced `Role`s per target namespace, `actions-runner`-style** —
  rejected: `thot`'s whole value proposition is answering questions
  about *any* namespace, not a fixed known set; a per-namespace `Role`
  would need editing every time a new app namespace is added, which
  defeats the "no redeploy needed" spirit the rest of this fleet's
  dashboard-editable entities already have.
- **Cluster-admin, matching the existing `k9s-dashboard` human-SSH path's
  own grant** — rejected: `thot` is a standing, alert/schedule-triggered,
  agent-fleet-summoned identity, not a human-initiated session; granting
  it the same blast radius as the human's own break-glass access
  multiplies the risk of the exact trust-domain-merge agent-fleet's
  ADR-0035 already named as an accepted-but-bounded risk, not an
  unbounded one.
- **Severity-filtered Alertmanager routing from day one** (only route
  `critical` alerts to `thot`) — rejected for v1: no data yet on what
  `thot` actually needs to see to be useful; fan-out-to-both is cheap to
  narrow later and expensive to have guessed wrong upfront.

## Consequences

- `thot` becomes the cluster's single broadest *read* grant that isn't
  literally the human operator's own cluster-admin kubeconfig — worth
  knowing when reasoning about blast radius of a compromised `thot` pod
  (RBAC excludes secrets/self-escalation/node-mutation, but a compromised
  `thot` could still read the full shape of every workload in the
  cluster).
- The Alertmanager `receivers:`/`route.routes[]` block in
  `values/prometheus/values.yaml` grows past a single-receiver shape for
  the first time — future alert-routing changes need to account for two
  receivers, not one.
- `gitops/platform/thot/` is a fourth standalone plain-manifest
  Application (after `actions-runner`, `e2e-provisioner`,
  `provisioner`) — the pattern is now well-established, not a one-off.
