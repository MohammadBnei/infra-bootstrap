# GitOps — ukubi-cluster

ArgoCD-driven GitOps for the ukubi-cluster (QEMU VMs on Proxmox). Everything in this folder is the single source of truth for what runs on the cluster. No `kubectl apply` outside of the one-time bootstrap.

---

## Directory layout

```
gitops/
├── bootstrap/                             # Applied once to bring the cluster up
│   ├── (secrets created by ansible/playbooks/register-repos.yml, not a file here — see ansible/README.md)
│   ├── argocd-application.yaml            # ArgoCD self-manages its own Helm chart
│   ├── traefik-application.yaml           # Standalone Application (needs helm.skipCrds, can't live in the shared ApplicationSet template — see file comment)
│   ├── traefik-crds/                      # Traefik's own CRDs (traefik.io_*/hub.traefik.io_*), vendored — see file comment in traefik-application.yaml
│   ├── argocd-ingressroute.yaml           # Traefik IngressRoute → argocd.bnei.dev
│   ├── infisical-ingressroute.yaml       # Traefik IngressRoute → infisical.bnei.dev
│   ├── argocd-github-apps-creds.yaml      # InfisicalSecret → ArgoCD repo-creds for user apps
│   ├── grafana-admin-secret.yaml          # InfisicalSecret → Grafana admin credentials
│   ├── basic-admin-auth-middleware.yaml   # Shared Traefik BasicAuth Middleware (ns default), for admin-only tools
│   ├── basic-admin-auth-secret.yaml       # InfisicalSecret → the above Middleware's htpasswd credential
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
│   │       └── extra-manifests.yaml      # Raw extra objects (ConfigMaps, Middlewares, ...) via values.extraManifests
│   └── values/                            # Helm values for platform apps (including platform-common-apps)
│       ├── traefik/values.yaml
│       ├── infisical/values.yaml
│       ├── infisical-operator/values.yaml
│       ├── longhorn/values.yaml
│       ├── prometheus/values.yaml
│       ├── grafana/values.yaml
│       ├── metrics-server/values.yaml
│       ├── local-path-provisioner/values.yaml
│       ├── searxng/values.yaml            # common-app-chart values, driven by platform-common-apps.applicationset.yaml
│       └── pgweb/values.yaml              # ditto
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
| 5 | Prometheus, Grafana, metrics-server | Observability, no hard ordering constraint |
| 10 | User apps (`apps.applicationset.yaml`), platform-common-apps (`platform-common-apps.applicationset.yaml`) | Depend on Infisical (secrets) + Traefik (IngressRoutes) |

Note: sync-wave ordering across independent top-level Applications isn't strictly enforced by ArgoCD without an App-of-Apps parent (which `DECISION.md` forbids here — see [ADR-0004](../docs/adr/0004-gitops-pattern-c-registry-applicationset.md)) — these numbers are the intended/documented order. In practice each Application's own `retry`/`selfHeal` policy converges regardless of exact creation order.

### Bootstrap credential chain

```
ansible/playbooks/register-repos.yml (manual, one-time):
  ├─ infisical-secrets          (ns: infisical) ← register-repos.env (ENCRYPTION_KEY, DB_CONNECTION_URI, ...)
  ├─ universal-auth-credentials (ns: infisical) ← register-repos.env (ARGOCD_INFISICAL_CLIENT_ID/SECRET)
  └─ repo-infra-bootstrap       (ns: argocd)    ← register-repos.env (INFRA_BOOTSTRAP_SSH_KEY_FILE)

