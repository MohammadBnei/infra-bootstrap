# ADR-0051: Expose the Hermes Agent dashboard at `hermes.bnei.dev` — two gates, not one

**Status:** Accepted — decided 2026-10-02. The authentik behaviour reused here is
the same shape ADR-0050 verified against goauthentik 2026.8 source; the Hermes
dashboard behaviour below was verified against upstream's own documentation for
`plugins/dashboard_auth/self_hosted`, not against a running instance, so the
step-0 probes in `ansible/playbooks/hermes-dashboard-configure.yml` are part of
the decision, not optional polish.
**Date:** 2026-10-02
**Related:** [ADR-0039](0039-authentik-identity-layer.md) (identity layer and its
four tiers — this adds an app to the Native OIDC tier *and* to forwardAuth, which
no other app does), [ADR-0050](0050-public-oidc-client-for-native-apps.md) (public
clients + PKCE by policy — same mechanics, different justification),
[ADR-0030](0030-expose-garage-s3-externally.md) (the redirector precedent for an
off-cluster host), [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (proxied
wildcard + origin lock)

## Context

LXC 101 `hermesagent` (VMID 101 on `ex-laptop`, imported at
`terraform/imported.tf:251`) runs NousResearch's Hermes Agent. Its web dashboard
— config editor, API-key manager, session browser, logs, analytics, cron, skills,
MCP, channels, and a **real PTY** on the Chat tab — listens on `127.0.0.1:9119`
and has only ever been reachable through an SSH tunnel. The operator wants it at
`https://hermes.bnei.dev`, behind authentik, the way `proxmox.bnei.dev` is
already fronted by Traefik.

**What is behind that login is not a dashboard.** Per
`docs/infrastructure-actual.md` §9, LXC 101 holds a Proxmox API token with role
`PVEVMAdmin`, SSH access to two of the three hypervisors, `~/.ssh/id_k8s_vm` for
every Kubernetes node, a GitHub token, and — per
`docs/runbook-k9s-ops-hub.md` — the Infisical machine identity.
`DECISION.md` §2 names this box as where "operations live". A session on this
dashboard is therefore an interactive shell holding hypervisor admin, cluster
node keys and the secret-store identity. That is strictly more dangerous than
`proxmox.bnei.dev`, which is only a login form, and ADR-0039 assigned *that* host
to forwardAuth plus the origin lock.

Two upstream properties shape everything else:

1. **The dashboard's auth gate is not satisfiable by a proxy.** Any non-loopback
   bind — and any non-loopback `public_url` — makes it refuse to start until an
   auth provider is configured. A reverse proxy in front does not count.
2. **`GET /api/status` is public by design.** It answers before any credential
   check with version, gateway state, every connected messaging channel, active
   session count, memory/swap/disk pressure and `last_boot_suspected_oom`.

## Decision

1. **Native OIDC *and* forwardAuth. Two independent gates.** The dashboard
   authenticates against authentik itself (satisfying property 1), and
   `gitops/redirectors/hermes.yaml` *also* attaches the existing
   `authentik-forwardauth` middleware. The first draft of this work rejected
   forwardAuth, on the grounds that it would force the bundled username/password
   provider as well — true only if forwardAuth *replaced* native OIDC. As an
   addition it needs no password, no second prompt (the user already holds the
   authentik SSO cookie) and no new authentik object: the forwardAuth tier's
   provider is `mode: forward_domain` with `cookie_domain: bnei.dev`, so it
   covers any `*.bnei.dev` host, and `authentik-blueprint-previews-policy.yaml`
   already restricts that application to `platform-admins`. It also closes
   property 2, which a single-gate design would have published to the internet.
2. **`platform-admins`, enforced in authentik, because Hermes has no roles.**
   ArgoCD falls through to `role:readonly` and Grafana to `Viewer`; Hermes has no
   equivalent, so the `policybinding` in
   `gitops/bootstrap/authentik-blueprint-hermes-policy.yaml` is the entire
   authorization decision. That is why gate 2 exists at all — the compound
   failure the policy file itself documents (a `!Find` miss writing
   `group_id = NULL`, plus a lost `core_default_app_access` flag, plus Wird's
   open enrollment) would otherwise hand a PTY to a self-registered stranger.
3. **Public client, for a reason that is NOT ADR-0050's.** ADR-0050 made public
   clients an exception with a stated test: a secret shipped in an IPA, an APK or
   a JS bundle is extractable. A FastAPI server reading `config.yaml` at mode
   0600 fails that test — it *can* keep a secret. It is public only because
   upstream's plugin refuses confidential clients outright. This is a new,
   narrower precedent: *public client as an upstream gap*, with none of ADR-0050
   Decision 2's compensating control (App Links / Universal Links domain
   verification is meaningless for a server). The compensating controls here are
   a single strict HTTPS redirect URI, PKCE S256 enforced by an authentik
   expression policy, the group binding, forwardAuth, and the origin lock.
