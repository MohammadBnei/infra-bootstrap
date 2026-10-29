#!/usr/bin/env bash
# Warn-only lint: which common-app-chart apps declare dataLifecycle.pii and
# dataLifecycle.backup (see gitops/platform/common-app-chart/values.yaml).
#
#   check-data-lifecycle.sh [user-appset] [platform-appset] [platform-values-dir]
#
# - User apps: the elements of apps.applicationset.yaml. valuesPath[0] and
#   [1] are fetched at targetRevision (gh api, like chart-golden.sh) and
#   merged, [1] over [0], the way ArgoCD layers them. Platform apps: the
#   elements of platform-common-apps.applicationset.yaml, read from
#   <platform-values-dir>/<name>/values.yaml.
# - VALUES_DIR=<dir> reads user values from <dir>/<owner/repo>/<rev>/<path>
#   instead of gh (offline; the fixture test). A missing file there is
#   `skipped (values unreadable)`.
# - Output is one line per app and never a value: `<app>: declared`,
#   `<app>: missing pii,backup`, `<app>: invalid pii` (and combinations),
#   `<app>: skipped (values unreadable)`, `<app>: fetch failed`, then a
#   counts line and one ::warning:: with the undeclared count.
# - A field is declared when it is a non-empty string; pii must also be
#   none, personal or sensitive (the chart refuses anything else).
# - Exits 0 whatever the declarations say (warn-only for now). Exits 1 only
#   when the lint itself is broken: a fetch failed for a reason other than
#   a 404 (bad token, rate limit, 5xx), a values file does not parse, or a
#   platform values file is missing; 2 on usage errors. A 404 repo is
#   skipped, so with github.token the private repos are skipped and the
#   counts line shows how many.
# - lint.yml runs this only on infra-bootstrap PRs and pushes, while an app
#   declares through a values PR in its own repo: the CI output is a
#   snapshot. The real report is a local run with your own `gh auth`.
#
# ponytail: covers common-app-chart apps in the two ApplicationSets only.
# Not covered: the upstream-chart apps of platform.applicationset.yaml
# (authentik, loki, grafana, infisical, ...), standalone Applications
# (thot, ukubi-game, agent-fleet provisioner, argocd, traefik), and the
# Pigsty databases and Garage buckets themselves. Upgrade path, when this
# lint becomes blocking: a declarations file for the non-chart apps.
# ponytail: yq reads YAML 1.2, helm YAML 1.1, so `backup: no` is a string
# here and a bool to helm; the chart's string check refuses it at render.
#
# bash 3.2-safe (macOS /bin/bash). Needs yq v4, jq, and gh unless VALUES_DIR.
set -uo pipefail

[ $# -le 3 ] || { echo "usage: check-data-lifecycle.sh [user-appset] [platform-appset] [platform-values-dir]" >&2; exit 2; }
USER_AS=${1:-gitops/bootstrap/apps.applicationset.yaml}
PLAT_AS=${2:-gitops/bootstrap/platform-common-apps.applicationset.yaml}
PLAT_VALUES=${3:-gitops/platform/values}
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

US=$'\x1f'
yq -o=json '.spec.generators[0].list.elements' "$USER_AS" \
  | jq -r ".[] | [.name, (.repoURL|sub(\"^https://github.com/\";\"\")|sub(\"\\\\.git\$\";\"\")), .targetRevision, (.valuesPath|join(\",\"))] | join(\"$US\")" \
  > "$T/user" || { echo "check-data-lifecycle: cannot read $USER_AS" >&2; exit 1; }
yq -o=json '.spec.generators[0].list.elements' "$PLAT_AS" | jq -r '.[].name' > "$T/plat" \
  || { echo "check-data-lifecycle: cannot read $PLAT_AS" >&2; exit 1; }

broken=0 n_ok=0 n_bad=0 n_skip=0

# status <app> <values files...>: prints the app's line
status() {
  local app=$1 dl r; shift
  # shellcheck disable=SC2016 # yq expression, not shell
  dl=$(yq ea -o=json '. as $i ireduce ({}; . * $i) | .dataLifecycle' "$@" 2>/dev/null) \
    || { echo "$app: fetch failed (values do not parse)"; broken=1; return; }
  r=$(jq -r '
    def st($v; $ok): if $v == null or $v == "" then "missing" elif $ok then "ok" else "invalid" end;
    if . == null then {} else . end
    | if type != "object" then "invalid pii,backup"
      else
        [ {f: "pii", s: st(.pii; (.pii | type) == "string" and (.pii | IN("none", "personal", "sensitive")))},
          {f: "backup", s: st(.backup; (.backup | type) == "string")} ] as $r
        | ([$r[] | select(.s == "invalid") | .f] | join(",")) as $inv
        | ([$r[] | select(.s == "missing") | .f] | join(",")) as $mis
        | [ (if $inv != "" then "invalid " + $inv else empty end),
            (if $mis != "" then "missing " + $mis else empty end) ]
        | if length == 0 then "declared" else join(", ") end
      end' <<<"$dl")
  echo "$app: $r"
  if [ "$r" = declared ]; then n_ok=$((n_ok + 1)); else n_bad=$((n_bad + 1)); fi
}

# fetch <repo> <rev> <path> <dest>: 0 ok, 3 unreadable (404 / missing), 1 other error
fetch() {
  if [ -n "${VALUES_DIR:-}" ]; then
    [ -f "$VALUES_DIR/$1/$2/$3" ] || return 3
    cp "$VALUES_DIR/$1/$2/$3" "$4"; return
  fi
  gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$3?ref=$2" >"$4" 2>"$T/err" </dev/null && return 0
  grep -q 'HTTP 404' "$T/err" && return 3
  return 1
}

while IFS=$US read -r name repo rev vpaths; do
  i=0 files=''
  for p in $(echo "$vpaths" | tr , ' '); do
    f=$T/$name.$i.yaml
    fetch "$repo" "$rev" "$p" "$f"; rc=$?
    case $rc in
      0) ;;
      3) echo "$name: skipped (values unreadable)"; n_skip=$((n_skip + 1)); continue 2 ;;
      *) echo "$name: fetch failed"; broken=1; continue 2 ;;
    esac
    files="$files $f"
    # ArgoCD reads valuesPath[0] and [1] only; ignore the rest.
    i=$((i + 1)); [ $i = 2 ] && break
  done
  [ -n "$files" ] || { echo "$name: fetch failed (no valuesPath)"; broken=1; continue; }
  # shellcheck disable=SC2086 # temp paths, no spaces
  status "$name" $files
done < "$T/user"

while read -r name; do
  v=$PLAT_VALUES/$name/values.yaml
  [ -f "$v" ] || { echo "platform/$name: fetch failed (no $v)"; broken=1; continue; }
  status "platform/$name" "$v"
done < "$T/plat"

echo "declared: $n_ok, undeclared: $n_bad, skipped: $n_skip"
[ "$n_bad" = 0 ] || echo "::warning::$n_bad apps missing a valid dataLifecycle pii/backup declaration (warn-only; see gitops/scripts/check-data-lifecycle.sh)"
exit $broken
