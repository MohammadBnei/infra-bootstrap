#!/usr/bin/env bash
# Golden render of gitops/platform/common-app-chart: renders the chart at two
# points for every element of gitops/bootstrap/apps.applicationset.yaml (user
# apps) and platform-common-apps.applicationset.yaml (platform apps), the way
# ArgoCD does, and says which renders differ.
#
#   chart-golden.sh <base-ref> <head-ref|DIR:chart-dir> [--public-only] [--allow-changes]
#
# - Base is `git merge-base <base-ref> <head>`, so a stale or behind base
#   does not show main's own commits as changes. Run `git fetch origin` first.
# - Only the chart varies. The element lists, gitops/platform/values and the
#   user apps' values (fetched once from each app repo at its own
#   targetRevision) all come from head, so adding an app is not a diff.
# - `DIR:<path>` renders a chart directory on disk as head (uncommitted
#   edits); lists and platform values then come from the working tree.
#   A plain ref ignores uncommitted edits.
# - Output is only `<app>: unchanged|changed <sha256 of head render>`
#   (`changed ... (base render failed)` when only head renders, e.g. a chart
#   fix), `<app>: skipped (not public)`, `<app>: skipped (unreadable by token)`,
#   `<app>: render failed|fetch failed`, plus a
#   `user-apps-rendered: N` line (user apps whose head render succeeded). This repo is public and the app repos are
#   not all public: never add output that prints values or manifests. helm
#   stderr is shown only for platform apps and apps whose repo is public.
# - --public-only renders only apps whose repo is public (CI: github.token
#   reads no private repo). A 404 repo is `skipped (unreadable by token)`,
#   distinct from a readable private one, so a public app whose repoURL broke
#   shows up. Without it every repo must be readable (local full run with your
#   own `gh auth`).
# - Exits 1 on any changed app, any render or fetch failure, or when no user
#   app rendered. By default any changed app is a failure: a chart PR should
#   render every app unchanged, and an app opts in through a separate
#   values-only PR. --allow-changes accepts an intended change (e.g. a label
#   or security default for every app): same lines, but `changed` no longer
#   fails the run. Render and fetch failures still do.
# - GOLDEN_OUT=<dir> keeps the renders (<app>.base.yaml / .head.yaml) for
#   diffing; it must be outside any git work tree, since private renders land
#   there. Otherwise everything goes to a temp dir removed on exit.
#
# bash 3.2-safe (macOS /bin/bash). Needs git, helm, yq v4, jq, gh.
set -uo pipefail

die() { echo "chart-golden: $*" >&2; exit 2; }
[ $# -ge 2 ] || die "usage: chart-golden.sh <base-ref> <head-ref|DIR:chart-dir> [--public-only] [--allow-changes]"
BASE=$1 HEAD_ARG=$2 PUBLIC_ONLY=false ALLOW_CHANGES=false; shift 2
for o in "$@"; do
  case $o in --public-only) PUBLIC_ONLY=true ;; --allow-changes) ALLOW_CHANGES=true ;; *) die "unknown option $o" ;; esac
done

TOP=$(git rev-parse --show-toplevel) || die "not in a git repo"
CHART=gitops/platform/common-app-chart
T=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT TERM

if [ -n "${GOLDEN_OUT:-}" ]; then
  mkdir -p "$GOLDEN_OUT" || die "cannot create GOLDEN_OUT"
  git -C "$GOLDEN_OUT" rev-parse --show-toplevel >/dev/null 2>&1 \
    && die "GOLDEN_OUT is inside a git work tree; private renders would be committable"
  OUT=$GOLDEN_OUT
else
  OUT=$T/out
fi

extract() { # <ref> <dest> <paths...>: git archive those paths at ref into dest
  local ref=$1 dest=$2; shift 2
  mkdir -p "$dest" && git -C "$TOP" archive "$ref" "$@" | tar -x -C "$dest"
}

case $HEAD_ARG in
  DIR:*)
    CH=${HEAD_ARG#DIR:}; [ -f "$CH/Chart.yaml" ] || die "no Chart.yaml in $CH"
    HEAD_REF=HEAD; SRC=$TOP ;;
  *)
    HEAD_REF=$HEAD_ARG; SRC=$T/head
    extract "$HEAD_REF" "$SRC" "$CHART" gitops/bootstrap gitops/platform/values || die "cannot extract $HEAD_REF"
    CH=$SRC/$CHART ;;
esac
MB=$(git -C "$TOP" merge-base "$BASE" "$HEAD_REF") || die "no merge-base for $BASE $HEAD_REF"
extract "$MB" "$T/base" "$CHART" || die "cannot extract $MB"
CB=$T/base/$CHART

USER_AS=$SRC/gitops/bootstrap/apps.applicationset.yaml
PLAT_AS=$SRC/gitops/bootstrap/platform-common-apps.applicationset.yaml

