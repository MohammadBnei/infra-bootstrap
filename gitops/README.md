# GitOps — ukubi-cluster

ArgoCD-driven GitOps for the ukubi-cluster (QEMU VMs on Proxmox). Everything in this folder is the single source of truth for what runs on the cluster. No `kubectl apply` outside of the one-time bootstrap.

---

## Directory layout

```
gitops/
├── bootstrap/                             # Applied once to bring the cluster up
│   ├── register-repos.sh                  # Creates manual K8s Secrets before ArgoCD starts
│   ├── argocd-application.yaml            # ArgoCD self-manages its own Helm chart
│   ├── argocd-ingressroute.yaml           # Traefik IngressRoute → argocd.bnei.dev
│   ├── infisical-ingressroute.yaml       # Traefik IngressRoute → infisical.bnei.dev
│   ├── argocd-github-apps-creds.yaml      # InfisicalSecret → ArgoCD repo-creds for user apps
│   ├── platform.applicationset.yaml       # ApplicationSet for all platform apps
│   └── apps.applicationset.yaml           # ApplicationSet for all user apps
├── platform/
│   ├── common-app-chart/                  # Shared Helm chart used by every user app
│   │   ├── Chart.yaml
│   │   ├── values.yaml                    # Defaults (override per-app in the app's repo)
│   │   └── templates/
│   │       ├── deployment.yaml            # Supports HTTP + TCP health probes
│   │       ├── service.yaml
│   │       ├── ingressroute.yaml         # Traefik IngressRoute (no Gateway API, no Ingress)
│   │       └── pvc.yaml
│   └── values/                            # Helm values for platform apps
│       ├── traefik/values.yaml
│       ├── infisical/values.yaml
│       ├── prometheus/values.yaml
│       ├── grafana/values.yaml
│       └── metrics-server/values.yaml
└── apps/
    └── registry.yaml                      # Human source of truth for user apps
```

---

## How it works

### Wave ordering

Everything is sequenced so each layer is ready before the next depends on it:

| Wave | App(s) | Why first |
|------|--------|-----------|
| 1 | **Infisical** | Serves SSH keys to ArgoCD via `InfisicalSecret` CRDs — must be ready before any app that needs a private values repo |
| 2 | **Traefik** | Ingress — must be up before IngressRoutes resolve |
| 5 | Prometheus, Grafana, metrics-server | Observability, no hard ordering constraint |
| 10 | All user apps | Depend on Infisical (secrets) + Traefik (IngressRoutes) |

### Bootstrap credential chain

```
register-repos.sh (manual, one-time):
  ├─ infisical-secrets          (ns: infisical) ← k8s-cluster/infisical/.env.secret
  ├─ universal-auth-credentials (ns: infisical) ← k8s-cluster/infisical/.env.client
  └─ repo-infra-bootstrap       (ns: argocd)    ← $INFRA_BOOTSTRAP_KEY_FILE (local SSH key)

Wave 1: Infisical starts
  └─ argocd-github-apps-creds.yaml (InfisicalSecret) resolves →
       repo-creds-github-bnei (ns: argocd) ← GITHUB_APPS_SSH_KEY from Infisical
       ArgoCD can now clone all MohammadBnei/* repos

Wave 2: Traefik syncs (values in infra-bootstrap, SSH key already present)
Wave 10: User apps sync (SSH keys for per-app repos now in ArgoCD cred store)
```

Only the infra-bootstrap SSH key and Infisical's own server credentials are injected manually. Everything else flows from Infisical once it's running.

### Two ApplicationSets

**`platform.applicationset.yaml`** — platform infrastructure:

| Wave | App | Chart |
|------|-----|-------|
| 1 | infisical | infisical/infisical |
| 2 | traefik | traefik/traefik |
| 5 | prometheus | prometheus-community/kube-prometheus-stack |
| 5 | grafana | grafana/grafana |
| 5 | metrics-server | metrics-server/metrics-server |

Each platform app: public Helm chart + values from `infra-bootstrap` via the manually-injected SSH key.

**`apps.applicationset.yaml`** — user apps, all at wave 10:

n8n · openweb-ui · openweb-ui-pipelines · searxng · whodb · api · ukubi-ai

Each user app: `common-app-chart` from infra-bootstrap + per-app `values.yaml` from the app's private repo.

Image updates are handled by each app's own CD pipeline — ArgoCD just syncs whatever `image.tag` is in `values.yaml`.

### common-app-chart

A minimal Helm chart for standard web apps. Renders:
- `Deployment` — image, env, envFrom, resources, optional health probes (HTTP or TCP), optional PVC mount
- `Service` — ClusterIP on `service.port`
- `IngressRoute` — Traefik CRD, `entryPoints: [websecure]`, native ACME via `tls.certResolver`
- `PersistentVolumeClaim` — optional, gated by `persistence.enabled`

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

`InfisicalSecret` CRDs live in each app's private repo, not in this chart. The chart's `envFrom` picks up the resulting K8s Secret by name. In-cluster Infisical URL for app repos:
```
http://infisical.infisical.svc.cluster.local:8080/api
```
Credentials namespace: `infisical` (was `vault` on old cluster).

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
export INFRA_BOOTSTRAP_KEY_FILE=~/.ssh/infra_bootstrap_id_ed25519

./gitops/bootstrap/register-repos.sh
```

The script requires no network connection to Infisical. It reads two local files:

| Source | K8s Secret created |
|---|---|
| `k8s-cluster/infisical/.env.secret` | `infisical-secrets` in ns `infisical` |
| `k8s-cluster/infisical/.env.client` | `universal-auth-credentials` in ns `infisical` |
| `$INFRA_BOOTSTRAP_KEY_FILE` | `repo-infra-bootstrap` in ns `argocd` |

> **Never commit SSH keys or secrets to this repo.** The `.env.*` files are gitignored.

### Step 3 — Apply bootstrap manifests

```bash
kubectl apply -f gitops/bootstrap/
```

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

## Hard constraints (from MISSION.md)

- **No Gateway API for app routing, no plain Ingress** — Traefik `IngressRoute` only (Gateway API can't get certs from Traefik's ACME resolver without cert-manager)
- **No cert-manager** — TLS via Traefik ACME (HTTP-01), `acme.json` on a PVC
- **No secrets in git** — all secrets via Infisical; `.env.*` files are gitignored
- **MetalLB and Cilium are not in ArgoCD** — kubespray owns them
- **No App-of-Apps root.yaml** — the ApplicationSet list IS the registry
