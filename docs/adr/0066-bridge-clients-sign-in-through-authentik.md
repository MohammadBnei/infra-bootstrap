# ADR-0066: The bridge's API clients sign in through authentik; apps publish and subscribe; agents announce when they wait on a human

**Status:** Proposed. Decided 2026-10-23 by M BN in mountain's play research (`plan/09-play.md` in the private
`MohammadBnei/mountain` repo) and the interview that followed. Amends [ADR-0060](0060-event-bridge.md) Decision 4 (who
calls the API), Decision 8 (how apps join), and its status line.
**Date:** 2026-10-23
**Related:** [ADR-0060](0060-event-bridge.md) (the bus), [ADR-0039](0039-authentik-identity-layer.md) (authentik is
the identity layer), [ADR-0055](0055-netbird-as-daily-ssh-path.md) (`netbird-agent`: the service-account
`client_credentials` precedent), [ADR-0049](0049-shared-commons-secrets-in-common-app-chart.md) (where a shared value lives).
agent-fleet: `adr/0066` (AgentService and its clients), `adr/0071` (the dispatcher and the gate).

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
- the game publishes "a player is needed";
- a push sender, a separate subscriber, turns that into a phone notification;
- agent-fleet core announces when a session waits on a human, so the game can show it.

Two parts of ADR-0060 don't fit that:
- **Decision 8** planned a `common-app-chart` `events:` block with TokenReview by namespace. The code has none of it.
- **The bridge authenticates API clients with static bearers.** `BRIDGE_CLIENTS` holds the sha256 of each token
  (`internal/bus/bus.go`). The only client is `core`, whose token is in Infisical and has never been sent.

The owner wants authentik to tell who did what everywhere, so a publisher must be an authentik identity.

## Decision

