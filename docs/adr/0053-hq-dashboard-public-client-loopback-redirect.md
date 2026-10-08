# ADR-0053: `hq.bnei.dev` — a public OIDC client for an SPA and MCP clients, and its loopback-redirect exception to ADR-0050

**Status:** Accepted — decided 2026-10-08, approved by M BN. Manifests on the
first PR: the app registration, `hqdb`/`dbuser_hq` in `pigsty/pigsty.yml`, the
provider and its policy, and the database Secret. **Not yet live:**
`DBUSER_HQ_PASSWORD` exists in Infisical (2026-10-08), but the role and the
database wait on the Pigsty playbook runs, and the Claude Code loopback and
claude.ai connector callback are **not registered yet** — both wait on hq's
spike to settle the port and the URL.
**Date:** 2026-10-08
**Related:** [ADR-0050](0050-public-oidc-client-for-native-apps.md) (public
clients, and the Decision 2 this makes an exception to),
[ADR-0051](0051-expose-hermes-dashboard.md) (the hermes policy-file convention),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (build-runner),
hq's own `docs/adr/0001-hq-dashboard.md` (the app-side decision)

## Context

hq is M BN's personal dashboard. It is a Go server with an embedded Svelte SPA
at `hq.bnei.dev`. It renders the hq repo's vision, project map and weekly
reviews. Edits and comments made in the browser land in Postgres as an inbox.
An MCP endpoint at `/mcp` lets Claude Code and claude.ai connectors drain that
inbox.

That puts three kinds of caller on one host:

- a browser running the SPA;
- Claude Code, a CLI on a laptop that receives its authorization code on a
  loopback listener;
- claude.ai's connector, which calls from the internet with a bearer token.

forwardAuth can serve none of them well. An MCP client cannot follow a 302 to
a login page. So the app authenticates every request itself, as an OIDC client
of authentik.

Two facts about the deployed authentik (2026.8.0) shape the rest. Both were
checked live on 2026-10-07:

- **No dynamic client registration.** The discovery document has
  `registration_endpoint: null`, and `/.well-known/oauth-authorization-server`
  returns 404. MCP clients cannot self-register.
- **PKCE is advertised but not required.** authentik advertises PKCE `S256`
  but does not require it. ADR-0050 Decision 3 handles this with a policy.

ADR-0050 Decision 2 allows exactly one `https://` redirect URI and **no
`http://localhost`**. The reason given: with implicit consent, a crafted
`/authorize` link plus anything listening on that port yields a code, with no
user interaction. Claude Code needs exactly that kind of redirect.

## Decision

1. **One public client, `hq`, for all three callers.** It is
   `client_type: public` with no secret (ADR-0050 Decision 1). The SPA and the
   CLI cannot hold a secret. The connector could, but a second, confidential
   client would give the server two audiences to pin. The `client_id` is
   committed in `gitops/bootstrap/authentik-blueprint-hq.yaml`. MCP clients
   are configured with it, because there is no dynamic registration.

2. **Exception to ADR-0050 Decision 2: one fixed-port loopback redirect.**
   `http://localhost:<port>/callback` is registered with
   `matching_mode: strict` on one fixed port. It is **never** a regex: a regex
   over the port accepts every listener on the machine. The claude.ai
   connector's callback is added alongside it, also strict. Both are omitted
   until hq's spike fixes the port and the URL. Each one, when added, is a
   reviewed one-line change to the blueprint.

3. **Explicit consent is the compensating control.** The provider uses
   `default-provider-authorization-explicit-consent`. It is the first provider
   on this cluster to do so; wird and hermes use implicit consent. A consent
   screen puts M BN in the loop on every new grant. That is the control whose
   absence ADR-0050 Decision 2 described: a crafted link can no longer finish
   silently. It costs one click per new client, and refresh tokens (validity
   `days=90`, threshold `days=3`) keep that rare.

4. **PKCE S256 and the access binding live in their own file,
   `authentik-blueprint-hq-policy.yaml`**, following the hermes convention
   (ADR-0051). The binding is to `platform-admins`. The application sets
   `policy_engine_mode: all`, so both bindings must pass.

5. **No forwardAuth on any path. The baseline chain stays.** ADR-0051's "two
   gates" rule does not apply. That rule is for a host whose session is a
   shell with no role floor. hq's session reads and writes M BN's notes and
   nothing more. The gate is the app's own token check, behind authentik's
   binding and consent. Origin lock, rate limit and headers still apply: hq's
   values must not disable the baseline.

6. **The server validates `aud` and `iss`, not only the signature.** Every
   provider here signs with the shared "authentik Self-signed Certificate", so
   a Grafana token verifies cleanly against hq's JWKS. The required checks:
   - `aud == <client_id>`
   - `iss == https://authentik.bnei.dev/application/o/hq/`

   This is the app's obligation. Nothing on the authentik side can enforce it.

7. **Database: Wird's pattern.**
   - `dbuser_hq` owns `hqdb`.
   - Role settings: `dbrole_readwrite`, `connlimit: 5`, `pgbouncer: false`
     (pgx and server-side prepared statements).
   - Only the SCRAM verifier is committed. The plaintext lives in Infisical as
     `DBUSER_HQ_PASSWORD`.
   - `hqdb` sets `revokeconn: true` and `register_datasource: false`.
   - `gitops/bootstrap/hq-secret.yaml` assembles `DATABASE_URL` into the
     Secret `hq-config`, as `wird-secret.yaml` does for Wird.

## Consequences

- MCP clients need the `client_id` configured by hand. If claude.ai's
  connector cannot take a pre-registered client id, this design does not reach
  it. hq's spike exists to find that out before the redirect lands.
- M BN clicks a consent screen on each new grant. That is the price of the
  loopback, paid on purpose.
- `platform-admins` also contains the `wird-agent` service account (#270). It
  cannot complete an interactive code flow, and consent would stop it if it
  could. A dedicated group is the upgrade path if that group grows.
- The plaintext-password drift in Pigsty is unchanged: this entry adds a
  verifier, not a plaintext.

## Not decided here

- hq's token handling, session model and MCP tool surface. These are in hq's
  `docs/adr/0001-hq-dashboard.md`.
- A `vite dev` redirect. Per ADR-0050, a dev provider would be a separate
  provider, never this one.
