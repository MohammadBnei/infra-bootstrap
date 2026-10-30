# ADR-0068: atlas admits one machine principal, `atlas-game`, for the game's town

**Status:** Proposed. Decided 2026-10-25 by M BN in mountain's R12 design (`plan/13-game-town.md` §1: "the client
reads atlas through a server-side machine credential, an authentik service account `atlas-game` declared as a
blueprint in infra-bootstrap"). Amends [ADR-0067](0067-mountain-atlas-platform-admins-only.md) for two read routes.
Reuses [ADR-0066](0066-bridge-clients-sign-in-through-authentik.md)'s shape and delivers that ADR's reserved
username prefixes and username-change setting (its rollout step 2, in part).
**Date:** 2026-10-26
**Related:** mountain `cmd/atlas/machine.go`, `plan/10-understanding.md` Security; ukubi-game (the town page and its
server); [ADR-0039](0039-authentik-oidc-sso.md) (authentik tiers).

## Context

atlas (mountain.bnei.dev) admits `platform-admins` only, through two locks: the `mountain-gate` forwardAuth in front
and atlas's own OIDC session check on every route but `/healthz` and `/auth/*` (ADR-0067).

The game (ukubi-game) draws atlas's graph and live state as a town. Its server reads two of atlas's routes:
- `GET /api/graph`: the graph;
- `GET /ws`: the live frames.

Today it reads them from a local `atlas --dev` on loopback. To leave loopback it needs an identity atlas can check.
- A person's session would not do: it lasts an hour, it is a browser cookie, and it would make the game act as that
  person.
- A shared static token would do worse: atlas would hold the secret, it would never expire, and authentik could not
  revoke it.

## Decision

1. **One OAuth2 provider and application, `atlas-api`.** Its fields are ADR-0066's, fixed here:
   - `grant_types: [client_credentials]`, with no redirect URI;
   - RS256 on the shared `authentik Self-signed Certificate`;
   - `access_token_validity: minutes=10`, `sub_mode: user_username`, `issuer_mode: per_provider`;
   - `client_id: atlas-api`, a literal: it is the token's `aud` and `azp`, and nothing secret;
   - no client secret rendered, and no federation.

   authentik generates a client secret on create and nothing reads it. A grant made with it would mint an
   `ak-…-client_credentials` account, which atlas refuses because the `sub` is wrong.
2. **One service account, `atlas-game`** (`type: service_account`), with an app password and its own policy binding to
   `atlas-api`.
   - The provider, application, account, app password and binding are **one blueprint**: they apply, or roll back,
     as one transaction (`gitops/bootstrap/authentik-blueprint-atlas-api.yaml`, an InfisicalSecret, since the app
     password is in it).
   - The app password is `ATLAS_GAME_APP_PASSWORD` in `infra-bootstrap-1-ge1`, and it has two consumers: authentik
     and the game's server. That is the `NETBIRD_AGENT_APP_PASSWORD` arrangement, not `platform-commons` (ADR-0049).
3. **What atlas checks** (mountain `cmd/atlas/machine.go`), offline, as the bridge checks its clients:
   - **The signature.** RS256 only, decided before any key is used. `kid`, `jku`, `x5u`, `x5c` and `jwk` are never
     read. The key is **the pinned certificate** (`MOUNTAIN_MACHINE_CERT`, PEM, one or more during a rotation), never
     a JWKS fetched over the pod network.
   - **The claims.**
     - `iss` is the provider's public issuer, `https://authentik.bnei.dev/application/o/atlas-api/`.
     - `aud` holds `atlas-api` and `azp` is `atlas-api`.
     - `sub` is `atlas-game`. The signing key is shared by every provider, so these checks are what make a token this
       one's.
     - `exp` gets no leeway and must have at least 5 s left. `nbf` and `iat` get one minute.
   - **The routes.** Only `GET /api/graph` and `GET /ws` admit the token. Every other gated route answers it with
     401. `/api/read` and the page are among them.
   - **A request carrying `Authorization` is judged by that header alone**, never by a cookie as well. A bad token
     is a 401 with `WWW-Authenticate: Bearer`. The token goes in the header only, never in the query.
   - **The socket.** It needs no browser `Origin`, since no cookie rides it. It ends at the token's `exp`, so
     deactivating `atlas-game` takes effect within 10 minutes. Revoking one token has no effect, because atlas
     validates offline.
   - **Configuration.** The four `MOUNTAIN_MACHINE_*` values are all set or none. With none set the path is off;
     with only some set, atlas refuses to start.
4. **How the game runs the grant.**
   - It sends username `atlas-game`, the app password and `client_id=atlas-api`, with no client secret.
   - It sends them to authentik's in-cluster Service (`platform-authentik-server.authentik.svc`) with
     `Host: authentik.bnei.dev` and `X-Forwarded-Proto: https`. authentik builds `iss` from the request host, so
     the token carries the public issuer without depending on Cloudflare.
   - It reaches atlas by atlas's in-cluster Service. `mountain.bnei.dev`'s forwardAuth stops a machine at Traefik,
     and stays as it is.
   - The token never reaches the game's page.