# The renders below hard-code ArgoCD's helm block exactly: ingress.hostname
# set to the element's hostname, valuesPath[0] then valuesPath[1] (or [0]
# again) for user apps, the platform values file for platform apps, nothing
# else. Any edit to either block, however small, stops here rather than
# render something ArgoCD would not.
helm_is() { # <yq path> <file> <expected valueFiles json>
  yq -o=json "$1" "$2" | jq -e --argjson vf "$3" '. == {valueFiles: $vf, parameters: [{name: "ingress.hostname", value: "{{.hostname}}"}]}' >/dev/null
}
helm_is .spec.template.spec.sources[0].helm "$USER_AS" '["$values/{{ index .valuesPath 0 }}", "$values/{{ if gt (len .valuesPath) 1 }}{{ index .valuesPath 1 }}{{ else }}{{ index .valuesPath 0 }}{{ end }}"]' \
  || die "apps.applicationset.yaml helm block changed; update this script"
helm_is .spec.template.spec.source.helm "$PLAT_AS" '["../values/{{.name}}/values.yaml"]' \
  || die "platform-common-apps.applicationset.yaml helm block changed; update this script"

US=$'\x1f'
elements() { # <file> <jq fields>: one US-separated line per element; error on a missing hostname
  yq -o=json '.spec.generators[0].list.elements' "$1" \
    | jq -r "if all(.[]; has(\"hostname\")) then .[] | [$2] | join(\"$US\") else error(\"an element has no hostname\") end"
}
elements "$USER_AS" '.name, .namespace, (.repoURL|sub("^https://github.com/";"")|sub("\\.git$";"")), .targetRevision, (.valuesPath|join(",")), .hostname' > "$T/user" || die "cannot read user elements"
elements "$PLAT_AS" '.name, .namespace, .hostname' > "$T/plat" || die "cannot read platform elements"

if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

fail=0 n_user=0
# compare <label> <show-stderr:true|false> <release> <namespace> <hostname> <values0> <values1>
compare() {
  local l=$1 loud=$2 o=$OUT/$1 err=/dev/null; shift 2
  $loud && err=/dev/stderr
  mkdir -p "$(dirname "$o")"
  local base_ok=true note=''
  helm template "$1" "$CB" -n "$2" -f "$4" -f "$5" --set "ingress.hostname=$3" >"$o.base.yaml" 2>"$err" </dev/null || base_ok=false
  if ! helm template "$1" "$CH" -n "$2" -f "$4" -f "$5" --set "ingress.hostname=$3" >"$o.head.yaml" 2>"$err" </dev/null; then
    echo "$l: render failed"; return 1
  fi
  case $l in platform/*) ;; *) n_user=$((n_user + 1)) ;; esac
  # A base that fails while head renders is a change (a chart fix), not a
  # render failure, so --allow-changes can accept it.
  if $base_ok && cmp -s "$o.base.yaml" "$o.head.yaml"; then echo "$l: unchanged $(sha "$o.head.yaml")"; return 0; fi
  $base_ok || note=' (base render failed)'
  echo "$l: changed $(sha "$o.head.yaml")$note"; $ALLOW_CHANGES || return 1
}

# visibility <owner/repo>: prints public|private|unreadable. Only a 404 is
# "unreadable" (private to this token, or gone); any other API error (bad
# token, rate limit, 5xx) is fatal, so a broken token cannot turn into a
# green run of skips.
visibility() {
  local out
  if out=$(gh api "repos/$1" --jq .private 2>&1 </dev/null); then
    [ "$out" = false ] && echo public || echo private # anything but false is private
  elif printf '%s' "$out" | grep -q 'HTTP 404'; then echo unreadable
  else return 1; fi
}

while IFS=$US read -r name ns repo rev vpaths host; do
  vis=$(visibility "$repo") || { echo "$name: fetch failed"; fail=1; continue; }
  if [ "$vis" = unreadable ] && ! $PUBLIC_ONLY; then echo "$name: fetch failed"; fail=1; continue; fi
  if [ "$vis" = unreadable ]; then echo "$name: skipped (unreadable by token)"; continue; fi # --public-only here
  if [ "$vis" = private ] && $PUBLIC_ONLY; then echo "$name: skipped (not public)"; continue; fi
  i=0 v0='' v1=''
  for p in $(echo "$vpaths" | tr , ' '); do
    f=$T/values/$name.$i.yaml; mkdir -p "$T/values"
    gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$p?ref=$rev" >"$f" 2>/dev/null </dev/null \
      || { echo "$name: fetch failed"; fail=1; continue 2; }
    # ArgoCD reads valuesPath[0] and [1] only (or [0] twice); ignore the rest.
    case $i in 0) v0=$f v1=$f ;; 1) v1=$f ;; esac
    i=$((i + 1)); [ $i = 2 ] && break
  done
  [ -n "$v0" ] || { echo "$name: fetch failed"; fail=1; continue; }
  loud=false; [ "$vis" = public ] && loud=true
  compare "$name" $loud "$name" "$ns" "$host" "$v0" "$v1" || fail=1
done < "$T/user"

while IFS=$US read -r name ns host; do
  v=$SRC/gitops/platform/values/$name/values.yaml
  compare "platform/$name" true "$name" "$ns" "$host" "$v" "$v" || fail=1
done < "$T/plat"

echo "user-apps-rendered: $n_user"
[ "$n_user" -gt 0 ] || fail=1
exit $fail
