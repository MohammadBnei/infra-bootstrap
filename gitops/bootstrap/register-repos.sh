#!/usr/bin/env bash
# Bootstrap script — create all manual K8s Secrets required before ArgoCD
# can sync the cluster. Safe to re-run (all kubectl calls are idempotent).
#
# WHY THIS SCRIPT EXISTS
# ArgoCD installs Infisical at wave 1. Infisical needs its own credentials
# before it can start (DB connection, encryption key). These come from the
# .env files already used by the running k8s-cluster/infisical/ setup.
#
# Once Infisical is up, it serves the user-app SSH keys to ArgoCD via
# InfisicalSecret CRDs (see bootstrap/argocd-github-apps-creds.yaml).
# Only the infra-bootstrap SSH key is injected manually here — it is the
# minimum required to pull Infisical's own platform values from infra-bootstrap.
#
# Prerequisites:
#   - kubectl configured against ukubi-cluster
#   - k8s-cluster/infisical/.env.secret present (gitignored, contains server creds)
#   - k8s-cluster/infisical/.env.client present (gitignored, contains machine-identity)
#   - INFRA_BOOTSTRAP_KEY_FILE set to path of the infra-bootstrap SSH private key
#
# Nothing is fetched from the network — all material is local.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override with env vars if needed
# ---------------------------------------------------------------------------
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
INFISICAL_NAMESPACE="${INFISICAL_NAMESPACE:-infisical}"
INFRA_BOOTSTRAP_REPO="git@github.com:MohammadBnei/infra-bootstrap.git"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFISICAL_ENV_DIR="$SCRIPT_DIR/../../k8s-cluster/infisical"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
  for cmd in kubectl; do
    command -v "$cmd" &>/dev/null || die "'$cmd' not found in PATH"
  done
  kubectl cluster-info &>/dev/null || die "kubectl cannot reach the cluster"
  [[ -f "$INFISICAL_ENV_DIR/.env.secret" ]] || die ".env.secret not found at $INFISICAL_ENV_DIR — copy it from the running cluster"
  [[ -f "$INFISICAL_ENV_DIR/.env.client" ]] || die ".env.client not found at $INFISICAL_ENV_DIR — copy it from the running cluster"
  [[ -n "${INFRA_BOOTSTRAP_KEY_FILE:-}" ]] || die "Set INFRA_BOOTSTRAP_KEY_FILE=/path/to/infra_bootstrap_id_ed25519"
  [[ -f "$INFRA_BOOTSTRAP_KEY_FILE" ]]     || die "SSH key not found: $INFRA_BOOTSTRAP_KEY_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
check_prereqs

INFRA_BOOTSTRAP_KEY="$(cat "$INFRA_BOOTSTRAP_KEY_FILE")"

# ---------------------------------------------------------------------------
# 1. ArgoCD namespace + infra-bootstrap repo credential
#    This is the ONLY SSH key injected manually. It lets ArgoCD pull
#    Infisical's platform values from infra-bootstrap (wave 1 sync).
#    All other repo SSH keys come from Infisical via InfisicalSecret CRDs.
# ---------------------------------------------------------------------------
log "Ensuring namespace $ARGOCD_NAMESPACE exists..."
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Registering infra-bootstrap repo credential..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-infra-bootstrap
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${INFRA_BOOTSTRAP_REPO}
  sshPrivateKey: |
$(printf '%s\n' "$INFRA_BOOTSTRAP_KEY" | sed 's/^/    /')
EOF

# ---------------------------------------------------------------------------
# 2. Infisical namespace + server credentials
#    infisical-secrets feeds kubeSecretRef in the Infisical Helm chart.
#    Contains ENCRYPTION_KEY, AUTH_SECRET, DB_CONNECTION_URI, REDIS_URL, SMTP_*.
# ---------------------------------------------------------------------------
log "Ensuring namespace $INFISICAL_NAMESPACE exists..."
kubectl create namespace "$INFISICAL_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

log "Creating infisical-secrets (from .env.secret)..."
kubectl create secret generic infisical-secrets \
  --namespace "$INFISICAL_NAMESPACE" \
  --from-env-file="$INFISICAL_ENV_DIR/.env.secret" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 3. Machine-identity credentials for the Infisical K8s operator
#    InfisicalSecret CRDs reference this secret to authenticate against the
#    Infisical server and materialize K8s Secrets for other apps.
# ---------------------------------------------------------------------------
log "Creating universal-auth-credentials (from .env.client)..."
kubectl create secret generic universal-auth-credentials \
  --namespace "$INFISICAL_NAMESPACE" \
  --from-env-file="$INFISICAL_ENV_DIR/.env.client" \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log ""
log "Bootstrap secrets created. Apply the GitOps manifests:"
log ""
log "  kubectl apply -f gitops/bootstrap/"
log ""
log "Wave order: Infisical(1) → Traefik(2) → Observability(5) → User apps(10)"
log "After wave 1, ArgoCD will receive user-app SSH keys via InfisicalSecret."
log ""
log "Watch ArgoCD come up:"
log "  kubectl -n argocd rollout status deploy/argocd-server"
