---
name: grafana-ops
description: Create or update Grafana dashboards and alert rules, platform-level or per-app, all routed through the shared Discord webhook. Use when the user asks to add/change a Grafana dashboard, add an alert rule, or wants dashboard/alert notifications wired to Discord.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Bash(git diff *)
  - Bash(git status *)
---

# /grafana-ops — Grafana dashboards & alerts, routed through Discord

Encodes `gitops/README.md`'s "common-app-chart" section and
`gitops/platform/values/grafana/values.yaml`'s alerting/dashboard blocks.
Every alert (platform or per-app) already routes through one shared Discord
contact point — this skill never creates a second webhook or receiver.

## Step 0 — pick the axis

Ask (if not already stated): **dashboard or alert**, and **platform-wide or
per-app**? That's 4 combinations, each with a different file to touch:

| | Dashboard | Alert |
|---|---|---|
| Platform-wide | `gitops/platform/values/grafana/values.yaml` (`dashboards.gitops.<key>`) | `gitops/platform/values/prometheus/values.yaml` (Alertmanager) or `grafana/values.yaml` (`alerting.rules.yaml`) |
| Per-app | app's own `values.yaml` (`dashboards:`) | app's own `values.yaml` (`logAlerts:`) |

## 1. Platform dashboard

Edit `gitops/platform/values/grafana/values.yaml`'s `dashboards.gitops.<key>`
map: add a new key with the raw dashboard JSON as the value. Static file
provisioning (`editable: false`) — stays locked from UI edits, this repo is
the source of truth. Live on next ArgoCD sync, no manual import.

## 2. Per-app dashboard

This lives in the **app's own repo**, not here — this skill can only give
the shape to hand the user:
```yaml
dashboards:
  enabled: true
  items:
    overview: |
      { "title": "My App Overview", "panels": [...], ... }
```
Renders a ConfigMap labeled `grafana_dashboard: "1"`, picked up dynamically
by Grafana's dashboards sidecar (`sidecar.dashboards` in
`gitops/platform/values/grafana/values.yaml`). Lands in Grafana's default
("General") folder — deliberately no dedicated folder (a `defaultFolderName`
broke Grafana's own provisioning walk on 2026-08-01, logging "failed to
walk provisioned dashboards: stat ...: no such file or directory", because
that subdirectory only gets created on first matching ConfigMap, not
upfront; see the comment in that values file before reintroducing one).

## 3. Platform alert

Metric-level (via Alertmanager) or a cluster-wide Grafana native rule:
- Alertmanager: `gitops/platform/values/prometheus/values.yaml`'s
  `alertmanager.config.route`/`receivers` — reuse the existing `discord`
  receiver, never add a second one.
- Grafana native (LogQL/Loki, not tied to one app): add a rule to the
  `gitops-log-alerts` group (or a new group) in `grafana/values.yaml`'s
  `alerting.rules.yaml` — reuse the existing `discord` contact point +
  notification policy.

## 4. Per-app alert

Already built — this lives in the **app's own repo**'s `values.yaml`:
```yaml
logAlerts:
  enabled: true
  rules:
    - uid: high-5xx-rate      # only needs to be unique within this app
      title: High 5xx rate
      expr: 'sum(rate({namespace="myapp"} |~ "(?i) 5\\d\\d " [5m]))'
      threshold: 0.2
      for: 5m                 # optional, defaults to 5m
      severity: warning       # optional, defaults to warning
```
Same mechanism as dashboards: ConfigMap labeled `grafana_alert: "1"`,
picked up by `sidecar.alerts`, routed through the shared Discord contact
point automatically — the app only declares the condition/threshold.

## Known gotchas

These files have bitten before — carried forward from `k8s-ops`:

- **Slack contact-point `url` goes under `settings`, not `secureSettings`.**
  Confirmed live (2026-07-29 incident): this Grafana version (11.4.0)
  CrashLoopBackOffs at startup with `secureSettings` — "token must be
  specified when using the Slack chat API". `settings` fixed it; Grafana
  still redacts it in API responses regardless of placement.
- **Helm `tpl` re-processes the whole `alerting:` block.** Grafana's own
  alert-annotation templating (`{{ $labels.x }}`, resolved by Grafana at
  fire time) has to be escaped as literal text (backtick trick) or Helm
  tries to resolve it as a Helm variable at chart-render time and fails
  with "undefined variable". For a multi-line body (the `templates.yaml`
  notification templates), wrap the whole thing in ONE Helm raw string
  literal instead of escaping each brace pair — but then no backtick may
  appear inside it.
- **A Threshold expression needs a single value per series.** Feeding it
  directly from a multi-point range query errors with "duplicate results
  with labels {}" (12.3.1 words it "looks like time series data, only
  reduced data can be alerted on") — add a `reduce` (`last`) step between
  the query and the threshold, as `gitops-log-alerts` does. With
  `execErrState: Alerting` this does not fail loudly: it fires a real
  Discord alert whose only content is the error, which reads like a
  flapping app. common-app-chart shipped without the reduce step and did
  exactly that until 2026-08-12.
- **Aggregate `by (...)` if you want the notification to say anything.**
  `sum(count_over_time(...))` yields one labelless number, so the message
  can only say "N". `sum by (pod, msg) (...)` promotes the log's own
  fields to alert labels, which the Discord template prints. Grafana
  cannot put raw log lines in a notification at all — alert queries must
  reduce to numbers, so a group-by label is the only route.
- For any raw provisioning YAML edit (contact points, policies, rules),
  `helm template` only catches templating errors, not runtime schema
  rejections like the one above — smoke-test against a local
  `docker run grafana/<version>` before pushing if the change is
  non-trivial.

## What this skill does not do

- Doesn't create a new Discord webhook or contact point — one shared
  webhook already exists (`ALERTMANAGER_DISCORD_WEBHOOK_URL` in Infisical,
  see `docs/secrets.md`), reused via the `/slack`-suffixed URL trick by
  both Alertmanager and Grafana. Every alert should route through the
  existing `discord` receiver/contact point.
- Doesn't apply anything live — these are all GitOps files, ArgoCD syncs
  after merge. Use `/k8s-ops` to check the rollout or debug a sync
  failure, don't `kubectl apply` from here.
- Doesn't touch a per-app repo directly (it's not this repo) — hand the
  user the values.yaml snippet to add there themselves.
