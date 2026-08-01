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
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf rollout restart *)
  - Bash(ssh -i ~/.ssh/id_k8s_vms core@* sudo kubectl --kubeconfig /etc/kubernetes/admin.conf rollout status *)
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

**3 control-plane nodes as of 2026-07-30** (`k8s-cp-01`/`.201`,
`k8s-cp-02`/`.204`, `k8s-cp-03`/`.206` — ADR-0017), any of them works as
the SSH target for the pattern above. There's also now a kube-vip VIP,
`192.168.1.180`/`k8s.bnei.lan` (ADR-0016) — confirmed live, cert SANs
include both — but that's an *API server* endpoint (`:6443`, for a real
kubeconfig/`kubectl` client), not an SSH target; this skill's pattern
still SSHes to a specific node and runs `kubectl` there.

**Control-plane/etcd/kubelet config that traces back to a kubespray
inventory var: fix the var + rerun kubespray with narrow `--tags`, don't
hand-patch the live static pod manifest.** A hand patch to
`/etc/kubernetes/manifests/*.yaml` works immediately but isn't persisted
anywhere kubespray knows about — the next node rebuild/rejoin (or a future
`cluster.yml` run) regenerates that manifest from the inventory vars and
silently drops the patch. Confirmed 2026-08-01: `k8s-cp-01`'s etcd static
pod had `--listen-metrics-urls=http://0.0.0.0:2381` (someone's prior hand
patch, never added to `inventory/ukubi/group_vars/`), while `k8s-cp-02`/
`k8s-cp-03` — rejoined after a `.165` Proxmox-host outage — came back with
kubeadm's own default (`127.0.0.1`-only), breaking Prometheus's etcd
metrics scrape (`etcdMembersDown`/`etcdInsufficientMembers`/`TargetDown`
firing) even though etcd's actual raft/quorum was healthy the whole time.
The durable fix was adding `etcd_listen_metrics_urls: "http://0.0.0.0:2381"`
to `inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml` (same pattern
already used for `kube_proxy_metrics_bind_address` from a near-identical
2026-07-29 incident) and re-running kubespray scoped to
`--tags control-plane` (see `ansible-ops` skill for the invocation) — not
`sed`-ing the manifest on the two drifted nodes. Live `kubectl`/manifest
patches in this skill are for ArgoCD/Application state and one-off
diagnostics, not for anything kubeadm/kubespray regenerates from inventory.

