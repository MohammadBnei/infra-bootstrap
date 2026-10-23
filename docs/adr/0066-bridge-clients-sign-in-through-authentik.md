# ADR-0066: The bridge's API clients sign in through authentik; apps publish and subscribe within allowlists; core announces sessions waiting on a person

**Status:** Proposed. Decided 2026-10-23 by M BN in mountain's play research (`plan/09-play.md` in the private
`MohammadBnei/mountain` repo), in the interview that followed, and after one doubt cycle (three reviews: bridge code,
authentik and security, agent-fleet). Amends [ADR-0060](0060-event-bridge.md) Decision 2 (retention), Decision 4 (who
calls the API) and Decision 8 (how apps join), plus its status line. Amends agent-fleet `adr/0071` §2 to §4 (reserved
types, the loader).
**Date:** 2026-10-23
**Related:** [ADR-0060](0060-event-bridge.md) (the bus), [ADR-0039](0039-authentik-identity-layer.md) (authentik is
the identity layer), [ADR-0055](0055-netbird-as-daily-ssh-path.md) (`netbird-agent`: the service-account
`client_credentials` precedent), [ADR-0049](0049-shared-commons-secrets-in-common-app-chart.md) (where a shared value
lives), [ADR-0063](0063-infisical-lan-split-horizon.md) (pods use backend Services). agent-fleet: `adr/0066`
(AgentService, its clients and what each may see), `adr/0067` (session visibility), `adr/0071` (the dispatcher and the
gate).

## Context

ADR-0060 says "not built", but most of the bridge exists:
- **The service** (`MohammadBnei/ukubi-bridge`, main `44a7642`) has GitHub App ingest with HMAC, the type allowlist
  and the trust rules, the reconcile loop, the Alertmanager and Grafana endpoints, and the Connect API (`Publish`,
  `Subscribe`, `Ack`, `Nack`, `Replay`) with head-of-line delivery, dead letters and subject parking.
