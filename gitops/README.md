# GitOps — ukubi-cluster

ArgoCD-driven GitOps for the ukubi-cluster (QEMU VMs on Proxmox). Everything in this folder is the single source of truth for what runs on the cluster. No `kubectl apply` outside of the one-time bootstrap.

---

## Directory layout

```
gitops/
├── bootstrap/                             # Applied once to bring the cluster up
│   ├── (secrets created by ansible/playbooks/register-repos.yml, not a file here — see ansible/README.md)
│   │     — this now includes repo-creds-github-bnei (ArgoCD repo-creds for
│   │     user-app repos, HTTPS + PAT), deliberately NOT an InfisicalSecret;
│   │     see register-repos.yml's header comment for why
│   ├── bootstrap-application.yaml         # Scoped App-of-Apps that self-syncs this whole directory (ADR-0021) — the one thing applied by hand, ever
│   ├── argocd-application.yaml            # ArgoCD self-manages its own Helm chart
│   ├── traefik-application.yaml           # Standalone Application (needs helm.skipCrds, can't live in the shared ApplicationSet template — see file comment)
│   ├── traefik-crds/                      # Traefik's own CRDs (traefik.io_*/hub.traefik.io_*), vendored — see file comment in traefik-application.yaml
│   ├── actions-runner-application.yaml    # Standalone Application: self-hosted GitHub Actions runner (plain manifests, no chart) — ADR-0022
│   ├── redirectors-application.yaml       # Standalone Application: TLS-terminating redirects to out-of-cluster hosts, plain manifests in gitops/redirectors/
│   ├── argocd-ingressroute.yaml           # Traefik IngressRoute → argocd.bnei.dev
│   ├── infisical-ingressroute.yaml       # Traefik IngressRoute → infisical.bnei.dev
│   ├── grafana-admin-secret.yaml          # InfisicalSecret → Grafana admin credentials
│   ├── basic-admin-auth-middleware.yaml   # Shared Traefik BasicAuth Middleware (ns default), for admin-only tools
│   ├── basic-admin-auth-secret.yaml       # InfisicalSecret → the above Middleware's htpasswd credential
│   ├── longhorn-backup-secret.yaml        # InfisicalSecret → Longhorn's Garage S3 backup-target credentials
│   ├── argocd-redis-secret.yaml            # InfisicalSecret → shared Pigsty Redis password, for argocd-application.yaml's externalRedis
│   ├── longhorn-daily-snapshot-recurringjob.yaml  # Longhorn RecurringJob CR, daily snapshot schedule
│   ├── node-drainer-rbac.yaml              # ServiceAccount+ClusterRole+ClusterRoleBinding for .165's self-drain automation (ansible/playbooks/self-drain-configure.yml) — least-privilege, cordon/evict/read-daemonsets only
│   ├── grafana-ingressroute.yaml           # Traefik IngressRoute → grafana.bnei.dev
│   ├── alertmanager-ingressroute.yaml      # Traefik IngressRoute → alertmanager.bnei.dev, gated by basic-admin-auth
│   ├── alertmanager-discord-secret.yaml    # InfisicalSecret → Discord webhook Alertmanager posts to
│   ├── provisioner-application.yaml        # Standalone Application: agent-fleet's provisioner (plain manifests, own RBAC, sourced from agent-fleet's own k8s/provisioner/) — see agent-fleet docs/adr/0012/0019/0020/0021
│   ├── platform.applicationset.yaml       # ApplicationSet for remaining platform apps (not traefik)
│   ├── platform-common-apps.applicationset.yaml  # ApplicationSet for common-app-chart-based platform tools (public image, no app-specific code)
│   └── apps.applicationset.yaml           # ApplicationSet for user apps with their own private repo
├── platform/
│   ├── common-app-chart/                  # Shared Helm chart used by every simple app (user app or platform-common-app)
│   │   ├── Chart.yaml
│   │   ├── values.yaml                    # Defaults (override per-app)
│   │   └── templates/
│   │       ├── deployment.yaml            # Supports HTTP + TCP health probes, extraVolumes/extraVolumeMounts
│   │       ├── service.yaml
│   │       ├── ingressroute.yaml         # Traefik IngressRoute (no Gateway API, no Ingress), optional middlewares
│   │       ├── pvc.yaml
│   │       ├── infisicalsecret.yaml      # Optional Infisical-backed secret, auto-wired into envFrom
│   │       ├── hooks.yaml                # ArgoCD PreSync/PostSync Jobs (ADR-0023)
│   │       ├── oneoff-cronjobs.yaml      # Suspended CronJobs for one-time scripts (ADR-0022/0023)
│   │       ├── grafana-alertrules.yaml   # Optional log alert ConfigMap, gated by logAlerts.enabled
│   │       ├── grafana-dashboards.yaml   # Optional dashboard ConfigMap, gated by dashboards.enabled
│   │       ├── limitrange.yaml
│   │       ├── poddisruptionbudget.yaml
│   │       └── extra-manifests.yaml      # Raw extra objects (ConfigMaps, Middlewares, ...) via values.extraManifests
│   ├── actions-runner/                    # Standalone Application's manifests: self-hosted GitHub Actions runner (ADR-0022)
│   └── values/                            # Helm values for platform apps (including platform-common-apps)
│       ├── traefik/values.yaml
│       ├── infisical/values.yaml
│       ├── infisical-operator/values.yaml
│       ├── longhorn/values.yaml
│       ├── prometheus/values.yaml
│       ├── grafana/values.yaml
│       ├── loki/values.yaml
│       ├── alloy/values.yaml
│       ├── metrics-server/values.yaml
│       ├── local-path-provisioner/values.yaml
│       ├── searxng/values.yaml            # common-app-chart values, driven by platform-common-apps.applicationset.yaml
│       ├── pgweb/values.yaml              # ditto
│       ├── ente-museum/values.yaml        # ditto
│       └── ente-web/values.yaml           # ditto
├── redirectors/                           # Plain manifests, no chart — TLS-terminating redirects to out-of-cluster hosts
│   ├── proxmox.yaml                       # Namespace+Service(ExternalName)+ServersTransport+IngressRoute → proxmox.bnei.dev (192.168.1.165:8006)
│   └── garage-s3.yaml                     # Namespace+Service(ExternalName)+IngressRoute → s3.bnei.dev (Garage S3 API, 192.168.1.199:3900) — ADR-0030
└── apps/
    └── registry.yaml                      # Human source of truth for user apps (apps needing their own repo)
```

