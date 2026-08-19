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

   > **Superseded 2026-08-19, hours later, by the operator's decision.** The
   > middleware is removed from the console; `fleet.bnei.dev` is gated by core's
   > OIDC alone. The reasoning below still stands on its own terms and is left
   > intact — what changed is the weighting, not the analysis. Consequences of
   > the reversal are recorded at the end of this ADR under *Amendment: dropping
   > the outer layer*.

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


## Amendment: dropping the outer layer (2026-08-19)

Decision 3 above is reversed. `basic-admin-auth` is removed from the console's
IngressRoute; core's own OIDC gate is the only thing in front of
`fleet.bnei.dev`.

One of the two original reasons had already expired by then: the deploy-window
hazard existed only while `k8s/core.yaml` could carry a middleware removal and a
pre-OIDC image tag at once, and the OIDC image was confirmed live at 4.6.2
first. The break-glass argument did not expire — it was overruled, deliberately,
in favour of a single sign-on.

**What is accepted by this.**

An authentik outage now means no console at all, and authentik depends on Pigsty
→ Patroni, so that chain sits under every login. There is no local admin to fall
back to, because core has none to keep — which is precisely the asymmetry
ADR-0039 Decision 6 named when it kept local admins on Grafana and ArgoCD.
Recovery is `FLEET_AUTH_DISABLED=1` plus a redeploy, or `kubectl port-forward`;
both need cluster access and neither is fast.

This is not hypothetical. Hours before the reversal, a trailing-slash bug in
core's issuer handling crash-looped it, and `basic-admin-auth` was the only
reason the window read as *console unreachable* rather than *console open*. That
protection is now gone. The fail-closed startup behaviour is unchanged and still
correct, but it now fails closed with nothing behind it.

**What is NOT weakened**, and was worth checking rather than assuming: the
console's IngressRoute matches on host with no path constraint, so removing the
middleware exposes every path core serves on 8080 that the in-app gate exempts.
That set is `/healthz`, `/auth/*`, and `/webhook/alertmanager`. The first two are
inert. The third carries its own bearer token and refuses every request when the
token is unset, so it is guarded — but it is now reachable from the internet on a
host that is still grey at Cloudflare, where it previously sat behind basic auth
as well. `/metrics` is deliberately **not** in the exempt set and stays gated.

**Retiring the credential itself is a separate job.** The same `apr1` hash still
gates pgweb, Alertmanager and Proxmox, and it is still in `k8s-cluster`'s git
history. Dropping the fleet's use of it removes the operator's daily reason to
type it, which makes it *more* likely to rot unrotated, not less. Tracked with
the rest of the forwardAuth tier.