Wave 1: Infisical starts
  └─ argocd-github-apps-creds.yaml (InfisicalSecret) resolves →
       repo-creds-github-bnei (ns: argocd) ← GITHUB_APPS_SSH_KEY from Infisical
       ArgoCD can now clone all MohammadBnei/* repos

Wave 2: Traefik syncs (values in infra-bootstrap, SSH key already present)
Wave 10: User apps sync (SSH keys for per-app repos now in ArgoCD cred store)
```

Only the infra-bootstrap SSH key and Infisical's own server credentials are injected manually. Everything else flows from Infisical once it's running.

### Three ApplicationSets, plus one standalone Application

**`platform.applicationset.yaml`** — platform infrastructure, external public Helm charts:

| Wave | App | Chart |
|------|-----|-------|
| 0 | longhorn | longhorn.io/longhorn |
| 0 | local-path-provisioner | containeroo/local-path-provisioner |
| 1 | infisical | infisical/infisical |
| 1 | infisical-operator | infisical/secrets-operator |
| 5 | prometheus | prometheus-community/kube-prometheus-stack |
| 5 | grafana | grafana/grafana |
| 5 | metrics-server | metrics-server/metrics-server |

Each platform app: public Helm chart + values from `infra-bootstrap` via the manually-injected SSH key (two Application sources: the external chart repo, plus infra-bootstrap for the values file).

**`traefik-application.yaml`** (wave 2) is deliberately a standalone `Application`, not part of the ApplicationSet above: it needs `helm.skipCrds: true` (the chart bundles an outdated Gateway API CRD set that a cluster `ValidatingAdmissionPolicy` rejects), and `skipCrds` is a `bool` field the ApplicationSet CRD validates strictly — it can't be produced by a per-element Go-template conditional in the shared list template. See the comment in the file for the full story.

**`platform-common-apps.applicationset.yaml`** — simple containerized tools with no app-specific code (public image, no CI/CD of their own), all at wave 10:

searxng · pgweb

Unlike the two ApplicationSets above, both the chart (`common-app-chart`) and the values file live in `infra-bootstrap` itself — a single Application source, no external repo or SSH key needed. Add one: append a list element + `gitops/platform/values/<name>/values.yaml`.

**`apps.applicationset.yaml`** — user apps that need their own private repo (app-specific code/CI, own release cadence), all at wave 10. Currently empty — n8n, openweb-ui(+pipelines), whodb, api, and ukubi-ai are deferred until each has a real per-app repo (see `docs/bootstrap-test-notes.md`).

Each user app: `common-app-chart` from infra-bootstrap + per-app `values.yaml` from the app's own private repo (two Application sources, `GITHUB_APPS_SSH_KEY` required).

Image updates are handled by each app's own CD pipeline — ArgoCD just syncs whatever `image.tag` is in `values.yaml`.

### common-app-chart

A minimal Helm chart for standard web apps. Renders:
- `Deployment` — image, env, envFrom, resources, optional health probes (HTTP or TCP), optional PVC mount
- `Service` — ClusterIP on `service.port`
- `IngressRoute` — Traefik CRD, `entryPoints: [websecure]`, native ACME via `tls.certResolver`
- `PersistentVolumeClaim` — optional, gated by `persistence.enabled`
- `InfisicalSecret` — optional, gated by `infisical.enabled`, auto-wired into the Deployment's `envFrom`

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

Annotations: `annotations` (Deployment), `podAnnotations` (pod template), `service.annotations` (Service), `ingress.annotations` (IngressRoute) — plain key/value maps, rendered as-is.

The chart can template its own `InfisicalSecret` CR — set `infisical.enabled: true` and `infisical.projectSlug` in the app's `values.yaml` and the resulting K8s Secret is auto-wired into the Deployment's `envFrom` (no manual `secretRef` needed). It reuses the cluster's shared `universal-auth-credentials` machine identity (ns `infisical`) — grant that identity access to your app's Infisical project in the Infisical UI, don't mint new K8s credentials per app. Defaults: `envSlug: dev`, `secretsPath: "/"`, in-cluster `hostAPI`. Apps that need a manually-authored `InfisicalSecret` (e.g. field remapping via `template:`) can still define one in their private repo and reference it manually via `envFrom`.

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

### Step 3 — Apply bootstrap manifests

```bash
kubectl apply -f gitops/bootstrap/traefik-crds/
kubectl apply -f gitops/bootstrap/
```

`traefik-crds/` is applied first and separately: it's Traefik's own CRDs
(`traefik.io_*`, `hub.traefik.io_*`), vendored from the chart because
`traefik-application.yaml` sets `helm.skipCrds: true` (see that file's
comment) and so never installs them itself. Not ArgoCD-managed — same
reasoning as `skipCrds` itself, see `traefik-application.yaml`.

ArgoCD becomes self-managing. Wave 1 (Infisical) syncs immediately using the manually-injected infra-bootstrap SSH key. Once Infisical is healthy, `argocd-github-apps-creds.yaml` resolves and injects the user-app SSH credential into ArgoCD automatically.

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

2. Add a read-only SSH deploy key. The private key goes in Infisical under `GITHUB_APPS_SSH_KEY` (or use a per-repo key added separately to the ArgoCD credential store).

3. Add the app to **both** files (they must stay in sync):

   **`gitops/apps/registry.yaml`**
   ```yaml
   - name: myapp
     namespace: myapp
     syncWave: "10"
     repoURL: git@github.com:MohammadBnei/myapp.git
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
