# ADR-0021: Self-syncing `gitops/bootstrap/` directory (scoped App-of-Apps)

**Status:** Accepted

## Context

`gitops/bootstrap/` holds the ApplicationSets (`apps.applicationset.yaml`,
`platform.applicationset.yaml`, `platform-common-apps.applicationset.yaml`)
and standalone Applications (`argocd-application.yaml`,
`traefik-application.yaml`) that define everything running on the
cluster — both platform apps and user apps. Per `gitops/README.md`'s
bootstrap sequence, this directory was only ever applied by hand:
`kubectl apply -f gitops/bootstrap/`, once, at cluster genesis.

In practice that means every edit to this directory after bootstrap —
onboarding a new user app, adding a platform component — needs a manual
`kubectl apply` to actually take effect; a merged PR alone does nothing.
This was hit directly onboarding `editable-blog` as a user app: the
registry + ApplicationSet files were correct in git, but nothing changed
on the cluster until re-applied by hand.

ADR-0004 rejected "App-of-Apps with an explicit `root.yaml`" as part of
adopting Pattern C. That rejection was about how *individual apps* get
deployed (registry.yaml + `list` generator beats a root Application
spawning child Applications one-by-one) — it was not a decision to keep
the bootstrap manifests themselves un-automated. That gap was simply
never addressed.

## Decision

Add one Application, `gitops/bootstrap/bootstrap-application.yaml`,
whose source is the `gitops/bootstrap/` directory itself (plain
manifests, non-recursive — `traefik-crds/` is a subdirectory and so is
already excluded by default, matching its existing out-of-band handling
for the same reason as `traefik-application.yaml`'s `skipCrds`).
`automated: {prune: true, selfHeal: true}`, same retry policy as every
other Application here.

This **narrows, not reverses**, ADR-0004's rejection: Pattern C's actual
app-deployment mechanism (`apps/registry.yaml` + `list` generator +
`common-app-chart`) is unchanged — this only makes the bootstrap
directory's *own* manifests self-sync instead of requiring a manual
re-apply after every merge. It's a single flat directory, not a
multi-level hierarchy, and it doesn't spawn per-app Applications the way
a rejected root.yaml would have.

The Application is bootstrapped once by hand (`gitops/README.md` Step 3,
same one-time nature as installing ArgoCD itself in Step 1) — after
that it manages itself too: future edits to
`bootstrap-application.yaml` sync automatically like everything else in
the directory.

## Consequences

- Editing anything in `gitops/bootstrap/` and merging to `main` is now
  enough — ArgoCD picks it up on its next poll/webhook, no manual
  `kubectl apply` step.
- `DECISION.md` §3's "App-of-Apps with an explicit `root.yaml`" bullet is
  qualified to point here instead of being a blanket rejection.
- `gitops/README.md`'s bootstrap sequence Step 3 changes from "run this
  every time this directory changes" to "run this once, ever."
