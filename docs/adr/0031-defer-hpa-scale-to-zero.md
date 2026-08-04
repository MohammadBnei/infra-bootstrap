# ADR-0031: Defer Kubernetes-native HPA scale-to-zero for user apps

**Status:** Rejected (for now — revisit once the feature reaches beta/GA)

## Context

The user asked to implement Kubernetes's native HPA scale-to-zero for
user apps in `gitops/`, default off. Three facts surfaced during
research:

1. **Version mismatch.** This cluster's inventory pins `kube_version:
   1.35.4` (`inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml:2`),
   matching `CLAUDE.md`. HPA scale-to-zero ships in Kubernetes 1.36, not
   1.35.4. Reaching it needs a kubespray submodule bump — its own PR per
   `DECISION.md` §1, never combined with inventory edits — plus a real
   `cluster.yml`/upgrade run.
2. **Alpha, not stable.** In 1.36, `HPAScaleToZero` is Alpha: off by
   default, requires an explicit feature gate on kube-apiserver and
   kube-controller-manager, and carries no compatibility guarantee
   before graduating (tracked informally toward 1.37 beta).
3. **Scale-up still needs an external signal, and there's no cold-start
   buffering.** HPA can only scale *up* from zero using an External or
   Object metric — CPU/memory can't be sampled with zero pods running.
   Nothing in this cluster exposes one today: `common-app-chart` has no
   `HorizontalPodAutoscaler` template, and while Prometheus is already in
   the stack, `prometheus-adapter` (or an equivalent metrics source) is
   not. Separately, stock Kubernetes has no request-buffering proxy in
   front of a scaled-to-zero Service — Knative's activator or KEDA's
   HTTP add-on solve that; plain HPA doesn't. Any HTTP-fronted app scaled
   to zero would drop/timeout the first request(s) during the scale-up
   window rather than have them queued transparently.

## Decision

Defer. Do not bump this cluster to 1.36 or add HPA scale-to-zero
support to `common-app-chart` solely to chase an alpha feature. Revisit
once `HPAScaleToZero` reaches beta/GA. When revisited, it needs, at
minimum:

- a kubespray version-bump PR to reach the target Kubernetes version
  (`DECISION.md` §1 — separate from any inventory edit);
- a metrics-source decision — `prometheus-adapter` was the only
  candidate discussed, since Prometheus is already deployed and no new
  dependency beyond it would be required; and
- an explicit call on scope: worker/queue-style apps (e.g. agent-fleet
  workers, where a cold-start delay before processing is harmless) are a
  reasonable fit for stock HPA scale-to-zero, but HTTP-fronted apps
  (dashboards, web UIs) are not, without also adopting a request-buffering
  layer such as Knative or KEDA's HTTP add-on — both of which are new
  dependencies requiring their own ADR and explicit user greenlight.

## Consequences

No `HorizontalPodAutoscaler` template is added to
`gitops/platform/common-app-chart/`. User apps keep the existing static
`replicaCount` in their `values.yaml`. This is documentation-only — no
chart, GitOps, or infra changes accompany this ADR.