**A ConfigMap change doesn't apply to running pods just because `kubectl
apply` succeeded.** DaemonSets/Deployments read their mounted ConfigMap
via kubelet's own sync (can take a while) or a `reload`-plugin-style
in-process poll (CoreDNS/nodelocaldns have one, still not instant). If you
need to *confirm* a config change took effect now rather than "eventually,
unconfirmed" — `kubectl rollout restart <daemonset|deployment>/<name> -n
<ns>` then `kubectl rollout status ... --timeout=60s`, and re-test.
Confirmed this the hard way 2026-07-30 (CoreDNS/nodelocaldns `dns_upstream_forward_extra_opts`
change) — see `docs/bootstrap-test-notes.md`.

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

## `gitops/bootstrap/*.yaml` DOES self-sync (as of ADR-0021)

A standalone `bootstrap` Application
(`gitops/bootstrap/bootstrap-application.yaml`, [ADR-0021](../../../docs/adr/0021-self-syncing-bootstrap-directory.md)) watches the
`gitops/bootstrap/` directory itself (plain manifests, non-recursive —
`traefik-crds/` is excluded the same way `traefik-application.yaml`
excludes it), tracking `main`, `automated: {prune: true, selfHeal: true}`.
Confirmed live: `kubectl get application -n argocd bootstrap` shows
`spec.source.path: gitops/bootstrap`, `targetRevision: main`, and that
automated policy.

That means editing any file in `gitops/bootstrap/` (an ApplicationSet, a
standalone `Application`, an `IngressRoute`) and merging to `main` is
enough — ArgoCD picks it up on its next poll/webhook, no manual `kubectl
apply` needed. The **only** one-time manual step left is bootstrapping
`bootstrap-application.yaml` itself, once, at cluster genesis (`gitops/
README.md` Step 3) — after that it manages itself too, including its own
future edits.

ADR-0004's "no root.yaml" rejection is about *how individual apps get
deployed* (registry.yaml + `list` generator beats a root Application
spawning per-app children one-by-one) — Pattern C's actual app-deployment
mechanism is unchanged. ADR-0021 only makes the bootstrap directory's own
manifests self-sync; it doesn't reverse ADR-0004.

`gitops/platform/values/*.yaml` also auto-syncs (pulled via the
Applications' separate git `ref: values` source) — same "just push" story.
If a fix "isn't taking effect," check `kubectl get application -n argocd
bootstrap` for `OutOfSync` (still waiting on ArgoCD's poll/webhook or a
merge to `main`) before assuming something is broken.

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

**Second confirmed instance (Loki, 2026-07-29)**: `lokiCanary` was nested
under `monitoring:` in `gitops/platform/values/loki/values.yaml` — same
silent-no-op failure mode as the Infisical case above, the canary
DaemonSet kept deploying despite looking disabled. `helm show values` is
what caught it; `yq`/YAML-lint alone never will, since the file is
perfectly valid YAML, just structurally wrong for that chart.

`helm template` against the real chart catches a different, narrower
class of bug than the one above: **structural rejections the chart's own
templates enforce**, not just unknown-key no-ops. Loki's `validate.yaml`
hard-fails if `singleBinary.replicas` is nonzero alongside any nonzero
SimpleScalable-mode replica (`write`/`read`/`backend` all default to
`3`, not `0`) — `helm template` surfaces this immediately (`You have more
than zero replicas configured for both the single binary and simple
scalable targets`), `yq` does not. Zero all three explicitly when running
SingleBinary mode.

**`helm template` still isn't sufficient for everything** — see the
Grafana contact-point gotcha below, which is an app-level runtime
validation error, not a Helm templating error. `.github/workflows/lint.yml`'s
`gitops` job only `helm template`s the local `common-app-chart`; it does
not render the third-party charts (`loki`, `alloy`, `grafana`,
`prometheus`, ...) that `platform.applicationset.yaml` actually deploys —
worth doing by hand (`helm pull --untar` + `helm template -f
gitops/platform/values/<name>/values.yaml`) before pushing a values
change to any of those, not just trusting CI.

## Grafana `slack` contact-point type: `url` goes under `settings`, not `secureSettings`

Confirmed live (2026-07-29 incident, PRs #55/#56): this chart's Grafana
version (11.4.0) rejects a contact point provisioning file outright at
startup if `url` is under `secureSettings` for the `slack` integration
type — `token must be specified when using the Slack chat API`,
`CrashLoopBackOff`, real outage, not a warning. Verified by reproducing
against a real local Grafana 11.4.0 container (`docker run
grafana/grafana:11.4.0`, mount a `provisioning/alerting/contactpoints.yaml`)
before touching the live cluster again — a plain literal URL under
`secureSettings` failed identically, proving it wasn't a `$__file{}`/env-var
interpolation problem, a field-placement one. `url` under plain `settings`
fixed it; Grafana still redacts it in API responses despite the placement
(confirmed via `GET /api/v1/provisioning/contact-points`), and `$__file{}`
interpolation there does resolve correctly (confirmed by pointing the
secret file at a local network listener and capturing the actual outbound
POST, not just "it didn't crash").

**General lesson**: an app's own runtime schema validation (this) is a
different failure class from a Helm templating error (the Loki bugs
above) — `helm template` will render this cleanly and still crash on
first boot. For anything touching a chart's own non-trivial runtime
config (secrets, notification channels, plugin-specific settings), a
local `docker run` smoke test against the real image catches what
template-rendering can't.

## Loki `detected_level` is query-time structured metadata, not an indexed label

`GET /loki/api/v1/label/detected_level/values` returns an empty result —
confirmed live — even though `{...} | detected_level=~"error"` filters
correctly. It's computed by Loki per-line at query time from common
level-token heuristics (works across JSON, logfmt-ish, and plain-text
logs alike — confirmed against real mixed-format app logs), not stored in
the label index. Don't build a dashboard variable that tries to discover
its values dynamically via `label_values(detected_level)` — it'll come
back empty. Use a static/custom variable with the known fixed vocabulary
instead: `critical,error,warn,info,debug,trace,unknown`.

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