---

## How it works

### Wave ordering

Everything is sequenced so each layer is ready before the next depends on it:

| Wave | App(s) | Why first |
|------|--------|-----------|
| 0 | **Longhorn**, **local-path-provisioner** | Longhorn is the default StorageClass (ADR-0002); local-path-provisioner stays installed as a non-default fallback. Every PVC in the cluster (Traefik's acme.json, common-app-chart PVCs) needs a default StorageClass to bind at all |
| 1 | **Infisical**, **infisical-operator** | Serves secrets to ArgoCD/apps via `InfisicalSecret` CRDs (the operator provides the CRD itself) — must be ready before any app that needs a private values repo or Infisical-backed secret |
| 2 | **Traefik** (standalone `traefik-application.yaml`, not in the ApplicationSet) | Ingress — must be up before IngressRoutes resolve |
| 5 | Prometheus, Grafana, Loki, Alloy, metrics-server | Observability, no hard ordering constraint |
| 10 | User apps (`apps.applicationset.yaml`), platform-common-apps (`platform-common-apps.applicationset.yaml`), redirectors (`redirectors-application.yaml`) | Depend on Infisical (secrets) + Traefik (IngressRoutes) |

Note: since [ADR-0021](../docs/adr/0021-self-syncing-bootstrap-directory.md) these Application/ApplicationSet manifests are all siblings inside the same `bootstrap` Application's resource list, but none of them carry a sync-wave annotation on their own metadata (only on the child app entries an ApplicationSet's `list` generator spawns) — so ArgoCD still doesn't order these siblings relative to each other. These numbers are the intended/documented order. In practice each Application's own `retry`/`selfHeal` policy converges regardless of exact creation order.

### Bootstrap credential chain