- **The platform side** (rollout step 2, #340) has the Pigsty user and database, the Infisical secrets, the app
  registration, the `events.bnei.dev` route and the build runner.

Not built:
- deletion by age;
- rollout step 3 (Alertmanager and Grafana still post to agent-fleet core);
- step 4 (core's `PublishEvent` and dispatcher; `definitions/clients/bridge.yaml` exists but opens nothing);
- steps 5 and 6.

The live state is unverified here: the cluster is down at the time of writing.

mountain's game (plan/09) puts apps on the bus for the first time:
- the game publishes "a person is needed";
- a push sender, a separate subscriber, turns that into a phone notification;
- agent-fleet core announces when one of the game's sessions waits on a person.

Several parts of ADR-0060 and of the code don't fit that:
- **API clients authenticate with static bearers.** `BRIDGE_CLIENTS` holds the sha256 of each token
  (`internal/bus/bus.go:41`). The only client is `core`, and its token has never been sent. The owner wants authentik
  to tell who did what everywhere.
- **Subscribing is a yes/no** (`bus.go:47`). The filter is whatever the caller asks for, and an empty filter matches
  everything, so any subscriber could read GitHub PR text, alerts and agent hand-offs.
- **Decision 8** planned a `common-app-chart` `events:` block with TokenReview by namespace. None of it exists.
- **Deletion by age** would remove events behind a parked subject, and a consumer whose cursor fell behind would
  resume silently at the oldest event left.

## Decision

1. **Every API client is an authentik service account and calls the bridge with an authentik access token.**
   - **The provider.** One OAuth2 provider and application, `ukubi-bridge-api`. It is a different object from the
     GitHub App `ukubi-bridge`. Its fields are fixed here:
     - `grant_types: [client_credentials]` and no redirect URI;
     - `signing_key`: the shared `authentik Self-signed Certificate` (RS256). Without it, authentik signs with HS256
       using the client secret;
     - `access_token_validity: minutes=10`, `sub_mode: user_username`, `issuer_mode: per_provider`;
     - `authorization_flow` set to the implicit-consent flow and `invalidation_flow` to the default, which every
       OAuth2 provider requires even when no browser uses it;
     - no `jwt_federation_providers` and no `jwt_federation_sources`.

     The provider's client secret is never handed out: a grant with it creates an `ak-…-client_credentials` account
     of its own.
   - **The accounts.**
     - One `type: service_account` user per client, named `bridge-<client>`. Each has its own blueprint file with an
       app-password token and its own policy binding to the application (the `netbird-agent` shape). That binding is
       what stops other accounts: authentik checks application access on every `client_credentials` path.
     - All three accounts (`bridge-core`, `bridge-game`, `bridge-push`) are declared in rollout step 2, before anything
       uses them. Before the first apply, check that no user named `bridge-*` already exists: the blueprint matches on
       username and would take that account over.
     - `bridge-`, `netbird-` and `ak-` are reserved prefixes in the `mountain-handle` policy and in a username policy
       on wird's enrollment.
     - Users cannot change their own username (authentik's "Allow users to change username" is off, declared, not
       clicked). Otherwise a visitor could rename into a future `bridge-<client>` before its blueprint lands. Every
       later client's rollout repeats the `bridge-*` username check.
   - **The app passwords** are `BRIDGE_<CLIENT>_APP_PASSWORD` in the root project (`infra-bootstrap-1-ge1`). The
     blueprint renders the key, and a `gitops/bootstrap/<client>-bridge-secret.yaml` delivers it to the client's
     namespace. This is the `NETBIRD_AGENT_APP_PASSWORD` arrangement, not `platform-commons`: each value has exactly
     two consumers, authentik and its client (ADR-0049).
   - **The issuer is the public one:** `https://authentik.bnei.dev/application/o/ukubi-bridge-api/`. authentik builds
     `iss` from the request host. So clients run the grant against the in-cluster Service
     (`platform-authentik-server.authentik.svc`) with `Host: authentik.bnei.dev` and `X-Forwarded-Proto: https`, and the
     bridge reads the JWKS from the same Service (its content does not depend on the host), so neither depends on
     Cloudflare. The rollout decodes a live token to check
     `iss`.
   - **What the bridge checks:**
     - the signature, RS256 only (never HS* or `none`), against **the pinned certificate** in the bridge's config
       (`BRIDGE_OIDC_CERT`, one or more PEM certificates during a rotation). That certificate is the only trust
       anchor. Amended 2026-10-23, after the build's doubt cycle: the JWKS is fetched over the pod network, where an
       agent pod could spoof the reply and so forge a token for the privileged `bridge-core`. The bridge fetches the
       JWKS hourly only to warn when it no longer contains a pinned key, which is what a rotation looks like;
       rotating means adding the new certificate to the config, then removing the old one. With no certificate
       pinned, every API call is refused and the webhooks keep working;
     - `iss`, `aud` and `azp` (the provider's client id), and `exp` with no leeway (`nbf` and `iat` get one minute).

     The signing key is shared by every provider, so the `iss` and `aud` checks are what make a token this bridge's:
     a mountain or Grafana token fails them.
   - **Who the caller is.** `sub` (the username) names the client in the bridge's table. An unknown `sub` is
     `Unauthenticated`.
   - **Streams expire with their token.** The bridge ends a `Subscribe` or `Replay` stream at its token's `exp`, and the
     client reconnects with a fresh token; an event in flight then is redelivered, as after any disconnect. A token with
     less than 5 seconds left cannot open a stream (it would end at once), which stays under the 10-second refresh margin
     of common OAuth clients. Deactivating an account in authentik therefore takes effect within 10
     minutes. Revoking a single token in authentik has no effect, because the bridge validates offline.
   - **The client table stays in the bridge, without secrets.** Its shape is `{name: {kind, publish_types,
     publish_subjects, subscribe, privileged}}`, where `subscribe` is a list of rules `{types, subjects}` (Decision 2).
     - It moves from Infisical to the bridge's `helm/values.yaml`, behind CODEOWNERS.
     - The bridge refuses to start if any client other than `bridge-core` is `privileged`.
     - `BRIDGE_CLIENTS` leaves `gitops/bootstrap/ukubi-bridge-secret.yaml`, and `BRIDGE_CORE_TOKEN` is deleted, both
       after the new bridge runs (Rollout step 3). The running bridge reads `BRIDGE_CLIENTS`; no client ever used
       `core`'s token.
   - **Core moves too, as `bridge-core`.** That is a second identity, never core's console OIDC client. A failed grant
     must not stop core from starting: the dispatcher retries and the rest of core runs.
   - **Unchanged:** GitHub keeps its HMAC, and Alertmanager and Grafana keep `BRIDGE_ALERT_TOKEN`, because neither
     sender can run an OAuth grant.

2. **Subscribing is bounded like publishing, for every client, core included.**
   - A client's `subscribe` is a list of rules. Each rule pairs type prefixes with subject prefixes, where `""`
     allows any subject. A client needs one subscription per rule: bridge-game's session events and its alerts are
     two subscriptions (`bridge-game/sessions`, `bridge-game/alerts`).
   - A `Subscribe` is accepted only when one rule covers its whole filter, and is refused when:
     - its type list is empty;
     - a requested type does not start with one of that rule's type prefixes;
     - its subject list is empty while the rule's subjects are not `""`;
     - a subject glob does not start with one of that rule's subject prefixes before its first `*` or `?`.
   - `privileged` changes only what a client may stamp on `Publish` (actor, trust, owner, hops). It never widens what
     it may read: bridge-core's rules exclude the human-facing types, so the bridge itself enforces Decision 4's read
     half, not only agent-fleet's loader.
   - `Replay` re-checks the stored filter against the table, so a client that loses a right cannot read history with
     it.
   - Type prefixes are written with their final dot (`dev.bnei.game.`), so a name never matches a longer one by
     accident.

3. **Reserved types and the clients' allowlists:**

   | Client | Publishes | Subscribes to |
   |---|---|---|
   | `bridge-core` (privileged) | `dev.bnei.agent.` (hand-offs) and `dev.bnei.fleet.session.`, subjects `fleet/` plus core's threads | one rule: `dev.bnei.github.`, `dev.bnei.alert.`, `dev.bnei.agent.` on any subject |
   | `bridge-game` (mountain's game) | `dev.bnei.game.`, subjects `game/` | two rules: `dev.bnei.fleet.session.` on `fleet/client/game/`; `dev.bnei.alert.` on any subject |
   | `bridge-push` (the push sender, its own ADR) | nothing | one rule: `dev.bnei.game.needs_you.` on `game/` |

   - **`dev.bnei.fleet.session.waiting` and `.resumed`** mark the edges of a session's pending decisions: unanswered
     questions and permission requests, where a plan to approve is a permission request for `ExitPlanMode`.
     - Core publishes `waiting` when the count goes from 0 to more, and `resumed` when it returns to 0. It recomputes
       after every append that asks or answers a decision, and when a stale decision is closed.
     - **Only for sessions opened by a client that opts in** (a field in agent-fleet's `definitions/clients/<name>.yaml`).
       The subject is `fleet/client/<client>/<thread id>`. Console and member sessions are never announced, so no
       client learns of a session AgentService would hide from it (agent-fleet `adr/0066`, `adr/0067`).
     - **Data:** `{thread_id, pending, reasons, position}`, where `reasons` lists `question`, `permission` or `plan`,
       and `position` is the id of the transcript entry whose append changed the count. It is durable and grows per
       session, so it survives a core restart; it is not the bridge's log `seq`. Never the definition, the opener, a
       prompt, a tool input or any transcript text.
     - **Envelope:** `actor=machine`, `actor_login=core`, `trusted=false`, no `owner`, no `causation_id`. The CloudEvent
       id is `<thread id>:<position>`.
     - **These events are hints.** Core holds no queue (agent-fleet `adr/0048` §2), so a publish lost while the bridge
       or authentik is down is gone. The game applies the highest `position` it has seen per thread, and reconciles with
       AgentService's status of its own threads at start and on a timer.
   - **`dev.bnei.game.needs_you.<kind>`** is the game's decision that a person should be told.
     - Data: the authentik username to notify and a link into the town.
     - Never an app, a host or a prompt. The push sender sends only a generic text and the link.

4. **Nothing an agent runs reads or forges the human-facing types.**
   - agent-fleet's definition loader refuses a `spec.owns` or `spec.subscribes` when:
     - its `types` list is empty;
     - a type prefix is a prefix of, or starts with, `dev.bnei.fleet.session.` or `dev.bnei.game.`;
     - a subject glob can match `fleet/` or `game/`.
   - Core's `PublishEvent` refuses those type prefixes and `fleet/` and `game/` subjects, so an agent cannot announce a
     wait for someone else's session.
   - Otherwise an agent woken by its own wait would loop, and a game event's text would become a prompt.

5. **An app's event is never trusted.** This is already the code for a non-privileged client:
   - `actor` is the client's `kind`, and `actor_login` is its name;
   - `trusted=false`, and no `owner`;
   - `hops` is the client's claim plus one.

   Under agent-fleet `adr/0071` §6 such an event can at most file a proposal; it never opens or wakes a session. The
   game gives orders to agents over AgentService as a registered fleet client (plan/09), never through the bus.

6. **Retention: events are deleted by age, 30 days** (ADR-0060 §2). The bridge is the transport, not the record. Each
   consumer keeps its own durable state, idempotent on `(source, id)`.
   - **Parked events are kept.** Deletion skips any event behind an uncleared dead letter on its subscription and
     subject. A Grafana alert fires on a dead letter left uncleared for 3 days.
   - **A gap is announced, never silent, and never false.** Amended 2026-10-23 after the build's review passes. Each
     deletion run deletes everything ingested before the cutoff (by the bridge's `ingested_at`, never the publisher's
     `time`), except events kept behind an uncleared dead letter, and, in the same transaction, for every subscription
     whose cursor is behind:
     - if a deleted event matched its filter and was never acked, it records or widens the gap (the deleted range)
       and bumps the gap's version;
     - the cursor moves past the deleted range, so a quiet subscription is not left behind, but stops before any kept
       event the subscription still has to receive (another subscription's parked subject must not hide it).

     The next `Subscribe` first sends one message carrying the gap and its version, then the events as usual; a gapped
     stream that is live is ended, so it reconnects to it. The consumer resyncs (the game from AgentService and its
     own database) and **confirms the gap** with an `Ack` carrying that version. It is sent on every reconnect until
     confirmed, and confirming an older version (one a later run widened) does nothing. A `Replay` from below the
     watermark streams what is kept, parked events included, after a first message saying that events in the range
     may have been deleted; it is never refused. The run locks `dead_letters`, so an operator's unparking cannot land
     between its steps.
   - **Dedup holds only within retention.** An alert still firing after 30 days, or a republish of an old id, comes
     back as a new event.

7. **Decision 8 of ADR-0060 is replaced.** No `events:` block in `common-app-chart`, no TokenReview, no ConfigMap
   RBAC. A new client is four reviewed changes:
   - its service account blueprint, here;
   - its app password in Infisical;
   - its secret delivery to its namespace;
   - an entry in the bridge's client table.

## Alternatives considered

- **Keep the static bearers.** This is what's built. Every client is a secret the bridge compares, and nothing in
  authentik shows who published. Rejected by the owner: authentik is the one place identity lives.
- **Federated Kubernetes service-account tokens.** authentik can accept a pod's projected token as a
  `client_assertion` against an OAuth source pointed at the cluster's JWKS. That removes the static secret. It needs
  the API server's issuer discovery reachable from authentik and a property mapping to carry the namespace. Deferred:
  the service account is the shape already running (`netbird-agent`). This stays the upgrade path.
- **TokenReview by namespace** (ADR-0060 §8). It needs no authentik dependency, but the bridge needs RBAC to call the
  API server, and identity stays outside authentik.
- **A longer token for core**, through a second provider, so the dispatcher rides out an authentik outage. Not
  chosen: one provider, one validity, revocation within 10 minutes.
- **A message broker** (RabbitMQ, NATS). Still rejected for ADR-0060's reasons: one more stateful service. RabbitMQ
  also deletes a message once acknowledged, so it cannot replay.
- **Keeping events forever** (the bridge as the event-sourcing record). Not chosen: consumers keep their own state, and
  the log stays small.

## Consequences

- **API calls depend on authentik.** A client with a valid token keeps working for up to 10 minutes of an outage.
  After that, `Publish` and `Subscribe` stop until authentik returns, and clients retry. So while authentik is down,
  event-driven agents don't hear events. That includes alerts about that same incident, which still reach Discord.
  GitHub ingest and the alert endpoints keep writing to the log, and core catches up when its grant succeeds again.
  authentik and the bridge both run on Pigsty, so a Pigsty outage stops both anyway.
- **Each client is one app password to rotate:** a new value in Infisical, the blueprint reapplied, and the client
  restarted. The bridge holds no secret for its API.
- **Renaming `core` to `bridge-core`** changes its source to `client/bridge-core` and its subscription names to
  `bridge-core[/…]`. Nothing is live yet, so nothing needs migrating.
- **The bridge code changes:**
  - token validation replaces the bearer comparison;
  - the client table gains the subscribe allowlists and loses `token_sha256`;
  - streams end at `exp`;
  - deletion runs with its watermark;
  - `Replay` re-checks rights;
  - the README and `bridge.proto` comments follow.
- **agent-fleet changes:**
  - core runs the grant;
  - core publishes the session edges for opted-in clients;
  - the loader and `PublishEvent` refusals;
  - the client opt-in field.

  Each lands in its own agent-fleet ADR.

## Rollout

1. This ADR, and the ADR-0060 status line.
2. Here:
   - the `ukubi-bridge-api` provider and application;
   - the three service accounts, each with its own binding (after the `bridge-*` username check);
   - the reserved prefixes in `mountain-handle` and in a wird username policy;
   - the username-change setting off;
   - the app passwords in Infisical, and `bridge-core`'s secret delivered to `agent-fleet`.
3. ukubi-bridge:
   - token validation, the client table in `helm/values.yaml` with CODEOWNERS;
   - the subscribe allowlists, stream expiry, and deletion with the watermark and kept dead letters;
   - the dead-letter alert;
   - then a live token decoded for `iss`;
   - only once that image runs: `BRIDGE_CLIENTS` out of the bridge secret here, and `BRIDGE_CORE_TOKEN` deleted.
     Until then the running bridge reads `BRIDGE_CLIENTS` at start.
4. agent-fleet:
   - core's grant, dispatcher and `PublishEvent` (ADR-0060 step 4);
   - the session edges and the client opt-in, in their own ADR;
   - the loader and `PublishEvent` refusals.
5. `bridge-game` and `bridge-push` go live with mountain's game service and the push ADR.
