---
name: dev-pod
description: Fast dev loop that runs a locally built app inside ukubi-cluster with no image build, registry push or ArgoCD deploy — a throwaway namespace, one alpine pod, the binary copied in with kubectl cp and hot-swapped, reached only through port-forward. Use when the user wants to iterate on app code against live cluster data/services (Prometheus, Alertmanager, Postgres, another app's API), test a change "on the real cluster" before merging, or asks for a dev pod / devpod.
user-invocable: true
allowed-tools:
  - Read
  - Bash(kubectl get ns -l purpose=dev*)
  - Bash(kubectl -n * get *)
  - Bash(kubectl -n * logs *)
  - Bash(git status *)
  - Bash(git diff *)
---

# /dev-pod — iterate against the live cluster without an image

Distilled from mountain's `scripts/devpod.sh` (verified live 2026-10-14).
The image path (build on `build-runner` → push to `registry.bnei.lan:5000`
→ ArgoCD sync) takes minutes and needs the LAN; this takes ~1 s per change
and works off-LAN. Template: `.claude/skills/dev-pod/devpod.sh`.

**This is not a deploy test.** It skips the chart, the Infisical secrets,
the IngressRoute, authentik and the real image. Before merge the app still
goes through `/add-app` + ArgoCD. Use this only to shorten the
code → live-data loop.

## How it works

1. Cross-compile a static linux/amd64 binary on the Mac.
2. Create a namespace labelled `purpose=dev`.
3. Run one bare pod (`docker.io/library/alpine`) whose command is a
   supervisor loop: `while true; do [ -x /app/bin ] && /app/bin <args>; sleep 1; done`
   over an `emptyDir` at `/app`.
4. `kubectl cp` the binary to `/app/bin.new`, then `mv` + `pkill` — the
   loop restarts it within a second.
5. Reach it only through `kubectl port-forward` — no Service, no
   IngressRoute, nothing public.
6. `down` deletes the namespace.

Pod hardening is in the template and must stay: `runAsNonRoot` (uid 65532),
`readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop ALL caps,
`cpu: 20m / memory: 32Mi` requests, `256Mi` limit.

## Commands

Copy the template into the app repo, edit the settings block (`NS`, `APP`,
`ARGS`, `PORTS`, `ENV_YAML`, `build()`), then:

```bash
cp ~/Code/infra-bootstrap/.claude/skills/dev-pod/devpod.sh scripts/devpod.sh
scripts/devpod.sh up      # ns + pod + first push, then port-forward (foreground)
scripts/devpod.sh push    # from another terminal: rebuild + hot-swap
scripts/devpod.sh logs    # follow app logs
scripts/devpod.sh down    # delete the namespace
```

`up` ends in a foreground `port-forward`; Ctrl-C stops the forward, not the
pod. `DEVPOD_NS=foo-dev scripts/devpod.sh up` overrides the namespace.

## Non-Go apps

The template only needs `build()` to leave something executable at `$BIN`.

- **Any static binary** (Rust `--target x86_64-unknown-linux-musl`, Zig,
  C with musl): same flow, change `build()`.
- **Interpreted apps** (Python, Node, Ruby): swap the image for a matching
  runtime (`python:3.12-alpine`, `node:22-alpine` — keep the `-alpine`
  variant, see `kubectl cp` gotcha), `kubectl cp` the source dir instead of
  a binary, and make the supervisor run `python /app/src/main.py` /
  `node /app/src/index.js`. Hot-swap is then: cp sources, `pkill` the
  interpreter. Dependencies either vendored into the copied dir or
  installed once into another `emptyDir` (`pip install --target`,
  `npm ci` with `HOME`/cache pointed at `/tmp`).

## Safety rules

- **Throwaway namespace only.** Never point `NS` at the app's real
  namespace (or any namespace ArgoCD manages) — a stray pod there drifts
  the Application, and `down` would delete the real one.
- **No secrets copied from other namespaces** unless the user explicitly
  asks for it. Prefer read-only, unauthenticated in-cluster endpoints; if a
  credential is needed, pass it via `ENV_YAML` from the user's own shell,
  never commit it.
- **No Service, no IngressRoute, no NodePort.** Port-forward is the only
  way in; that is what keeps a half-finished build off the internet.
- **Always `down` when done.** Then check for leftovers, including from
  other sessions:
  ```bash
  kubectl get ns -l purpose=dev
  ```
  Anything listed there is a dev pod someone forgot; ask before deleting
  one you didn't create.

## Gotchas

- **amd64.** Cluster nodes are amd64, the Mac is arm64:
  `GOOS=linux GOARCH=amd64 CGO_ENABLED=0`. A wrong-arch binary fails in the
  loop with `exec format error` every second — check `logs`.
- **KUBECONFIG.** The default `~/.kube/config` has no ukubi context; the
  template defaults to `~/.kube/ukubi-admin.conf` (cluster-admin, talks to
  the API VIP directly — not `ssh k9s` like `/k8s-ops`).
- **Why not the registry:** `registry.bnei.lan:5000` does not resolve off
  the LAN, so a local push fails. docker.io pulls work from the cluster.
- **readOnlyRootFilesystem:** the app can write only to the `emptyDir`s
  (`/app`, `/tmp`). An app that writes to `$HOME`, a cache dir or its own
  working dir needs that path pointed at `/tmp` or another emptyDir added.
- **`kubectl cp` needs `tar` in the image** — hence alpine, not
  distroless/scratch. `pkill` comes from busybox too.
- **Origin/CORS checks:** the browser sees `http://127.0.0.1:<port>`.
  An app that checks `Origin` (websockets especially) needs a dev flag
  that allows `http://127.0.0.1:*` / `http://localhost:*` — and that flag
  must never be on in the real chart.
- **NetworkPolicies:** only `argocd`, `has-journal` and `thot` have them;
  a dev pod can't reach services there. Everything else is open, e.g.
  Prometheus `platform-prometheus-kube-p-prometheus.monitoring:9090` and
  Alertmanager on `:9093` (`monitoring` has no NetworkPolicy).
- No admission policy blocks this pod shape today (verified 2026-10-14).
- `ARGS` is spliced inside a single-quoted `sh -c`; keep single quotes
  out of it.

## What this skill does not do

- Doesn't deploy, register or expose an app — that's `/add-app`.
- Doesn't build images — that's `build-runner-ops`.
- Doesn't touch ArgoCD-managed namespaces, and doesn't leave anything
  running: every session ends with `down` + `kubectl get ns -l purpose=dev`.