4. **PKCE enforced by its own policy object, `hermes-require-pkce`, declared in
   `authentik-blueprint-hermes-policy.yaml` — hermes' own policy file, not the
   shared `platform-apps` one — and bound with `!KeyOf`.** The separate file is
   not tidiness: a blueprint applies as a single transaction and
   `PolicyBinding.target` is a required FK, so a `!Find` miss on a
   not-yet-registered `hermes` is a validation error that rolls the whole file
   back. Sharing the file would let that take argocd's and grafana's bindings
   down too, which with `core_default_app_access: false` locks the operator out
   of both. Not a `!Find` reference to
   `wird-require-pkce`, even though the expression is identical and app-agnostic:
   `!Find` returns `None` rather than failing, which writes a row with
   `policy_id = NULL` that `PolicyEngine.build()` drops — PKCE silently
   unenforced, nothing logged, and alphabetical blueprint ordering makes a cold
   rebuild the likely trigger.
5. **Auth configuration lives in a systemd drop-in, as environment variables.**
   The dashboard's own Config page can rewrite `config.yaml` (Save / Reset to
   defaults / Import), so anyone who logs in could delete `dashboard.oauth` and
   fail the next start closed. Env wins over `config.yaml` and the UI cannot
   write env. `trusted_proxies` is the exception — it has no env override
   upstream — and it is the one setting whose loss breaks login rather than
   locking the box.
6. **Break-glass is the hypervisor console, not a local password provider.**
   ADR-0039 Decision 6 calls break-glass "not optional", and its Decision 5 (the
   LAN `ClientIP()` bypass) is still unbuilt. A shared password on this box would
   be a second credential to a PTY holding hypervisor keys, so instead:
   `pct enter 101`, remove the two drop-ins, `daemon-reload`, restart. Because
   every OIDC setting lives in those drop-ins, that one step reverts the box to a
   loopback bind with the gate off and the SSH tunnel working, with authentik out
   of the path entirely. This is an argued deviation from Decision 6, not an
   oversight: the recovery path exists, it just requires physical/hypervisor
   access rather than a password.
7. **`0.0.0.0` bind plus an `nftables` allow-list — which narrows the exposure
   but does not reduce it to Traefik.** The bind is forced by Hermes' peer-IP
   guard (a loopback bind rejects Traefik at the socket layer). The rule takes
   `:9119` from "every device on `192.168.1.0/24`" down to "the five k8s node
   addresses", installed *before* the bind flips, scoped to tcp/9119 with
   `policy accept` so nothing else on the box is touched.

   **What it does not buy, stated plainly.** Cilium masquerades pod egress to the
   LAN as the node address — measured 2026-10-02 with tcpdump inside the container
   while a pod on `k8s-worker-02` curled it, and the SYN arrived from
   `192.168.1.203`. A packet filter therefore cannot tell Traefik's pod from any
   other pod, so allowing the node addresses is equivalent to allowing **every pod
   in every namespace**, plus any node-local process. Those callers reach the
   dashboard directly, skipping Traefik and so skipping gate 2 and the origin
   lock: they face gate 1 alone, they can read the unauthenticated `/api/status`,
   and they can set `X-Forwarded-*` headers that `trusted_proxies` will believe.
   Internet traffic still crosses both gates — this is a cluster-internal and
   node-local hole, accepted rather than closed because every fix requires
   something only Traefik can present (a secret header injected by a Traefik
   `Middleware`, or mTLS on the upstream hop) and Hermes can require neither, so
   each means another process on the box. Upgrade path if this stops being
   acceptable: terminate the upstream hop in a small reverse proxy on the LXC that
   demands that header or client certificate, and keep Hermes on loopback behind
   it. An earlier draft of this ADR claimed the rule kept pods out; it does not.
8. **Two-phase rollout, each phase with a rescue.** Phase A configures OIDC while
   still bound to loopback — `public_url` alone engages the gate, so a wrong
   issuer or client_id surfaces as an `/api/status` response rather than as an
   unreachable box. Phase B firewalls, then binds. A failure in either phase
   removes the drop-in it just wrote, restarts, and fails with the journal.
9. **MFA deferred, with a trigger.** `ARCHITECTURE.md`'s Critical tier (a WebAuthn
   policy) is not built, and ADR-0039 wants two devices enrolled before it is
   enforced. Shipping without it is an accepted risk; the trigger is explicit —
   enroll two passkeys, then bind a WebAuthn policy to `hermes` **and**
   `proxmox` together, since both are hypervisor-adjacent.

## Implementation note, 2026-10-02

Two things the plan had as "probably fine" turned out to be the real work:

- **The installed Hermes could not do this at all.** LXC 101 was on `0.15.1`
  (2026.5.29), whose only dashboard-auth plugin is `nous` — no `self_hosted`, no
  `basic`, and no `HERMES_DASHBOARD_OIDC` anywhere in its source. Upstream added
  `plugins/dashboard_auth/self_hosted` on 2026-06-04; it ships in `v2026.9.24`.
  So Decision 1's native gate was unconfigurable until the box was updated, and
  on 0.15.1 there was *no* self-hostable gate of any kind. `hermes update` also
  failed silently the first time (`✗ Failed to fetch updates from origin`,
  exit 0) on stale remote refs — `git remote prune origin` in
  `~/.hermes/hermes-agent` cleared it. The box is now on `0.21.5 (2026.9.24)`,
  `config_version` migrated 26 → 49, with the dashboard and the user-level
  `hermes-gateway.service` (`Linger=yes`, so it survives the reboot the static
  IP needed) both back up. `plugins/dashboard_auth/` now carries `basic`,
  `drain`, `nous` and `self_hosted` where it had only `nous`.
