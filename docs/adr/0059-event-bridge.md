# ADR-0059: Event bridge — `ukubi-bridge`, a Postgres-backed event bus feeding fleet agents

**Status:** Accepted, not built. Nothing is deployed by this ADR.
**Date:** 2026-10-18
**Related:** [ADR-0031](0031-defer-hpa-scale-to-zero.md) (Knative/KEDA deferred),
[ADR-0032](0032-thot-rbac-and-alerting.md) (Alertmanager → thot webhook),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (one build-runner
instance per build repo), [ADR-0035](0035-self-hosted-forgejo-authoritative-github-mirror.md)
(Forgejo, Proposed), [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md)
(WAF skip rule for a GitHub webhook), [ADR-0055](0055-netbird-as-daily-ssh-path.md)
(`netbird-agent` short-lived JWT). agent-fleet: `adr/0048` (one session, one pod;
no queue in core), `adr/0061` (gate amendment: registered clients open sessions),
`adr/0071` (event dispatch, threads, trust), `adr/0072` (approval-gated executor).

## Context

Agent-fleet is gaining *defined agents*: agents dedicated to one app or one
platform component (zot/buildah, traefik/netbird, each app repo), see
agent-fleet `adr/0061`–`0070`. Those agents are only useful if the right
information reaches them without the operator relaying it by hand: a PR to
review, an alert on the component they own, a hand-off from another agent.

Today there is no bus. One path exists: Alertmanager and Grafana POST to
agent-fleet core's `/webhook/alertmanager`, which files a *proposal*
(deduplicated by fingerprint) and pings Discord; a human opens it. It is
hard-coded to one repo. Everything else — GitHub, ArgoCD, zot, app events —
reaches no agent at all, and agents cannot message each other asynchronously.

The operator wants a bus that is a platform primitive, like Loki or
Prometheus: sources are GitHub, infra events, external feeds and app domain
events; subscribers are fleet agents (including a future always-on,
Hermes-type agent), apps, and agents publishing to each other. The binding
constraint is operating burden — one operator — and durability and replay
matter more than throughput.

The first concrete use (the 4-week success case): the operator pushes a PR on
an app repo; the app's owner agent reviews it automatically and publishes
"needs registry"; the zot/buildah agent drives onboarding to completion on
one surface (the fleet dashboard session), where each step only a human may
authorise is an approval button.

## Decision

1. **A new service, `ukubi-bridge`** (own repo, Go, own build-runner instance
   per ADR-0034), deployed as a user app through `common-app-chart`. One
   replica, `Recreate`. It is the only reader and writer of its database.
2. **Postgres on Pigsty is the store**, database `bridge`, no extension.
   - `events`: append-only log, `UNIQUE(source, ce_id)`, not partitioned,
     deleted by age (retention longer than the GitHub reconcile lookback).
     Inserts are serialised by an advisory lock so ids commit in order and a
     cursor can never skip a late-committing row — a global lock, acceptable
     at homelab volume; the upgrade path is an `xmin`-horizon cursor.
   - `subscriptions`: one row per named subscriber with `last_acked_id`.
     Delivery is head-of-line with backoff; after N failures the event goes
     to a dead-letter state and its subject is parked (later events on the
     same subject park too, preserving per-thread order).
   - The bridge connects to the primary directly, not through pgbouncer:
     `LISTEN` needs a session-mode connection and Pigsty pools in
     transaction mode.
3. **The envelope is CloudEvents 1.0** (proto). `subject` is the thread key
   (`repo/<name>/pr/<n>`, an alert fingerprint, …). Extensions: `owner`,
   `actor` (`human|bot|agent|machine`), `trust`, `hops`, `causationid`,
   `replayed`.
4. **The API is gRPC (Connect)**: `Publish`, `Subscribe(name)` (stream),
   `Ack`, `Replay`. Only `Replay` sets `replayed`. Subscribers must be
   idempotent on the event id.
