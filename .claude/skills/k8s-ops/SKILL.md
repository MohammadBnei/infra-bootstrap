---
name: k8s-ops
description: Operate the live ukubi-cluster (kubectl/helm/ArgoCD) over SSH for test/bootstrap work. Use when the user asks to check cluster/ArgoCD state, debug a sync failure, or drive kubectl/helm against the cluster directly, once they've authorized hands-on execution for the session.
user-invocable: true
allowed-tools:
  - Read
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf get *)
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf describe *)
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf logs *)
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf annotate application * argocd.argoproj.io/refresh=hard --overwrite)
  - Bash(helm show values *)
  - Bash(helm pull * --untar *)
  - Bash(git status *)
  - Bash(git diff *)
---

# /k8s-ops — ukubi-cluster live operations helper

Unlike `ansible-ops`/`terraform-ops` (which only ever print commands for the
user to run), this skill reflects a *different*, explicitly-authorized
workflow: for `ukubi-cluster` test/bootstrap sessions, the user has
authorized running `kubectl`/`helm`/ArgoCD operations directly against the
live cluster. This skill's job isn't to refuse execution — it's to encode
the guardrails that held up when doing this for real, so the same mistakes
don't get repeated. Read `docs/bootstrap-test-notes.md` for the full
incident log this skill is distilled from.

## Access pattern

```bash
ssh -i ~/.ssh/id_k8s_vms core@<node-ip> "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf <cmd>"
```

The key path comes from `inventory/ukubi/hosts.yaml`'s
`ansible_ssh_private_key_file` — read it from there, don't guess a path or
scan `~/.ssh` for candidates.

**Never materialize `/etc/kubernetes/admin.conf` (or any cluster
credential) on the local machine.** Every `kubectl`/`helm` call runs
remotely over SSH. To apply a local manifest, pipe it in rather than
copying the kubeconfig down:

```bash
cat gitops/bootstrap/some-manifest.yaml | ssh -i ~/.ssh/id_k8s_vms core@<ip> \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -"
```

To render a Secret offline (no live cluster contact) and apply it the same
way: `kubectl create secret ... --dry-run=client -o yaml | ssh ... apply -f -`.

## `gitops/bootstrap/*.yaml` does NOT self-sync

There is deliberately no App-of-Apps watching `gitops/bootstrap/`
(`DECISION.md`'s own "no root.yaml" lock, [ADR-0004](../../../docs/adr/0004-gitops-pattern-c-registry-applicationset.md)). That means the ArgoCD self-app,
both ApplicationSets, and any standalone `Application` (e.g.
`traefik-application.yaml`) are only ever applied **once**, manually. Editing
and pushing one of these files changes nothing live until it's re-applied:

```bash
cat gitops/bootstrap/<file>.yaml | ssh -i ~/.ssh/id_k8s_vms core@<ip> \
  "sudo kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f -"
```

Only `gitops/platform/values/*.yaml` auto-syncs (it's pulled via the
Applications' separate git `ref: values` source) — an edit there just needs
a push, no manual re-apply. If a fix "isn't taking effect" after a push,
check which category the edited file falls into before assuming ArgoCD is
broken.

## Always check the real chart schema before writing a values file

**The single most expensive mistake this session**: an entire
`gitops/platform/values/infisical/values.yaml` was nested under a
top-level `infisical:` key that doesn't exist in that chart's schema. Helm
silently accepts unknown top-level keys as dead weight — it does not error.
Every setting in that file (image tag, `kubeSecretRef`, replicaCount,
resources) was a no-op for an entire session, and the symptom (backend
stuck on a bundled Mongo dependency) was chased for a while without anyone
realizing the real values file had never applied at all.

Before writing or editing any platform values file:

```bash
helm repo add <name> <url> && helm repo update <name>
helm show values <name>/<chart> --version <pinned-version>
```

Diff the real top-level keys against what you're about to write. If a
chart's own values are flat (`backend:`, `mongodb:`, etc. at top level, no
wrapper), match that exactly — don't invent a wrapper key that "feels
right."

## ArgoCD sync/refresh mechanics

Force a re-evaluation of an Application after a live manifest re-apply or a
values push:

```bash
ssh ... "sudo kubectl ... -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite"
ssh ... "sudo kubectl ... -n argocd patch application <name> --type merge -p '{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}'"
```

If a ConfigMap change (`argocd-cm`) or an ApplicationSet template edit
doesn't seem to take effect even after refresh, the controller may be
caching settings — restart it:

```bash
ssh ... "sudo kubectl ... -n argocd rollout restart statefulset/argocd-application-controller"
ssh ... "sudo kubectl ... -n argocd rollout restart deploy/argocd-applicationset-controller"
```

## ApplicationSet Go-template: non-string fields are typed strictly, before rendering

A shared list-generator `template:` block is validated against the target
`Application` CRD schema **before** Go-template placeholders are rendered.
String fields (`chartRevision`, `repoURL`, etc.) accept any string
including literal `{{ }}` text, so per-element templating works fine there.
But a `bool`/`int` field (e.g. `helm.skipCrds`) rejects a templated
placeholder outright — `kubectl apply` fails with `must be of type
boolean`, even inside a valid Go-template conditional expression. If one
app in a shared ApplicationSet needs a differing boolean/int value that
others don't, give it its own standalone `Application` manifest instead of
trying to template the shared list — see `traefik-application.yaml` for
the pattern (same wave annotation, same values-repo source, just not
generated from the list).

## `resource.exclusions` matches the object's own apiGroup/kind, not a group named inside its spec

A CRD that *defines* `gateway.networking.k8s.io/HTTPRoute` is itself an
object of kind `CustomResourceDefinition` in group `apiextensions.k8s.io`.
Excluding `apiGroups: [gateway.networking.k8s.io]` in `argocd-cm`'s
`resource.exclusions` does **not** stop ArgoCD from trying to apply that
CRD — check `.status.resources` on the Application to see what's actually
being tracked/attempted before assuming an exclusion took effect.

## Traefik chart: don't set `port:` to 80/443 directly

`ports.<entrypoint>.port` in the Traefik chart is the **container's own**
listen port; the chart's default `securityContext` runs as non-root (UID
65532, capabilities dropped, no `NET_BIND_SERVICE`), so binding a port
below 1024 inside the container fails with `permission denied`. The chart
already exposes 80/443 externally via `exposedPort` while the container
listens on safe defaults (8000/8443 for `web`/`websecure`) — leave `port:`
alone unless there's a specific reason to change the container's internal
listen port.