```
ansible/playbooks/register-repos.yml (manual, one-time — safe to re-run):
  ├─ infisical-secrets          (ns: infisical) ← register-repos.env (ENCRYPTION_KEY, DB_CONNECTION_URI, ...)
  ├─ universal-auth-credentials (ns: infisical) ← register-repos.env (ARGOCD_INFISICAL_CLIENT_ID/SECRET)
  ├─ repo-infra-bootstrap       (ns: argocd)    ← register-repos.env (INFRA_BOOTSTRAP_SSH_KEY_FILE)
  └─ repo-creds-github-bnei     (ns: argocd)    ← register-repos.env (GITHUB_APPS_USERNAME/GITHUB_APPS_PAT)
       ArgoCD can now clone all MohammadBnei/* repos over HTTPS

Wave 2: Traefik syncs (values in infra-bootstrap, credential already present)
Wave 10: User apps sync (repo-creds-github-bnei already present)
```

`repo-creds-github-bnei` used to flow through Infisical via an `InfisicalSecret`
CR (`argocd-github-apps-creds.yaml`, now removed) — onboarding editable-blog
found the infisical-operator's template rendering corrupts this value
unpredictably (confirmed on both an SSH key and a PAT), so it's injected
manually here instead, same as the infra-bootstrap SSH key. See
`docs/bootstrap-test-notes.md` for the full investigation. Only these four
secrets and Infisical's own server credentials are injected manually.
Everything else flows from Infisical once it's running.

### Three ApplicationSets, plus two standalone Applications

**`platform.applicationset.yaml`** — platform infrastructure, external public Helm charts:

| Wave | App | Chart |
|------|-----|-------|
| 0 | longhorn | longhorn.io/longhorn |
| 0 | local-path-provisioner | containeroo/local-path-provisioner |
| 1 | infisical | infisical/infisical |
| 1 | infisical-operator | infisical/secrets-operator |
| 5 | prometheus | prometheus-community/kube-prometheus-stack |
| 5 | grafana | grafana/grafana |
| 5 | loki | grafana-community/loki |
| 5 | alloy | grafana/alloy |
| 5 | metrics-server | metrics-server/metrics-server |

Each platform app: public Helm chart + values from `infra-bootstrap` via the manually-injected SSH key (two Application sources: the external chart repo, plus infra-bootstrap for the values file).

**`traefik-application.yaml`** (wave 2) is deliberately a standalone `Application`, not part of the ApplicationSet above: it needs `helm.skipCrds: true` (the chart bundles an outdated Gateway API CRD set that a cluster `ValidatingAdmissionPolicy` rejects), and `skipCrds` is a `bool` field the ApplicationSet CRD validates strictly — it can't be produced by a per-element Go-template conditional in the shared list template. See the comment in the file for the full story.

**`actions-runner-application.yaml`** (wave 1) is also standalone: plain manifests (RBAC/ServiceAccount binding, not something `common-app-chart` renders), deploying the self-hosted GitHub Actions runner (`gitops/platform/actions-runner/`) that executes `common-app-chart`'s `hooks:`/`oneOffJobs:` CI (see ADR-0022). RBAC is scoped per-namespace — extend `rbac-<namespace>.yaml` any time another app's `oneOffJobs` gets wired up.

**`platform-common-apps.applicationset.yaml`** — simple containerized tools with no app-specific code (public image, no CI/CD of their own), all at wave 10:

searxng · pgweb · ente-museum · ente-web

Unlike the two ApplicationSets above, both the chart (`common-app-chart`) and the values file live in `infra-bootstrap` itself — a single Application source, no external repo or SSH key needed. Add one: append a list element + `gitops/platform/values/<name>/values.yaml`.

**`apps.applicationset.yaml`** — user apps that need their own private repo (app-specific code/CI, own release cadence), all at wave 10. Currently: `editable-blog`, `dream-analyst`, `vos-monolith`, `vos-monolith-dev`, `agent-fleet-core` (see `gitops/apps/registry.yaml`). n8n, openweb-ui(+pipelines), whodb, api, and ukubi-ai are still deferred until each has a real per-app repo (see `docs/bootstrap-test-notes.md`).

The three `agent-fleet-*` apps moved here from `platform-common-apps` 2026-07-31: their image is built from the `agent-fleet` repo, and that repo's own CI (`docker.yml`) needs to bump the pinned `image.tag` in its `k8s/*.yaml` on every release — the platform-common pattern's infra-bootstrap-only single source can't support a self-contained CI tag bump, so they need the same two-source shape as any other user app, even though they serve no HTTP (`hostname: ""`, no ingress rendered). See `agent-fleet/README.md`.

