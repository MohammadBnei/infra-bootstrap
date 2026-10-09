# ADR-0053: `hq.bnei.dev` — a public OIDC client for an SPA and MCP clients, and its loopback-redirect exception to ADR-0050

**Status:** Accepted — decided 2026-10-08, approved by M BN. Shipped in two
PRs: the authentik client, its own consent flow and policy, and
`hqdb`/`dbuser_hq` first, so hq's OAuth spike can run before any app exists;
the app registration, build runner and database Secret later, with hq's first
build. **Not yet live:**
`dbuser_hq`/`hqdb` **live 2026-10-09** (`pgsql-user.yml`, `pgsql-db.yml`
against `.205`, Patroni leader; `ignored=0` both). Verified past the recap:
`connlimit` 20, `dbrole_readwrite`, `hqdb` owned by `dbuser_hq` with PUBLIC
connect revoked, and a login with the Infisical plaintext through the `.232`
VIP that could create and drop a table.
**Date:** 2026-10-08
**Related:** [ADR-0050](0050-public-oidc-client-for-native-apps.md) (public
clients, and the Decision 2 this makes an exception to),
[ADR-0051](0051-expose-hermes-dashboard.md) (the hermes policy-file convention),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (build-runner),
hq's own `docs/adr/0001-hq-dashboard.md` (the app-side decision)

## Context

hq is a private dashboard for M BN: a Go server with an embedded Svelte SPA
at `hq.bnei.dev`, a Postgres inbox written from the browser, and an MCP
endpoint at `/mcp` that Claude Code and claude.ai connectors drain.

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
   `http://localhost:39871/callback`, Claude Code's `--callback-port` form,
   registered with `matching_mode: strict`. It is **never** a regex: a regex
   over the port accepts every listener on the machine. Alongside it, also
   strict, is claude.ai's connector callback,
   `https://claude.ai/api/mcp/auth_callback`. Both come from the vendors'
   published docs. A client that sends `127.0.0.1` instead of `localhost`
   gets a second strict entry, never a pattern.

3. **A consent screen on every authorization is the compensating control,
   and it needs hq's own flow.** The stock
   `default-provider-authorization-explicit-consent` flow does **not** provide
   it. Its consent stage runs in mode `expiring` (four weeks), and
   `UserConsent` is keyed on user and application, not on redirect URI
   (checked against 2026.8.0's source). Under it, one SPA login records
   consent for hq, and a crafted loopback link then completes silently for
   four weeks. So `authentik-blueprint-hq.yaml` declares its own flow,
   `hq-authorization`, bound to its own consent stage with
   `mode: always_require`. Its own, rather than retuning the shared stage,
   which would change consent for every app using it. The provider references
   it with `!KeyOf`, so a miss fails the blueprint loudly.

   The cost is a click at **every** authorization, SPA logins included.
   Refresh tokens (validity `days=90`, threshold `days=3`) keep that rare.
   Relaxing the mode to cut the clicks removes the control; that change needs
   this ADR amended first.

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
   - Role settings: `dbrole_readwrite`, `connlimit: 20`, `pgbouncer: false`
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
- M BN clicks a consent screen at every authorization, including each SPA
  login once its refresh token lapses. That is the price of the loopback, paid
  on purpose.
- `platform-admins` also contains the `wird-agent` service account (#270). It
  cannot complete an interactive code flow, and consent would stop it if it
  could. A dedicated `hq-users` group was considered and declined by M BN
  (2026-10-09): `platform-admins` stays the binding. Revisit only if a
  machine grant (`client_credentials`) is ever added to this client, since
  that would make wird-agent's membership a usable path into hq.
- The plaintext-password drift in Pigsty is unchanged: this entry adds a
  verifier, not a plaintext.

## Not decided here

- hq's token handling, session model and MCP tool surface. These are in hq's
  `docs/adr/0001-hq-dashboard.md`.
- A `vite dev` redirect. Per ADR-0050, a dev provider would be a separate
  provider, never this one.