5. **Push sources are ingested by the bridge itself.**
   - GitHub through a **GitHub App** (one install, HMAC, deliveries API).
     `X-GitHub-Delivery` is the `ce_id`. An in-process reconcile loop
     redelivers deliveries missing from the log, which covers both bridge
     downtime and events lost to a Pigsty failover.
   - Only an allowlist of event types is accepted (PR
     opened/synchronize/closed/reopened, `issue_comment`,
     `pull_request_review`) — not `check_run`, `status` or `push`, which
     fan out per commit and would wake agents in a loop.
   - Alertmanager and Grafana receivers that point at core today are
     repointed to the bridge. When Postgres is down the bridge answers 503;
     both retry.
   - Public ingress is `events.bnei.dev`, an IngressRoute **scoped to the
     webhook path**, with a Cloudflare WAF skip rule scoped to the same path
     (the ADR-0038 precedent for ArgoCD's webhook).
   - Pull sources (k8s events, email, calendar, RSS) come later, as separate
     publisher pods calling `Publish`.
6. **Trust is computed by the bridge, not taken from the sender.** For a PR
   it comes from the PR author and the head repo — a fork PR is never
   trusted, whatever account the webhook names as `sender`. Events caused by
   the thread's own agent identity are dropped. An event published by an
   agent inherits the lowest trust along its `causationid` chain.
7. **Agent-fleet core stays private and queue-free.** Agents never reach the
   bridge directly (definition pods may only talk to core, the vault and
   DNS). They publish through core's `PublishEvent`, which stamps the
   verified session and computes `hops`. Core consumes through one
   dispatcher subscriber that opens or resumes sessions through
   `AgentService.Open` as a registered client. Routing, threads, the actor
   gate and the session cap are agent-fleet `adr/0071`; the approval-gated
   executor is `adr/0072`.
8. **Apps subscribe later** through a `common-app-chart` `events:` block
   (`publish` types, `subscribe` filters) that the bridge reads as an
   allowlist, keyed by namespace. The bridge's TokenReview and ConfigMap-read
   RBAC ship as plain manifests — the chart does not template RBAC.

## Alternatives considered

- **NATS JetStream** — native fan-out, replay and push; a new stateful
  broker on Longhorn to babysit. Lost to reusing Pigsty's HA and pgBackRest.
- **Argo Events** — its EventSource CRDs cover GitHub, calendar and webhooks
  as YAML, but it adds a controller and still needs a JetStream EventBus.
- **Redis Streams on `redis-main`** — already running (ArgoCD's cache), but
  weaker persistence; agent-fleet already walked away from a Redis queue
  (its `adr/0001`).
- **Knative Eventing** — deferred with Knative itself (ADR-0031).
- **pgmq on top of the log** — per-message ack and retry, but a second copy
  of every event, a router whose transaction boundary was undefined, and an
  extension Pigsty does not ship here (`pg_extensions: [postgis, pgvector]`).
- **Spool to a PVC when Postgres is down** — makes the bridge stateful, the
  chart's single RWO PVC cannot serve two replicas, and it does not cover
  writes lost to an async-replication failover. Replaced by 503 plus the
  GitHub reconcile.
- **Everything inside agent-fleet core first** (a GitHub webhook next to the
  alert webhook) — fastest path to the first agent flow, but it needs a
  retry loop in core, which agent-fleet `adr/0048` §2 forbids, and makes a
  core path public on every host it serves. The bridge keeps both out of core.
- **Apps and agents reading Postgres directly** — makes the schema the
  public contract and hands database credentials to every app.

## Consequences

- One more service, repo, build runner and database to run. Agent-fleet core
  gains no public path.
- Pigsty replicates asynchronously (`pg_rpo` 1 MiB). A failover can lose an
  acknowledged non-GitHub event (ArgoCD, zot, a `Publish` call). Accepted;
  Alertmanager re-fires, GitHub is reconciled.
- A single bridge replica means a restart window; senders retry and GitHub
  is reconciled.
- The GitHub adapter is GitHub-specific. If Forgejo (ADR-0035) becomes the
  authoritative forge, it gets its own adapter; the envelope does not change.
- Webhook-driven agents read attacker-reachable text (PR bodies, comments,
  Renovate release notes). The trust rules above and the session taint in
  agent-fleet `adr/0071`/`0072` are the defence; quoting alone is not.

## Rollout

1. This ADR; agent-fleet `adr/0071` and `adr/0072`.
2. `ukubi-bridge` repo, build runner, Pigsty database and user, Infisical
   secrets (App key, webhook secret, database credentials), app
   registration, IngressRoute and WAF rule.
3. Repoint Alertmanager and Grafana; alert events carry thread semantics
   (`resolved` closes the thread).
4. Core `PublishEvent` and the dispatcher, after agent-fleet's definitions
   (`owns`/`subscribes`) and `AgentService.Open` exist.
5. The approval-gated executor, after agent-fleet's security phase and
   Agent Vault.
6. Pilot: the zot/buildah definition plus one app-owner definition, running
   the success case end to end.