Each user app: `common-app-chart` from infra-bootstrap + per-app `values.yaml` from the app's own private repo (two Application sources, `GITHUB_APPS_SSH_KEY` required).

Image updates are handled by each app's own CD pipeline — ArgoCD just syncs whatever `image.tag` is in `values.yaml`.

**`redirectors-application.yaml`** (wave 10) is also standalone, deliberately not a chart or ApplicationSet: TLS-terminating redirects to out-of-cluster LAN hosts (e.g. Proxmox's web UI at `192.168.1.165:8006`), which have no pods to template a Deployment/Service around. Each redirect is one self-contained plain manifest (own `Namespace` object — `CreateNamespace=true` only auto-creates the Application's own `destination.namespace`, not other namespaces referenced inside a directory source, same reason `actions-runner`'s manifests declare their own `Namespace` too — plus a `type: ExternalName` Service pointing at the bare IP, optional `ServersTransport` for a self-signed backend cert, IngressRoute with `tls.certResolver: le`) dropped straight into `gitops/redirectors/`, synced the same flat-directory way as `bootstrap-application.yaml` itself (ADR-0021). Add one: copy `proxmox.yaml`, change the name/namespace/hostname/backend IP:port.

Deliberately `ExternalName`, not `ClusterIP` + hand-authored `Endpoints`/`EndpointSlice`: `argocd-cm`'s `resource.exclusions` excludes both `Endpoints` and `EndpointSlice` cluster-wide (standard tuning to cut watch/UI churn from the control-plane-managed ones), so ArgoCD silently drops them from any manifest it applies — Traefik ends up with a Service but zero backends ("no available server"). `ExternalName` sidesteps this entirely: no Endpoints/EndpointSlice exist for that Service type, and Traefik's `kubernetesCRD` provider resolves `spec.externalName` directly, IP literals included.

This requires `providers.kubernetesCRD.allowExternalNameServices: true` in `gitops/platform/values/traefik/values.yaml` — off by default in Traefik itself (an SSRF guardrail), so without it every redirector's IngressRoute fails with `externalName services not allowed` and clients get a 404 (no router gets built at all).

Currently: `proxmox.yaml` (proxmox.bnei.dev) and `garage-s3.yaml` (s3.bnei.dev, [ADR-0030](../docs/adr/0030-expose-garage-s3-externally.md)).

**`provisioner-application.yaml`** (wave 10) is also standalone, same shape as `actions-runner-application.yaml`, but its manifests live OUT-OF-REPO as of agent-fleet's `docs/adr/0019`/`0020`/`0021`: this Application's `source` points at agent-fleet's own `k8s/provisioner/` (own scoped `Role`/`RoleBinding`, `NetworkPolicy`, `Deployment`, shared workspace PVC) instead of a directory here, deploying agent-fleet's provisioner (task-worker-pod spawning + e2e task-preview) into the existing `agent-fleet` namespace. See agent-fleet's `k8s/provisioner/README.md` and `docs/adr/0012`/`0019`/`0020`/`0021` for the design.

### common-app-chart

A minimal Helm chart for standard web apps. Renders:
- `Deployment` — image, env, envFrom, resources, optional health probes (HTTP or TCP), optional PVC mount
- `Service` — ClusterIP on `service.port`
- `IngressRoute` — Traefik CRD, `entryPoints: [websecure]`, native ACME via `tls.certResolver`
- `PersistentVolumeClaim` — optional, gated by `persistence.enabled`
- `InfisicalSecret` — optional, gated by `infisical.enabled`, auto-wired into the Deployment's `envFrom`
- `hooks:` — guard-railed ArgoCD PreSync/PostSync `Job`s (schema migrations, etc. — see ADR-0023)
- `oneOffJobs:` — suspended `CronJob`s for one-time scripts, triggered via `kubectl create job --from=cronjob/...` and a ledger-driven reusable CI workflow (see ADR-0022/0023)
- `ConfigMap` (log alert rules) — optional, gated by `logAlerts.enabled`, labeled `grafana_alert: "1"` so Grafana's alerts sidecar picks it up dynamically (see `gitops/platform/values/grafana/values.yaml`'s `sidecar.alerts`) — routes through the platform's shared Discord contact point, the app only declares the LogQL condition/threshold
- `ConfigMap` (dashboards) — optional, gated by `dashboards.enabled`, labeled `grafana_dashboard: "1"` so Grafana's dashboards sidecar picks it up dynamically (see `gitops/platform/values/grafana/values.yaml`'s `sidecar.dashboards`) — the app ships its own dashboard JSON from its own repo, no platform file edits needed

