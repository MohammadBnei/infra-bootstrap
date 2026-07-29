# ADR-0027: Loki + Grafana Alloy for centralized logging (over ClickHouse, over Promtail)

**Status:** Accepted
**Date:** 2026-07-29

## Context

`ARCHITECTURE.md` §9 had flagged "Loki + Promtail for centralized logging"
as under consideration but not committed since the observability section
was first written — no log storage backend or shipping agent existed.
Two real alternatives were weighed for each half of the decision before
implementing (PRs #54–#57):

**Storage backend — Loki vs. ClickHouse:**

- **ClickHouse** — a general-purpose OLAP database. Using it for logs means
  either hand-rolling a schema + ingestion pipeline (a shipper writing rows
  into a defined table), or running a purpose-built product on top of it
  (SigNoz, HyperDX). Grafana needs the community `grafana-clickhouse-datasource`
  plugin (not bundled), and alert rules become raw SQL instead of LogQL.
  Meaningfully heavier to run/operate (schema/TTL management, higher
  baseline RAM) than this homelab's log volume ever stresses — its real
  advantage (fast SQL analytics over huge volumes) is unused headroom here.
- **Loki** — purpose-built for this exact job. First-class Grafana
  integration (LogQL, Explore, alerting-as-code all work with zero plugin),
  SingleBinary + filesystem-storage mode needs no separate object store,
  and its resource footprint matches this cluster's existing bias toward
  the smallest tool that does the job (same reasoning ADR-0002 used to
  reject Ceph).

**Log-shipping agent — Grafana Alloy vs. Promtail:**

- **Promtail** — Grafana Labs' original purpose-built shipper. Plain-YAML
  config, does exactly one job (tail container logs, push to Loki) in a
  few dozen lines. Status: Long-Term Support — maintained for bugfixes,
  no new features, not going away imminently but frozen in scope.
- **Alloy** — Grafana's newer unified collector, a distribution of the
  OpenTelemetry Collector. Natively speaks OTLP (can receive
  traces/metrics/logs pushed via the OTel protocol from instrumented
  apps), in addition to today's job of tailing/shipping container logs.
  Heavier config surface for the logs-only job alone.

## Decision

- **Loki**, SingleBinary deployment mode, filesystem storage (no
  minio/S3) — `gitops/platform/values/loki/values.yaml`. Chart migrated
  off `grafana.github.io/helm-charts` to `grafana-community.github.io/helm-charts`
  (~March 2026); Loki's own `validate.yaml` requires the SimpleScalable
  mode's `write`/`read`/`backend` replicas explicitly zeroed alongside a
  nonzero `singleBinary.replicas` — not just left at chart defaults (all
  default to 3).
- **Grafana Alloy**, DaemonSet, logs-only config today (`discovery.kubernetes`
  → `discovery.relabel` → `local.file_match` → `loki.source.file` →
  `loki.process` (`stage.cri`) → `loki.write`) —
  `gitops/platform/values/alloy/values.yaml`. Picked specifically because
  OTel instrumentation (traces/metrics) is on this project's roadmap;
  choosing Alloy now avoids a second agent migration later. OTLP receiver
  components aren't wired up yet (YAGNI — nothing sends OTLP today), but
  the same config file is where they'd go. See ARCHITECTURE.md §9 for the
  detailed pipeline diagram — the original implementation used
  `loki.source.kubernetes` (kubelet API proxy) instead of hostPath file
  tailing; switched 2026-07-29, see Consequences below.
- **Grafana-native alerting**, not Loki's own Ruler and not routed through
  k8s Alertmanager — alert rules query the Loki datasource directly via
  Grafana's unified alerting, routing through the same Discord contact
  point Alertmanager already uses (reuses the `alertmanager-discord-webhook`
  secret from ADR/PR #51, mounted as a file into the Grafana pod).
- **Per-app log alerts**: `common-app-chart` gained a `logAlerts:` values
  block (PR #54) — a user app declares a LogQL condition/threshold in its
  own `values.yaml`, rendering a ConfigMap labeled `grafana_alert: "1"`
  that Grafana's alerts sidecar (`sidecar.alerts`, cluster-wide
  `searchNamespace: ALL`) picks up dynamically. Routing stays
  platform-owned (one shared contact point); apps only own *when* to alert.

## Consequences

- Two real, non-obvious runtime bugs only surfaced once actually deployed
  (neither was catchable by `helm template`/YAML-lint alone — see PR #55
  for the Loki chart-schema ones, PR #56 for the Grafana one):
  - Grafana's `slack`-type contact point rejects `url` under
    `secureSettings` outright for this chart's Grafana version (11.4.0) —
    it has to be under plain `settings` (still redacted in API responses
    despite the placement). Root-caused and fixed against a real local
    Grafana container, not guessed from docs a second time.
  - Loki's `lokiCanary` is a top-level values key, not nested under
    `monitoring:` — nesting it there is a silent no-op (Helm accepts
    unknown keys without error).
- `.github/workflows/lint.yml`'s `helm lint / template` step only renders
  the local `common-app-chart` — it does not render the third-party
  charts (`loki`, `alloy`, `grafana`, `prometheus`, ...) that
  `platform.applicationset.yaml` actually deploys. A CI step that
  `helm template`s those against their real pinned chart versions would
  have caught the Loki bugs (and the Helm-`tpl`-escaping half of the
  Grafana bug) before merge — not yet added, flagged as follow-up work,
  not blocking this ADR.
- Loki's level filtering (for both the built-in dashboard and any
  per-app query) uses Loki's auto-computed `detected_level`, not
  `| json | level=...` — confirmed live that `detected_level` isn't a
  real indexed label (`/loki/api/v1/label/detected_level/values` returns
  empty) but filters correctly as a pipeline stage, and that it works
  uniformly whether an app logs JSON, logfmt-ish text, or plain text.
  This matters because most existing user apps (`vos-monolith`,
  `editable-blog`) don't emit JSON logs yet — a JSON-only filter would
  have silently excluded them.
- Retention is 14d (`compactor.retention_enabled` +
  `delete_request_store: filesystem`), tunable; PVC is 20Gi, ~60Gi raw
  disk once Longhorn's default 3x replication is accounted for.
- **Update 2026-07-29** (PR #67): `loki.source.kubernetes` proxies log
  reads through the kubelet API. When a pod is deleted — this cluster's
  CI-driven app namespaces redeploy frequently — its tailer goroutine
  could leak instead of tearing down, then loop forever re-requesting the
  now-garbage-collected container's log and forwarding the kubelet's
  literal `unable to retrieve container logs for containerd://<id>` error
  text into Loki as if it were real application output (confirmed live
  via a direct Loki query — 15+ duplicate garbage lines under a dead
  pod's label set, polluting any query scoped to that namespace). Fixed
  by switching to `local.file_match` + `loki.source.file` (hostPath
  `/var/log/pods` tailing, filtered per-node via the chart's built-in
  `K8S_NODE_NAME` env var) — this never touches the kubelet API, so a
  deleted pod's log file just disappears instead of erroring. Also
  bumped the alloy chart `0.12.0` → `1.11.0` while touching this file
  (checked: no breaking changes in that range affect any component used
  here). See ARCHITECTURE.md §9's whitebox section for the full pipeline.