1. **Every API client is an authentik service account and calls the bridge with an authentik access token.**
   - **The provider:** one OAuth2 provider and application, `ukubi-bridge-api`. It allows the `client_credentials`
     grant only, with no redirect URI, `sub_mode: user_username`, and a short access-token validity (10 minutes). It
     is a different object from the GitHub App named `ukubi-bridge`.
   - **The accounts:** one service account per client, named `bridge-<client>` (`bridge-core`, `bridge-game`,
     `bridge-push`). Each is declared in a blueprint with an app-password token, the `netbird-agent` shape.
     - The app password is in Infisical, in the client's own project, never in `platform-commons` (ADR-0049: one
       consumer).
     - The application is bound to one group, `bridge-clients`, so no other account gets a token for it.
   - **The client:** it runs the grant (username plus app password), caches the token, and refreshes it before
     expiry.
   - **The bridge:** it validates the token.
     - The signature is checked against the provider's JWKS, cached and refetched on an unknown `kid`.
     - It checks `iss`, `aud` (the provider's client id) and `exp`.
     - It maps `sub` (the username) to its client table. An unknown `sub` is `Unauthenticated`.
   - **The client table stays in the bridge**, without tokens: `{name: {kind, publish_types, publish_subjects,
     subscribe, privileged}}`, keyed by the username. It holds no secret, so it moves from Infisical to the bridge's
     `helm/values.yaml`, where a new client is reviewed in a PR.
   - **Core moves too.** Core is `bridge-core`, the only privileged client. `BRIDGE_CORE_TOKEN` and the sha256 in
     `BRIDGE_CLIENTS` are deleted once the bridge accepts tokens; nothing ever sent them.
   - **Unchanged:** GitHub deliveries keep their HMAC. Alertmanager and Grafana keep `BRIDGE_ALERT_TOKEN`, because
     neither can run an OAuth grant.

2. **Event types and subjects are reserved per client**, as the client table's prefixes:

   | Client | Publishes | Subscribes to |
   |---|---|---|
   | `bridge-core` (privileged) | `dev.bnei.agent.`, any subject | GitHub, alerts, agent hand-offs (agent-fleet `adr/0071`) |
   | `bridge-game` (mountain's game) | `dev.bnei.game.`, subjects `game/` | `dev.bnei.agent.waiting`, `dev.bnei.agent.resumed`, alerts |
   | `bridge-push` (the push sender, its own ADR) | nothing | `dev.bnei.game.needs_you` |

   - **`dev.bnei.agent.waiting` and `dev.bnei.agent.resumed`** are published by core when a session blocks on a person
     (a permission, a question, a plan to approve) and when it moves on.
     - Subject: `fleet/session/<id>`.
     - Data: the session id, the definition, the client that opened the session, and the reason
       (`permission | question | plan`).
     - Never the prompt, the tool input or any transcript text.
     - Core's side is an agent-fleet ADR. This ADR only reserves the types.
   - **`dev.bnei.game.needs_you`** is the game's decision that a person should be told.
     - Data: the authentik username to notify, a kind and a link into the town.
     - Never an app, host or prompt. The push sender sends only a generic text and the link.

3. **Nothing an agent runs subscribes to the human-facing types.** Core's dispatcher subscribes by an allowlist of
   type prefixes (agent-fleet `adr/0071` §4), and that list never contains `dev.bnei.agent.waiting`,
   `dev.bnei.agent.resumed` or `dev.bnei.game.`. agent-fleet's definition loader must refuse a `spec.subscribes`
   that matches them. Otherwise an agent woken by its own wait loops, and a stranger's text in a game event becomes
   a prompt.

4. **An app's event is never trusted.** This is already the code for a non-privileged client:
   - `actor` is the client's `kind`, and `actor_login` is its name;
   - `trusted=false`, and no `owner`;
   - the bridge sets `hops`.

   Under agent-fleet `adr/0071` §6 such an event can at most file a proposal; it never opens or wakes a session. The
   game gives orders to agents over AgentService as a registered fleet client (plan/09), not through the bus.

5. **Retention is unchanged: events are deleted by age** (ADR-0060 §2). The bridge is the transport, not the record.
   Each consumer keeps its own durable state:
   - the game folds the events into its own database, idempotent on `(source, id)`;
   - a consumer down for longer than retention has lost the gap.

   The deletion job is not built. Its window must exceed both the reconcile lookback and the longest consumer outage
   we accept: **30 days**.

6. **Decision 8 of ADR-0060 is replaced.** No `events:` block in `common-app-chart`, no TokenReview, no ConfigMap
   RBAC. A new client is three reviewed changes:
   - a service account in the blueprint, here;
   - its app password in Infisical;
   - an entry in the bridge's client table.

## Alternatives considered

- **Keep the static bearers.** This is what's built. Every client is a secret the bridge compares, and nothing in
  authentik shows who published. Rejected by the owner: authentik is the one place identity lives.
- **Federated Kubernetes service-account tokens.** authentik can accept a pod's projected token as a
  `client_assertion` against an OAuth source pointed at the cluster's JWKS. That removes the static secret. It
  needs the API server's issuer discovery reachable from authentik and a property mapping to carry the namespace.
  Deferred: the service account is the shape already running (`netbird-agent`). This stays the upgrade path.
- **TokenReview by namespace** (ADR-0060 §8). It needs no authentik dependency, but the bridge needs RBAC to call
  the API server, and identity stays outside authentik.
- **A message broker** (RabbitMQ, NATS). It is still rejected for ADR-0060's reasons: one more stateful service.
  RabbitMQ also deletes a message once acknowledged, so it cannot replay.
- **Keeping events forever** (the bridge as the event-sourcing record). Not chosen: consumers keep their own state,
  and the log stays small.

## Consequences

- **API calls now depend on authentik.** A client holding a valid token keeps publishing for up to 10 minutes of an
  outage. A new token needs authentik, so a longer outage stops `Publish` and `Subscribe` until it returns, and
  clients retry. GitHub and the alert endpoints don't depend on authentik. authentik and the bridge both run on
  Pigsty, so a Pigsty outage stops both anyway.
- **Each client is one app password to rotate.** Rotation means a new token in authentik, a new value in Infisical,
  and a restart of the client. The bridge holds no secret for its API.
- **The bridge gains a JWKS fetch** from authentik in-cluster. Which URL it reads, while checking the public issuer,
  is an implementation detail recorded in the bridge's README.
- **The bridge code changes:**
  - token validation replaces the bearer comparison;
  - `BRIDGE_CLIENTS` loses `token_sha256`;
  - the dispatcher in core runs the grant.

  Until that ships, no client is live, so nothing needs migrating.

## Rollout

1. This ADR, and the ADR-0060 status line.
2. The blueprint: the `ukubi-bridge-api` provider and application, the group `bridge-clients`, and the service
   account `bridge-core`; its app password in Infisical.
3. ukubi-bridge: token validation, the client table in `helm/values.yaml`, and deletion by age (30 days).
4. agent-fleet: core's dispatcher and `PublishEvent` with the grant (ADR-0060 step 4); `dev.bnei.agent.waiting` and
   `dev.bnei.agent.resumed` (its own ADR); the loader refusal (Decision 3).
5. `bridge-game` and `bridge-push`, with mountain's game service and the push ADR.
