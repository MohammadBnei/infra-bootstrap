#!/usr/bin/env bash
# Fails CI if gitops/apps/registry.yaml and
# gitops/bootstrap/apps.applicationset.yaml have drifted — the ApplicationSet's
# list generator is a hand-mirrored copy of the registry, not a template over
# it, so nothing else catches a missed or half-updated entry.
set -euo pipefail

REGISTRY="${1:-gitops/apps/registry.yaml}"
APPSET="${2:-gitops/bootstrap/apps.applicationset.yaml}"

registry_json=$(yq -o=json '. | sort_by(.name)' "$REGISTRY")
appset_json=$(yq -o=json '.spec.generators[0].list.elements | sort_by(.name)' "$APPSET")

if [ "$registry_json" == "$appset_json" ]; then
  echo "OK: $REGISTRY and $APPSET are in sync."
  exit 0
fi

echo "::error::$REGISTRY and $APPSET have drifted — every field per 'name' entry must match exactly."
diff <(echo "$registry_json") <(echo "$appset_json") || true
exit 1
