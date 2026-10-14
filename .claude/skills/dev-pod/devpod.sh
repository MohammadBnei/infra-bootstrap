#!/usr/bin/env bash
# Dev pod: run a locally built binary against the live ukubi-cluster with no
# image build, registry push or ArgoCD deploy. Copy into your repo as
# scripts/devpod.sh and edit the five settings below.
#
#   scripts/devpod.sh up       create throwaway ns + pod, push binary, port-forward
#   scripts/devpod.sh push     rebuild + hot-swap the binary (restart in ~1 s)
#   scripts/devpod.sh logs     follow the app's logs
#   scripts/devpod.sh down     delete the namespace (always do this when done)
#
# ponytail: one bare pod, no Service/Deployment/IngressRoute — reachable only
# via port-forward. The real chart is tested by the ArgoCD deploy; this only
# shortens the code -> live-data loop.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ukubi-admin.conf}"

# --- settings ---------------------------------------------------------------
NS="${DEVPOD_NS:-myapp-dev}"            # throwaway; never the app's real namespace
APP=app                                 # pod/container name and binary name
ARGS='--dev --listen :8080'             # args the supervisor passes to the binary
PORTS=(18080:8080)                      # local:container, as many as needed
ENV_YAML='[]'                           # e.g. '[{ name: LOG_LEVEL, value: debug }]'
build() {                               # must leave a linux/amd64 binary at $BIN
  GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "$BIN" ./cmd/app
}
# ----------------------------------------------------------------------------

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${TMPDIR:-/tmp}/devpod-$NS-$APP"
K="kubectl -n $NS"

push() {
  (cd "$ROOT" && build)
  $K cp "$BIN" "$APP:/app/$APP.new" -c "$APP"
  $K exec "$APP" -c "$APP" -- sh -c "chmod +x /app/$APP.new && mv /app/$APP.new /app/$APP && { pkill -x $APP || true; }"
  echo "pushed $(shasum -a 256 "$BIN" | cut -c1-12)"
}

up() {
  kubectl create ns "$NS" --dry-run=client -o yaml \
    | kubectl label --local -f - purpose=dev -o yaml | kubectl apply -f -
  $K apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $APP, labels: { app: $APP-dev } }
spec:
  securityContext: { runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532 }
  containers:
    - name: $APP
      image: docker.io/library/alpine:3.20
      # Supervisor loop: pkill the binary => restarts with whatever is at /app/$APP.
      command: [sh, -c, 'while true; do [ -x /app/$APP ] && /app/$APP $ARGS; sleep 1; done']
      env: $ENV_YAML
      resources: { requests: { cpu: 20m, memory: 32Mi }, limits: { memory: 256Mi } }
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
      volumeMounts: [{ name: app, mountPath: /app }, { name: tmp, mountPath: /tmp }]
  volumes: [{ name: app, emptyDir: {} }, { name: tmp, emptyDir: {} }]
EOF
  $K wait --for=condition=Ready "pod/$APP" --timeout=120s
  push
  for p in "${PORTS[@]}"; do echo "port-forward: http://127.0.0.1:${p%%:*}"; done
  exec $K port-forward "pod/$APP" "${PORTS[@]}"
}

case "${1:-}" in
  up) up ;;
  push) push ;;
  logs) $K logs -f "$APP" -c "$APP" ;;
  down) kubectl delete ns "$NS" --wait=false ;;
  *) sed -n 2,13p "$0"; exit 2 ;;
esac
