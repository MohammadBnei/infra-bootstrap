#!/usr/bin/env bash
# Install the pilot's add-ons, in order (plan §1.6). Run on the Pi.
# Idempotent: helm upgrade --install throughout.
#
# Every version is pinned by the caller; nothing floats:
#   CILIUM_VERSION=  METALLB_VERSION=  LONGHORN_VERSION=  METRICS_SERVER_VERSION=
#   CERT_APPROVER_VERSION=  (a kubelet-serving-cert-approver release tag)
#   PILOT_LB_RANGE=192.168.1.A-192.168.1.B  (the reserved slice, plan §1.1)
set -euo pipefail

: "${CILIUM_VERSION:?}" "${METALLB_VERSION:?}" "${LONGHORN_VERSION:?}"
: "${METRICS_SERVER_VERSION:?}" "${CERT_APPROVER_VERSION:?}" "${PILOT_LB_RANGE:?}"
PILOT_API="${PILOT_API:-https://192.168.1.21:6443}"

here="$(cd "$(dirname "$0")" && pwd)"

# Never against prod: the current kubeconfig must point at the pilot.
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
if [[ "$server" != "$PILOT_API" ]]; then
  echo "refusing: kubeconfig points at $server, not the pilot ($PILOT_API)" >&2
  exit 1
fi
case "$PILOT_LB_RANGE" in
  *192.168.1.23[3-9]* | *192.168.1.24[0-9]* | *192.168.1.250*)
    echo "refusing: $PILOT_LB_RANGE overlaps prod's MetalLB pool .233-.250" >&2
    exit 1 ;;
esac

# 1. Namespaces first: Talos enforces Pod Security `baseline` outside
#    kube-system, which rejects MetalLB's speaker and Longhorn.
for ns in metallb-system longhorn-system; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=privileged --overwrite
done

helm repo add cilium https://helm.cilium.io/ >/dev/null
helm repo add metallb https://metallb.github.io/metallb >/dev/null
helm repo add longhorn https://charts.longhorn.io >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

# 2. Cilium. Nodes are NotReady until it runs.
helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system --values "$here/values/cilium.yaml" --wait --timeout 10m
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# 3. Serving-cert approver, right after Cilium: with rotated kubelet serving
#    certs, `kubectl logs`/`exec` fail until it runs.
kubectl apply -f "https://raw.githubusercontent.com/alex1989hu/kubelet-serving-cert-approver/${CERT_APPROVER_VERSION}/deploy/standalone-install.yaml"

# 4. MetalLB + the pilot pool.
helm upgrade --install metallb metallb/metallb --version "$METALLB_VERSION" \
  --namespace metallb-system --wait --timeout 5m
PILOT_LB_RANGE="$PILOT_LB_RANGE" envsubst < "$here/values/metallb-pool.yaml" | kubectl apply -f -

# 5. Longhorn on the Talos user volume.
helm upgrade --install longhorn longhorn/longhorn --version "$LONGHORN_VERSION" \
  --namespace longhorn-system --values "$here/values/longhorn.yaml" --wait --timeout 15m

# 6. metrics-server.
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version "$METRICS_SERVER_VERSION" --namespace kube-system --wait --timeout 5m

echo "add-ons installed. Test workloads (plan §1.6.7) are applied separately."