- **Expect to restart the authentik worker twice after the first sync.** The
  mounted blueprint directory sorts `authentik-blueprint-hermes-policy` *before*
  `authentik-blueprint-hermes` (`-` < `/`), so a discovery pass can apply the
  policy file while the application does not exist yet. `PolicyBinding.target` is
  a required FK and a blueprint applies as one transaction, so that file rolls back
  whole. It fails closed — no binding, and `core_default_app_access: false` denies
  — and self-heals on the next pass, which is the second restart.
- **`:8642` was already bound `0.0.0.0`.** The OpenAI-compatible API server,
  keyed from `/home/hermes/.hermes/.env`, has been LAN-reachable independently of
  this work. It is out of scope here and was left alone, but the `nftables` rule
  this ADR adds covers only `:9119` — so that endpoint is still open to the LAN.
  Worth its own decision.

## Consequences

- `hermes.bnei.dev` needs no DNS change: `*.bnei.dev` is a proxied Cloudflare
  wildcard. The route is one new file in `gitops/redirectors/`, picked up by
  `redirectors-application.yaml` with nothing to add to `registry.yaml`.
- **The container's NIC is now static, and the address is not what the docs
  said.** Recon on 2026-10-02 found LXC 101 on `192.168.1.72` with eight hours
  left on its DHCP lease — not the `192.168.1.181` recorded in
  `docs/infrastructure-actual.md`, `bin/install-requirements.sh` and
  `docs/runbook-k9s-ops-hub.md` (that address is free and unanswered). It was
  pinned with `pct set 101 -net0 …,ip=192.168.1.72/24,gw=192.168.1.254` rather
  than left to the lease, because the redirector points at a literal IP and a
  renewal would have produced a 502 with nothing in git changing. The static
  value is **not** declared in `terraform/imported.tf`: that resource already
  lists `initialization[0].ip_config` in `ignore_changes`, so a declaration there
  would read as enforced while changing nothing — its comment records the live
  value instead. **`.72` came out of the DHCP pool** — recon found the container
  holding it on a live lease — so a static pin without a matching Freebox
  reservation is a duplicate address waiting to happen: the Freebox can hand `.72`
  to another device while the LXC is off, and the playbook's `hermes_expected_ip`
  assert would still pass while traffic went elsewhere. Reserving it is a required
  step, and the one part of this change that needs LAN-side access.
- **Cloudflare's Browser Integrity Check does not block the plugin — measured,
  not assumed.** From inside LXC 101 on 2026-10-02: `urllib` → **403**, `curl` →
  200, `httpx` → 200. The plugin uses `httpx`, and
  `plugins/dashboard_auth/_shared.py` sets an explicit
  `User-Agent: HermesAgent/1.0` on its JWKS client with the comment that "some
  WAFs block the library default" — upstream had already met this. The playbook's
  probe is therefore httpx, the client that matters; a urllib probe would fail
  here forever and prove nothing. If httpx ever starts getting 403, the remedy is
  a Pi-hole split-horizon entry for `authentik.bnei.dev` → `192.168.1.233` (the
  mechanism `pihole-configure.yml` already uses for `stt.bnei.dev`, and the
  blocker ADR-0039 Decision 5 waits on) or a Cloudflare WAF exception.
- **Grey-clouding is the likely end state, not an edge case.** `fleet.bnei.dev`
  is already DNS-only because of Cloudflare's 100s timeout versus streaming. The
  Chat tab is a WebSocket PTY; it sends a 20s keepalive and silently reattaches
  after a drop, so a drop is easy to miss and must be checked at the `/api/ws`
  close code rather than by watching the terminal. If `hermes.bnei.dev` goes
  grey, `cloudflare-origin-lock` **must** be removed from the route in the same
  commit — it 403s every non-Cloudflare source. Both authentik gates are
  unaffected either way, which is most of why Decision 1 is worth its one extra
  line.
- **Logout is cosmetic.** Hermes clears its cookies and revokes the token, but
  the authentik session survives and the authorization flow is
  implicit-consent — so logging out and back in is instant and silent. On a box
  with a PTY, treat "log out" as "closed the tab".
- **The group has one member, and it is circular.** `platform-admins` contains
  only `akadmin`, which is also the account that can edit the binding gating it.
  Negative testing needs a throwaway non-member account. Widening the group is
  the natural next step and it is also the moment Decision 9's trigger matters.
- **Any cluster workload, and any node-local process, can reach `:9119`
  directly with gate 1 as its only check.** See Decision 7: that is the
  firewall's measured limit, not a misconfiguration.
- **Shrinking the blast radius is a separate change.** Moving the Proxmox token,
  the k8s node key and the Infisical identity off this box would materially
  reduce what one login buys. Out of scope here; worth its own issue.