## Traefik ACME + Gateway API do not mix — don't re-litigate without cert-manager

Confirmed via `traefik/traefik-helm-chart#1467` (open, untriaged) and
`traefik/traefik#11125` (frozen, never implemented): Traefik's built-in
ACME resolver only ever issues certs for `IngressRoute`/`Ingress`. Gateway
API listeners can only get certs from a pre-existing `Secret`
(`certificateRefs`), which only cert-manager (or an equivalent, bespoke,
unmaintained bridge) can produce. This is why [ADR-0001](../../../docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md) locks
`IngressRoute`, not Gateway API, for app routing. Don't propose reverting
to Gateway API for app HTTPS routing without also proposing cert-manager —
and cert-manager is separately forbidden (same ADR-0001).

## Destructive/ambiguous actions: always confirm first

Even with hands-on execution authorized, these still stop and ask rather
than proceed:
- Deleting any cluster-scoped resource (CRDs especially) not created in
  the current session.
- Choosing a storage or database backend (NFS vs. local-path-provisioner,
  etc.) — these are architecture decisions, not bug fixes.
- Any Postgres/Pigsty role or ownership mutation (see below) — confirm the
  current state read-only first, then confirm the fix with the user before
  running it.

## Pigsty: database-level `owner:` doesn't fix pre-existing table ownership

`pg_databases[].owner` in `pigsty.yml` only runs `ALTER DATABASE ... OWNER
TO ...` — the database object's own owner attribute. It does **not**
retroactively change ownership of tables already created inside it under a
different role. A migration failing with `must be owner of table X` means
some earlier process (a prior migration attempt, a manual `psql` session)
created that table under a different role than the app currently connects
as. Confirm the actual current owner first (read-only:
`information_schema.tables` / `\dt+`), then the bulk fix — run as a
superuser — is:

```sql
REASSIGN OWNED BY <current_owner> TO <intended_owner>;
```

not a per-table `ALTER TABLE ... OWNER TO`.

## Git staging safety

Always run `git diff --cached --stat` right before committing, especially
after any file rename. `git add path1 path2 path3` aborts the **entire**
command (stages nothing) if even one pathspec doesn't match anything on
disk — this can silently produce an empty or rename-only commit if the
diffstat isn't checked first.
