#!/usr/bin/env bash
# Render and validate the pilot's machine configs (plan §1.5 step 0).
# Run on the Pi. Writes talos/rendered/ (gitignored: it contains secrets).
#
#   SECRETS=/path/to/secrets.yaml SCHEMATIC_ID=<id> TALOS_VERSION=v1.14.x talos/render.sh
#
# secrets.yaml comes from the talos-pilot Infisical project (base64-decoded
# into a 0600 file); delete it after use.
set -euo pipefail

: "${SECRETS:?path to the talosctl gen secrets bundle}"
: "${SCHEMATIC_ID:?Image Factory schematic id (talos/schematic.yaml)}"
: "${TALOS_VERSION:?e.g. v1.14.1}"
K8S_VERSION="${K8S_VERSION:-1.35.4}"

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/rendered"
mkdir -p "$out"
chmod 700 "$out"

common=()
for p in "$here"/patches/common/*.yaml; do common+=(--config-patch "@$p"); done

talosctl gen config ukubi-pilot https://192.168.1.21:6443 \
  --with-secrets "$SECRETS" \
  --kubernetes-version "$K8S_VERSION" \
  --install-image "factory.talos.dev/metal-installer/${SCHEMATIC_ID}:${TALOS_VERSION}" \
  "${common[@]}" \
  --config-patch-control-plane "@$here/patches/controlplane/control-plane.yaml" \
  --output "$out" --force

talosctl machineconfig patch "$out/controlplane.yaml" \
  --patch "@$here/patches/nodes/esprimo-1.yaml" --output "$out/esprimo-1.yaml"
talosctl machineconfig patch "$out/worker.yaml" \
  --patch "@$here/patches/nodes/esprimo-2.yaml" --output "$out/esprimo-2.yaml"

for n in esprimo-1 esprimo-2; do
  if grep -q 'FILL-ME' "$out/$n.yaml"; then
    echo "refusing: $n still has a FILL-ME placeholder (disk serial)" >&2
    exit 1
  fi
  talosctl validate --config "$out/$n.yaml" --mode metal
done
chmod 600 "$out"/*
echo "rendered and validated: $out/esprimo-1.yaml, $out/esprimo-2.yaml, $out/talosconfig"
