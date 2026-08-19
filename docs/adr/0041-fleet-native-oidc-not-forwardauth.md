# ADR-0041: `fleet.bnei.dev` moves to the Native OIDC tier

**Status:** Proposed
**Date:** 2026-08-19
**Amends:** [ADR-0039](0039-authentik-identity-layer.md) Decision 3 — which assigns
`fleet` and the e2e previews to the forwardAuth tier. The previews stay there;
`fleet` does not.
**Related:** [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (why `fleet`
is the one host still grey, and therefore the least protected), agent-fleet
issues #200 and #209

## Context

ADR-0039 Decision 3 assigns each host a tier by what the application can do:
native OIDC where the app can federate, forwardAuth where it cannot. `fleet` was
put in forwardAuth on the reasonable assumption that agent-fleet's `core` does
not speak OIDC — which was true, and is a statement about the code rather than
about what the code should be.

Two facts that were not in front of ADR-0039 change the answer.

**forwardAuth does not close the hole that matters most on this host.** A
Traefik middleware gates the ingress. It has no opinion about a caller that
never reaches the ingress — and agent-fleet#200 is exactly that: a worker pod
POSTs to `agent-fleet-core.agent-fleet.svc.cluster.local:8080` on the pod
network, behind nothing but a CSRF header, and reads or mutates the console's
API. Putting authentik in front of Traefik leaves that untouched and completed.
The pods on the other side of it hold repo write tokens and, through thot,
cluster RBAC.

**`fleet` is the host with the least perimeter and the most authority behind
it.** It is the only `*.bnei.dev` host still grey at Cloudflare (ADR-0038):
no WAF, no geo rules, origin lock off, origin IP public. It was also, until
now, gated by the single shared `apr1` credential whose hash is in
`k8s-cluster`'s git history — the same one on pgweb, Alertmanager and Proxmox.

ADR-0039's own rule points here once `core` can federate: *"forwardAuth is used
only where the application cannot federate. Where it can, OIDC is preferred."*
The premise changed; the rule did not.

## Decision

1. **`fleet.bnei.dev` moves from the forwardAuth tier to the Native OIDC tier.**
   `core` becomes an OIDC relying party against authentik: authorization-code
   flow with `state`, `nonce` and PKCE, a signed session cookie, and a required
   `platform-admins` group claim. The gate is inside the process, so it applies
   to every caller regardless of network position — which is the property
   forwardAuth structurally cannot have.

2. **The e2e preview hosts stay on forwardAuth**, with a `forward_domain`
   provider and `cookie_domain: bnei.dev`. They route to a session's own
   dev-server pod; there is no fleet code in that request path to terminate OIDC
   with, and the hostnames are minted at runtime by the provisioner, so
   `forward_single` cannot name them.

3. **`basic-admin-auth` stays on the console's IngressRoute**, in front of the
   OIDC gate, and is not retired by this ADR.

   Two reasons, and the second is the load-bearing one. It is the break-glass:
   ADR-0039 Decision 6 already records that a `ClientIP()` LAN route can bypass a
   *middleware* but cannot bypass an application's own OIDC redirect, which is
   why Grafana and ArgoCD keep local admins. `core` has no local admin to keep,
   so an authentik outage would otherwise mean no console at all — and the
   console is where a blocked session's permission decision gets answered.

   It also removes a deployment hazard that has nothing to do with security
   theory: `k8s/core.yaml` carries both the middleware reference and the image
   tag, ArgoCD auto-syncs it from `main`, and the release workflow bumps the tag
   in a *later* commit. Removing the middleware in the same change that adds the
   gate would serve the console unauthenticated, publicly, for the length of a
   six-component serial build.

4. **`core` does not read `X-authentik-*` headers**, now or after this lands. It
   verifies its own ID token instead. A component reachable on the pod network
   can forge any header, so trusting one converts an authorization gap into an
   impersonation one — strictly worse. This is why the tier assignment is not
   merely a matter of taste for this host.

## Consequences

- The forwardAuth tier's `cookie_domain: bnei.dev` scopes authentik's proxy
  session cookie to the whole zone, so it is sent to every host in it, including
  public ones. It is authentik's own cookie rather than a credential to those
  apps, but it is a real widening and is the price of covering hostnames that do
  not exist when the blueprint is written.
- Because agent-authored dev servers run on same-site siblings of the console
  (`<id>-e2e.bnei.dev` vs `fleet.bnei.dev`), `SameSite` is not a defence between
  them. `core`'s session cookie is therefore named `__Host-fleet_session`, which
  forbids a `Domain` attribute at the browser level and stops a preview page
  shadowing the console's cookie.
- Two authentication systems now sit in front of one host, which ADR-0039
  Decision 3 explicitly warns against. Accepted knowingly and bounded: the outer
  one is a break-glass with a named retirement condition (a second, independent
  path to the console — a local admin, or an authentik that is not deployed by
  the thing it gates), not an indefinite second gate.
- `core` gains a hard dependency on authentik → Pigsty → Patroni for every
  login. That chain is what Decision 3 above exists to mitigate.
- Adding the fleet does not change the propagation chain: merge → restart the
  Infisical operator if a CR template changed → restart the authentik worker so
  discovery re-applies → restart `core` if its own credentials changed. Skipping
  any of the four leaves everything looking healthy.

## Alternatives considered

- **Keep `fleet` on forwardAuth (ADR-0039 as written).** Rejected: leaves
  agent-fleet#200 entirely open, on the host with the most authority behind it,
  while looking solved.
- **forwardAuth *plus* a NetworkPolicy denying worker pods → core:8080.**
  Rejected as the whole answer. It constrains network topology rather than
  establishing caller identity, gives no attribution, and a policy that is
  written but not enforced looks identical to one that works. Still worth doing
  as a layer below this, tracked with ADR-0040's default-deny work.
- **Native OIDC for the previews too.** Not possible: no fleet code is in that
  request path.
- **Retire `basic-admin-auth` from the console in the same change.** Rejected —
  see Decision 3.