5. **The account names are protected.** A blueprint matches its service account on the username, so an enrolled
   `atlas-game` would be taken over and handed the binding.
   - `atlas-`, `bridge-`, `netbird-` and `ak-` are reserved prefixes:
     - in `mountain-handle`;
     - in a new `wird-username` policy on wird's public enrollment, which had no username rule.
   - Users cannot change their own username. authentik's tenant setting `default_user_change_username` is declared
     false by the `authentik-set-flags` PostSync Job. It is a tenant field, which no blueprint can target. This is
     ADR-0066's "declared, not clicked".
   - Why a username and not `hashed_user_id` as `sub`: atlas pins `sub` in its config, and a hashed id exists only
     after the first apply, so pinning it would add a hand-copied step to every rebuild. A username is only as good as
     its protection, which is the three measures above plus the `atlas-api` provider issuing `client_credentials`
     only (no browser login can reach it).
6. **Accepted risk: plaintext on the pod network.**
   - The app password crosses the pod network in clear to authentik's Service, as ADR-0066's clients' passwords do.
   - The 10-minute token crosses it in clear to atlas's Service. atlas's namespace has no NetworkPolicy yet.
   - A pod that can sniff that traffic can read the town for 10 minutes, or mint tokens until the password is
     rotated. It can read nothing else, and write nothing: the two routes are read-only.
   - What it cannot do is forge a token. The certificate pin is what stops a spoofed key.

## Consequences

- **The town depends on authentik.** A game with a valid token keeps reading for up to 10 minutes of an outage. After
  that it stops, says so, and retries. atlas's own admins are unaffected for as long as their sessions last.
- **One app password to rotate:**
  1. set a new value in Infisical;
  2. the operator re-renders the blueprint and authentik reapplies it;
  3. restart the game.
- **A signing-key rotation touches atlas's config:** add the new certificate to `MOUNTAIN_MACHINE_CERT`, then remove
  the old one. The bridge's `BRIDGE_OIDC_CERT` moves at the same time.
- **atlas's audience is no longer people only.** ADR-0067's "platform-admins only" stays true for every person, and for
  every route but these two reads.

## Rollout

1. This ADR.
2. **Before merging the blueprint:**
   - `ATLAS_GAME_APP_PASSWORD` exists in Infisical (a random 48 bytes, urlsafe). A missing key leaves the Secret
     unrendered, and the authentik worker mounts every listed blueprint Secret.
   - No user named `atlas-game` exists: `ak shell -c "from authentik.core.models import User; print(User.objects.filter(username__startswith='atlas-').values_list('username', flat=True))"`
     prints an empty list.
3. **Merge:** the blueprint, the reserved prefixes, and the username setting.
4. **After the apply:**
   - The blueprint shows `successful` in the authentik admin.
   - There is exactly one `atlas-game` user, with one app-password token and one binding on `atlas-api`.
   - The Job logs `default_user_change_username: False`.
   - A grant, run from a pod with the headers above, returns a token. Decoded, it shows the public `iss`,
     `aud`/`azp` `atlas-api`, `sub` `atlas-game` and RS256.
   - No token is ever printed into a log.
5. **mountain:** atlas's machine path, merged off. The `MOUNTAIN_MACHINE_*` values are set in its Helm values only
   when the game is deployed.
6. **ukubi-game:** the token client. Deploying the game (its image, app entry, hostname and own sign-in) is its own
   change, with its own decision on the hostname and gate.

## Amendment (2026-10): the machine routes add `GET /api/read` and `GET /api/tree`

Decided in mountain's world/d3-reads (the game's rooms and reader). Amends Decision 1's route list and §6's accepted
risk. Nothing else in this ADR changes: the principal, the token, the pin and the rollback are as above.

1. **Two more machine routes, both read-only.**
   - `GET /api/tree`: the file names of a held repo.
   - `GET /api/read`: one file, as the **redacted render** (the same text atlas shows an admin, not the raw bytes).
   - The machine path still serves `GET /api/graph`, `GET /ws` and these two, and nothing else. The mountain PR for
     the routes is world/d3-reads.
2. **Restated accepted risk (§6).** A sniffed token now reads every held repo's source, private ones included, for up
   to 10 minutes. Before this amendment it read the town graph only. It still writes nothing, and it still cannot
   forge a token.
3. **Where the game uses them.** Files and code are served only on the game's owner routes.
   - Rooms for a non-public repo cross to the public pod as counts only; public-fields.txt pins this.
   - A public repo's file names may cross; file contents never do.
4. **Follow-up: a NetworkPolicy for the atlas namespace.** §6 notes it has none, and the routes above raise what the
   gap exposes. A policy that admits only Traefik, the game and the monitoring scrape closes it. It is not part of
   this amendment, and the risk in 2 stands until it lands.
