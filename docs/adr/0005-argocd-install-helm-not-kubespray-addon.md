# ADR-0005: Install ArgoCD via Helm, not the kubespray addon

**Status:** Accepted

## Context

kubespray ships an `argocd_enabled` addon path that installs ArgoCD as
part of the cluster bootstrap playbook run. Coupling ArgoCD's lifecycle
and version to kubespray's release cadence is undesirable — ArgoCD
upgrades should be independent of cluster-provisioning runs.

## Decision

Install ArgoCD via Helm, after kubespray has finished:

```
helm install argocd argo/argo-cd -n argocd --create-namespace
```

Bootstrap once with `kubectl apply -f bootstrap/{argocd-application,
applicationset}.yaml`. After that one-time step, the cluster is
gitops-driven — the `argocd` Application manages ArgoCD's own upgrades
going forward.

## Consequences

- `argocd_enabled: true` in kubespray inventory group_vars is never set
  for this cluster — flip it back to `false` if it's ever found set (see
  `DECISION.md` Known Drift).
- ArgoCD version bumps are a GitOps change (edit the `argocd` Application
  source), not a kubespray/ansible change.
