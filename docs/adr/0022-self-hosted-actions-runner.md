# ADR-0022: Self-hosted GitHub Actions runner in-cluster

**Status:** Accepted
**Amended by:** [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md)
— image builds do **not** run in this pod. They run on the `build-runner`
LXC, outside the cluster entirely, precisely so this runner's identity (a
projected SA token with `create jobs` in `vos`/`vos-dev`) is never inherited
by arbitrary `Dockerfile` execution. (ADR-0034 first specified a separate
in-cluster Deployment; that failed live — buildah cannot extract image
layers without `CAP_SYS_ADMIN` — and moving out of the cluster strengthened
the separation rather than weakening it.) The scope described below is
unchanged. Note both runners share one `ACCESS_TOKEN`, so revoking it stops
`oneOffJobs` as well as builds.

## Context

The new `oneOffJobs` mechanism (see ADR-0023) needs CI to trigger a
`kubectl create job --from=cronjob/...` and poll it for completion — i.e.
CI needs to talk to the cluster's Kubernetes API.

No existing workflow in this repo or any app repo (`vos-monolith` included)
touches the cluster directly today — every one only builds/pushes images
and commits tag bumps back to git; ArgoCD (polling from outside) does the
actual apply. GitHub-hosted runners (`ubuntu-latest`) genuinely cannot
reach the API server to do this: the API server only has LAN-only
`.bnei.lan` names (`ARCHITECTURE.md`'s DNS table; `k8s.bnei.lan` →
`192.168.1.180` per ADR-0016), only `*.bnei.dev` HTTP(S) is forwarded
through the Freebox to Traefik, and ADR-0009 already rejected
Wireguard/Tailscale for remote cluster access. There is no existing path
in or out for this.

## Decision

Deploy a GitHub Actions **self-hosted runner as a pod in ukubi-cluster**,
labeled `ukubi` so workflows opt in via `runs-on: [self-hosted, ukubi]`
(only `reusable-oneoff-job.yml` uses it — every other workflow keeps
running on `ubuntu-latest`, nothing else needs cluster access).

Uses an **in-cluster `ServiceAccount`**, scoped via RBAC to exactly the
namespaces that actually need it (`vos`, `vos-dev` today — extend per-app
as more apps adopt `oneOffJobs`), with only the verbs the reusable
workflow actually calls:

- `create`, `get`, `list`, `watch` on `jobs`
- `get` on `pods`, `pods/log`

No `ClusterRole`, no Secret read access, no access to `argocd`/other
namespaces. `kubectl` auto-detects in-cluster config via the pod's
projected SA token — no kubeconfig or credential ever leaves the cluster,
and nothing needs to be stored as a GitHub secret for this.

## Alternatives considered

- **Expose the API server externally** (new Freebox port-forward + public
  DNS distinct from the `.bnei.lan` names), authenticate GitHub-hosted
  runners with a scoped `ServiceAccount` token as a GitHub encrypted
  secret. Rejected: opens a permanent public path to the Kubernetes API —
  a materially larger attack surface than anything currently exposed
  (today only HTTP(S) via Traefik is forwarded) — and cuts against
  ADR-0009's rejection of remote cluster access more broadly.
- **Defer CI automation, trigger one-off jobs by hand instead.** Viable as
  an interim fallback (a human runs the same `kubectl create job
  --from=cronjob/...` primitive manually — no worse than today's manual
  `make oneoff-job` flow) but does not satisfy the actual requirement
  (automated trigger + feedback, no manual step).

## Consequences

- New infrastructure to maintain: a runner deployment/RBAC in
  `gitops/platform/`, distinct from every other platform app in that it
  holds (scoped) write access to live namespaces rather than being purely
  passive.
- RBAC scope must be revisited every time a new app's `oneOffJobs` gets
  wired into the reusable workflow — the `Role` needs that app's namespace
  added, it isn't automatically cluster-wide.
- If the runner pod goes down, `oneOffJobs` triggering stalls (the ledger
  just stays "pending" — no data loss, matches the retry-on-next-push
  design in ADR-0023) but hooks/Deployments/everything else ArgoCD manages
  is unaffected — this only touches the one new trigger path.