Key values a per-app `values.yaml` must set:

```yaml
image:
  repository: ghcr.io/owner/app
  tag: "1.2.3"
service:
  port: 8080
```

Health probe example (n8n):
```yaml
livenessProbe:
  enabled: true
  type: http      # or tcp
  path: /healthz
  initialDelaySeconds: 30
readinessProbe:
  enabled: true
  type: http
  path: /healthz
  initialDelaySeconds: 15
```

Log alert rule example (app's own Loki-based error condition):
```yaml
logAlerts:
  enabled: true
  rules:
    - uid: high-5xx-rate      # only needs to be unique within this app
      title: High 5xx rate
      expr: 'sum(rate({namespace="myapp"} |~ "(?i) 5\\d\\d " [5m]))'
      threshold: 0.2
      for: 5m                 # optional, defaults to 5m
      severity: warning       # optional, defaults to warning
```

Dashboard example (app ships its own dashboard JSON):
```yaml
dashboards:
  enabled: true
  items:
    overview: |
      { "title": "My App Overview", "panels": [...], ... }
```

**Dashboards note** — two mechanisms exist, pick based on ownership:
- **Platform-wide** dashboard (applies across apps, e.g. cluster health): add
  a JSON blob under `dashboards.gitops.<key>` in
  `gitops/platform/values/grafana/values.yaml` directly — static file
  provisioning, `editable: false`, lives in this repo.
- **Per-app** dashboard (belongs to one app): use the `dashboards:` block
  above in that app's own `values.yaml` — dynamic, ConfigMap + sidecar,
  lives in the app's own repo, lands in Grafana's default ("General")
  folder (no dedicated folder yet — see the `sidecar.dashboards` comment
  in `grafana/values.yaml` for why one isn't set).

Annotations: `annotations` (Deployment), `podAnnotations` (pod template), `service.annotations` (Service), `ingress.annotations` (IngressRoute) — plain key/value maps, rendered as-is.

The chart can template its own `InfisicalSecret` CR — set `infisical.enabled: true` and `infisical.projectSlug` in the app's `values.yaml` and the resulting K8s Secret is auto-wired into the Deployment's `envFrom` (no manual `secretRef` needed). It reuses the cluster's shared `universal-auth-credentials` machine identity (ns `infisical`) — grant that identity access to your app's Infisical project in the Infisical UI, don't mint new K8s credentials per app. Defaults: `envSlug: dev`, `secretsPath: "/"`, in-cluster `hostAPI`. Set `infisical.autoReload: true` to have the chart add `secrets.infisical.com/auto-reload: "true"` to the Deployment automatically (restarts it when the managed secret changes) — no need to hand-add it under `annotations:`. Apps that need a manually-authored `InfisicalSecret` (e.g. field remapping via `template:`) can still define one in their private repo and reference it manually via `envFrom`.

`apps.applicationset.yaml` and `platform-common-apps.applicationset.yaml` both set `ignoreDifferences` for `InfisicalSecret`'s `.status` so the operator's periodic resync doesn't leave the Application permanently `OutOfSync`.

---

## Bootstrap sequence

Run once on a fresh cluster after kubespray has finished.

**Kubespray handles:** Cilium, CoreDNS, kube-proxy, MetalLB, Gateway API CRDs. Do not add those to ArgoCD.

### Step 1 — Install ArgoCD (one-time Helm bootstrap)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set configs.params."server\.insecure"=true
```

### Step 2 — Create bootstrap secrets

```bash
cp ansible/playbooks/register-repos.env.example ansible/playbooks/register-repos.env
# ...fill in register-repos.env...

set -a && source ansible/playbooks/register-repos.env && set +a
ansible-playbook -i inventory/ukubi/hosts.yaml ansible/playbooks/register-repos.yml
```

Full details (prerequisites, where each value comes from, how to extend) are
in [ansible/README.md](../ansible/README.md#playbooksregister-reposyml). No
network connection to Infisical is required — see that doc for why these
three inputs deliberately stay local instead of flowing through Infisical.

| Source (in `register-repos.env`) | K8s Secret created |
|---|---|
| `ENCRYPTION_KEY`, `AUTH_SECRET`, `DB_CONNECTION_URI`, `REDIS_URL`, `SMTP_*`, ... | `infisical-secrets` in ns `infisical` |
| `ARGOCD_INFISICAL_CLIENT_ID` / `ARGOCD_INFISICAL_CLIENT_SECRET` | `universal-auth-credentials` in ns `infisical` |
| `INFRA_BOOTSTRAP_SSH_KEY_FILE` | `repo-infra-bootstrap` in ns `argocd` |

> **Never commit SSH keys or secrets to this repo.** `register-repos.env` is gitignored (`*.env`).

### Step 3 — Apply bootstrap manifests (one-time only)

```bash
kubectl apply -f gitops/bootstrap/traefik-crds/
kubectl apply -f gitops/bootstrap/
```

`traefik-crds/` is applied first and separately: it's Traefik's own CRDs
(`traefik.io_*`, `hub.traefik.io_*`), vendored from the chart because
`traefik-application.yaml` sets `helm.skipCrds: true` (see that file's
comment) and so never installs them itself. Not ArgoCD-managed — same
reasoning as `skipCrds` itself, see `traefik-application.yaml`.

This second `kubectl apply` only needs to happen once, ever, because
`gitops/bootstrap/bootstrap-application.yaml` is itself one of the
manifests it installs — a scoped App-of-Apps
([ADR-0021](../docs/adr/0021-self-syncing-bootstrap-directory.md)) that
makes ArgoCD watch and self-sync the rest of this directory from then
on. **After this first apply, adding a platform or user app is just:
edit `gitops/bootstrap/` (and/or `gitops/apps/registry.yaml`), merge to
`main`, done** — no further manual `kubectl apply` needed.

ArgoCD becomes self-managing. Wave 1 (Infisical) syncs immediately using the manually-injected infra-bootstrap credential. `repo-creds-github-bnei` (also manually injected, see "Bootstrap credential chain" above) is already present for user-app repos at wave 10.

### Step 4 — Watch it come up

```bash
kubectl -n argocd rollout status deploy/argocd-server
open https://argocd.bnei.dev
kubectl -n argocd get applications
```

---

## Adding a user app

1. Create a private GitHub repo with at minimum a `values.yaml`:

   ```yaml
   image:
     repository: ghcr.io/owner/myapp
     tag: "0.1.0"
   service:
     port: 3000
   ```

2. No per-repo credential needed — `repo-creds-github-bnei` already grants ArgoCD HTTPS read access to every `MohammadBnei/*` repo (see "Bootstrap credential chain" above). Just make sure the repo is under that account/org.

3. Add the app to **both** files (they must stay in sync), using the **HTTPS** form for `repoURL` (not `git@github.com:...` — this project uses HTTPS + PAT, not SSH deploy keys, see the credential chain section above for why):

   **`gitops/apps/registry.yaml`**
   ```yaml
   - name: myapp
     namespace: myapp
     syncWave: "10"
     repoURL: https://github.com/MohammadBnei/myapp.git
     valuesPath: values.yaml
     hostname: myapp.bnei.dev
   ```

   **`gitops/bootstrap/apps.applicationset.yaml`** — mirror the same entry under `spec.generators[0].list.elements`.

4. Commit and push. ArgoCD reconciles within seconds.

---

## Updating a platform app

Edit `gitops/platform/values/<name>/values.yaml`, commit, push. ArgoCD `selfHeal` applies it automatically.

To bump a chart version: update `chartRevision` in `platform.applicationset.yaml`.

---

## Hard constraints (from `DECISION.md` / `docs/adr/`)

- **No Gateway API for app routing, no plain Ingress** — Traefik `IngressRoute` only (Gateway API can't get certs from Traefik's ACME resolver without cert-manager) — [ADR-0001](../docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- **No cert-manager** — TLS via Traefik ACME (HTTP-01), `acme.json` on a PVC — [ADR-0001](../docs/adr/0001-ingress-traefik-ingressroute-over-gateway-api.md)
- **No secrets in git** — all secrets via Infisical; `.env.*` files are gitignored
- **MetalLB and Cilium are not in ArgoCD** — kubespray owns them
- **No App-of-Apps root.yaml** — the ApplicationSet list IS the registry — [ADR-0004](../docs/adr/0004-gitops-pattern-c-registry-applicationset.md)
