# ADR-0054: Host a NetBird control plane for an external mesh — a hosting-only carve-out from ADR-0009

**Status:** Accepted — decided 2026-10-11, approved by M BN. Ships in three
PRs:
1. This ADR, the deploy, and the database.
2. The authentik client and its access policy.
3. Traefik's websecure timeouts, merged in a maintenance window.

**PR 1 live 2026-10-11** (#276, #277): server Ready, dashboard and Dex
served at `netbird.bnei.dev` with the `*.bnei.dev` certificate, all three
stores on Pigsty, STUN answering on the public IP through the Freebox UDP
forward. **PR 2 live 2026-10-11** (#280–#282): authentik is the only login,
the laptops and the Pi are peers. Still open: the Traefik timeout measurement
(PR 3).
**Amended 2026-10-11 by [ADR-0055](0055-netbird-as-daily-ssh-path.md):**
cluster hosts join the mesh as NetBird SSH peers. §1's first bullet no longer
holds; its second (no route or resource into the LAN) still does.
**Date:** 2026-10-11
**Related:**
- [ADR-0009](0009-reject-wireguard-tailscale.md): the rejection this narrows.
- [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md): grey records and the origin lock.
- [ADR-0039](0039-authentik-identity-layer.md): authentik as the identity layer.
- [ADR-0042](0042-pgbackrest-shared-repo-and-restore-command.md): backups.
- [ADR-0044](0044-stt-grpc-service.md): the Traefik timeout measurement and the grey-host middleware precedent.

## Context

A Raspberry Pi 4 sits at a partner's home and is administered over SSH from
two laptops (M BN's and N MG's). All three sit behind residential NATs, so
something has to broker the connections. NetBird does this: a WireGuard mesh
with a control plane (management, signal, relay, STUN) and per-peer access
policies.

Hosted NetBird was rejected because of its US dependencies: AWS hosting and
Auth0 login, per netbird.io/privacy. The self-hosted control plane needs a
public HTTPS endpoint, a public UDP port and a database, and this cluster
already has all three.

ADR-0009 rejected "Wireguard / Tailscale for this cluster". Its consequence
reads "No VPN mesh is layered onto `ukubi-cluster`": the question it answered
was *remote access to the cluster*. Hosting a coordination server that the
cluster itself never joins is a different proposition, and DECISION.md §3's
one-line "❌ Wireguard / Tailscale" was too broad to tell them apart. Hence
a fresh ADR, rather than reopening ADR-0009.

(ADR-0011 was suggested as the governing record. It is not one: it rejects
multi-region, DR, GPU multi-tenancy and service mesh, and says nothing about
VPNs.)

## Decision

### 1. Hosting only — ADR-0009 stands for everything else

The cluster may host the NetBird control plane. These stay forbidden, and
each would need its own ADR:
- ~~**No cluster node, pod, PVE host or LXC runs a NetBird client** or joins
  the mesh.~~ Superseded by ADR-0055: hosts are SSH peers. Pods still never are.
- **No NetBird route, network resource or exit node points into
  `192.168.1.0/24`** or any cluster CIDR.
- **Cluster remote access stays SSH/bastion**, exactly as ADR-0009 left it.
  *(Amended by ADR-0055: it is SSH over NetBird, with the bastion pattern kept
  for heavy runs and break-glass.)*

The mesh's peers are the two laptops and the Pi, and its one policy allows
`laptops → pi` on SSH. If a later request wants a cluster host in the mesh,
that is ADR-0009's question again, not this ADR's. *(It was asked:
[ADR-0055](0055-netbird-as-daily-ssh-path.md) answers it for SSH.)*

### 2. Shape: the combined `netbird-server`, two common-app-chart releases

- **Server.** `netbirdio/netbird-server` (v0.65+) runs management, signal,
  relay and STUN in one binary configured by one `config.yaml`. That replaces
  the old four-container layout, and coturn with it.
- **Two releases.** It and `netbirdio/dashboard` are two
  `platform-common-apps` releases in namespace `netbird`
  (`gitops/platform/values/netbird{,-dashboard}`). Pinned tags: `0.80.0` and
  `v2.94.0`.
- **Single replica, `Recreate`.** HA for management and signal is NetBird's
  commercial tier.
- **Config delivery.** `config.yaml` is assembled whole by
  `gitops/bootstrap/netbird-config-secret.yaml`, an InfisicalSecret template,
  hq's pattern, and mounted at the image's default path.

### 3. Exposure

| Endpoint | Path | Why |
|---|---|---|
| `netbird.bnei.dev` TCP 443 | Freebox → Traefik `.233` | Management and signal gRPC (h2c to the backend), relay WebSocket, `/api`, `/oauth2` (embedded Dex), dashboard |
| UDP 3478 | Freebox → MetalLB **`.235`** | STUN. It cannot go through Traefik or Cloudflare |

**Not exposed:**
- coturn's UDP 49152-65535 (only for clients older than v0.29).
- QUIC on UDP 443 (optional; clients fall back to WebSocket).

**The route is hand-written** in `values/netbird`'s `extraManifests`. The
chart's single route cannot send two gRPC prefixes as h2c. The dashboard
release owns the host's catch-all route, and Traefik's length-based priority
lets the server's longer `Host() && PathPrefix()` rules win. `/api`, `/oauth2`
and the dashboard carry the baseline rate limit and headers, the ADR-0044
grey-host precedent. The gRPC and relay streams carry no middleware.

**STUN's Service uses `externalTrafficPolicy: Local`.** Under `Cluster`,
kube-proxy SNATs to a node IP, and STUN would report that address as the
peer's. With one replica, MetalLB announces from the pod's node. The address
goes dark during each `Recreate` rollout, and peers use the relay meanwhile.

**`netbird.bnei.dev` is an explicit grey record** in ADR-0038's table:
- The STUN URI uses the same name, and Cloudflare's proxy carries no UDP.
- The dashboard release therefore turns `originLock` off and keys its limiter
  on the TCP peer (`sourceHeader: ""`), as ente-web does.

**Traefik's websecure `readTimeout` goes to 0** (PR 3). NetBird requires it
for signal and relay streams. ADR-0044 measured that the repo's v3 default of
60s is per-request, and a signal stream is one request lasting hours.
- **Cost:** weaker slowloris protection on every websecure host.
- **Rejected alternative:** a dedicated entrypoint, which needs a second
  Freebox forward.
- **Measure first:** hold a peer session past 60s on the current setting. If
  it survives, PR 3 is dropped.

### 4. Identity: embedded Dex brokers authentik, and authentik is the only login

The combined server ships an embedded Dex at `/oauth2`. NetBird's current
docs add authentik to it as a **Generic OIDC** upstream (confidential
client), not as a replacement. The "standalone" replacement exists only for
the legacy multi-container layout, with an authentik admin token for user
sync.

So:
- **Dex is the broker**, inside the server, with nothing US-hosted.
- **authentik is the only login** once `localAuthDisabled: true` is set.
- **Access is gated by a `netbird-users` group** bound in its own policy
  blueprint. Without a binding, `core_default_app_access false` denies
  everyone, and a binding is also what keeps public Wird self-enrollment off
  the mesh.

**One step is a click, recorded here as bootstrap state.** NetBird generates
the upstream's redirect URI when the provider is added in its dashboard, and
`config.yaml` cannot declare an external IdP. The order is:
1. PR 1 deploys with a local `owner` account. The owner is set in
   `config.yaml` so the first internet visitor to `/setup` cannot claim it.
2. The provider is added in the dashboard and the redirect URI is copied.
3. PR 2 commits the blueprint.
4. The first authentik login is verified.
5. `localAuthDisabled` is flipped.

**Done 2026-10-11.** authentik login worked, NetBird ownership moved to the
authentik-backed user, and `localAuthDisabled` was set.

**Break-glass, an argued deviation from ADR-0039 Decision 6.** That decision
keeps an app's local admin for when authentik is down. Here the local login
would be a password form on the internet. So it is off. The `owner` block stays
in `config.yaml`, and reverting that one line to `false` restores it with the
same password. Established tunnels keep running meanwhile (§7), so the cost of
an authentik outage is only that nobody can start a new session.

Group sync through Dex is unverified. NetBird groups (`laptops`, `pi`) are
assigned in NetBird until it is tested.

### 5. Peers and policy

- **Laptops:** SSO.
- **The Pi:** a one-off setup key, auto-group `pi`, short expiry. Enrolled
  with `--allow-server-ssh`.
- **Client version:** v0.61+ on all three (NetBird SSH).
- **Policy:** `Default` (All ↔ All) is deleted. The single policy is
  `laptops → pi`, NetBird SSH on 22 (redirected to 22022 on the Pi), with
  `laptops` mapped to the Pi's OS user. NetBird SSH fails closed when no
  mapping exists.

### 6. Store and backup

- **Databases.** All three stores are on Pigsty, owned by `dbuser_netbird`
  (hq's switches: `pgbouncer: false`, `revokeconn`):
  - `netbirddb`: management, holding peers, groups, policies and setup keys.
  - `netbirdeventsdb`: activity.
  - `netbirdidpdb`: Dex.
- **Backup** is therefore pgBackRest (ADR-0042) alone. The required
  `dataDir` is a 1Gi Longhorn PVC, but it holds only a cache: the GeoLite
  databases management downloads at boot. It started as an `emptyDir`, and
  the first deploy crashed once re-downloading them (a failed load is fatal),
  so it moved to a PVC. It needs no backup.
- **`server.store.encryptionKey`** (`NETBIRD_STORE_ENCRYPTION_KEY`) lives
  only in Infisical. Without it a restored `netbirddb` is unreadable. A
  restore also needs the same domain.

### 7. Availability, stated honestly

NetBird: "NetBird clients can tolerate a Management server outage as long as
connections are already established through relays or peer-to-peer"
(docs.netbird.io, *Scaling your self-hosted deployment*). Signal "steps out"
once a connection exists (*How NetBird works*).

The limits:
- **A relayed session dies with the cluster**, because the relay is in it.
- **New connections and NetBird SSH's JWT check need management and
  authentik up.**
- **Laptops re-authenticate when their login expires.** The Pi does not,
  because it uses a setup key.

So a cluster outage keeps an already-open P2P SSH session alive. It does not
let anyone open a new one.

## Consequences

- **DECISION.md §3.** The entry becomes "Wireguard / Tailscale **as cluster
  access**", linking here. ADR-0009 keeps its status and gains a pointer.
- **MetalLB.** `.235` is the third pinned address, after `.233` and `.234`.
- **A new kind of internet exposure: a UDP port.** It has no prior art on the
  Freebox, and the forward is M BN's to make.
- **Hairpin is unverified.** Pods resolve through Pi-hole, so the grey name
  gives them the public IP and relies on Freebox NAT loopback. If that fails,
  the fix is a Pi-hole override to `.233` for TCP, with STUN moved to a name
  without one.
- **A dashboard-held step** (the upstream IdP) breaks "everything declared in
  git" for this one app. It is recorded here instead of hidden.

## Alternatives considered

- **Hosted NetBird.** Rejected for its US dependencies (AWS, Auth0).
- **Headscale (open-source Tailscale control plane).** Not evaluated in
  depth. NetBird was the requester's choice, and nothing found here argued
  against it. Revisit only if NetBird's self-hosted path stalls.
- **Plain WireGuard with a Pi port-forward at the partner's home.** It needs
  a change on a router this operator does not control.
- **Legacy multi-container NetBird with authentik replacing Dex.** It is a
  deprecated layout and hands NetBird an authentik admin token.
