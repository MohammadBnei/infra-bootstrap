# ADR-0072: Self-hosted LiveKit for the shared world's voice: one UDP and one TCP port

**Status:** Proposed. Drafted 2026-11-11 for mountain plan/22 (voice, chat, parties and mail). It ships in infra PR B,
before the realm's voice phase (P4). M BN merges.
**Date:** 2026-11-11
**Related:**
- [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md): the Cloudflare proxy and the origin lock.
- [ADR-0054](0054-netbird-control-plane-hosting-only.md): the precedent for UDP on a MetalLB address through a Freebox forward.
- [ADR-0001](0001-ingress-traefik-ingressroute-over-gateway-api.md): no cert-manager, so no TLS listener outside Traefik.

## Context

The shared world (`ukubi-game`, the realm) gains proximity voice among about 20 players. They are friends mixed with
GitHub and Google sign-ins, which are approved automatically. The owner chose a self-hosted SFU, LiveKit, so voices
stay in-house and are never recorded.

WebRTC media needs UDP, or a TCP fallback, from the internet to the SFU. The Cloudflare proxy carries no UDP, and
Traefik has no UDP entrypoint. Today's only UDP exposure is NetBird's STUN on 3478 to `.235` (ADR-0054). ADR-0054 left
coturn's relay range unexposed on purpose.

## Decision

1. **LiveKit runs as a registry app.** One replica, `Recreate`, no Redis. The common-app-chart renders it. Its config
   file comes from an InfisicalSecret template (the NetBird precedent).
2. **Signalling** is `wss://voice.bnei.dev` through Traefik websecure, behind the Cloudflare proxy. The IngressRoute
   matches **only `PathPrefix(/rtc)`** (plus any path the client SDK provably needs). LiveKit's Twirp admin API on the
   same port 7880 is never routed; the realm reaches it inside the cluster.
3. **Media** goes to one MetalLB address, `192.168.1.236`, with `externalTrafficPolicy: Local`:
   - **UDP 7882** (single-port mux),
   - **TCP 7881** (the ICE-TCP fallback).

   M BN adds two Freebox forwards to `.236`. There is no port range, and no TURN.
4. **No TURN/TLS.** It would need a certificate outside Traefik (ADR-0001 bans cert-manager) and a second public 443
   path. Players on networks that block both UDP and TCP 7881 get no voice. That is accepted.
5. **Fence:**
   - Ingress: Traefik on 7880; the world on 7881/tcp and 7882/udp; `ukubi-realm` on 7880.
   - Egress: the world on UDP (LiveKit runs its own connectivity checks) and DNS.
   - `ukubi-realm` gains egress to `livekit:7880`.
6. **Secrets:** `LIVEKIT_KEY` and `LIVEKIT_SECRET`, in the LiveKit config and in the realm's Secret
   (`UKUBI_REALM_LIVEKIT_KEY` / `_SECRET`).

## Consequences

- **Wider exposure.** Two more ports face the internet on the public IP.
- **ICE reveals the origin.** The origin's WAN IP (`82.65.231.50`) is handed to every client as an ICE candidate, the
  address the ADR-0038 origin lock otherwise hides. NetBird's STUN already reveals it. Voice makes it visible to every
  player.
- **Home players are untested.** Whether the Freebox hairpins UDP is unverified (ADR-0054). Plan/22's spike S2
  tests it. The fallback is a LAN candidate, or a split-horizon `voice.bnei.lan`.
- **Outages.** One replica with `externalTrafficPolicy: Local` means voice drops on each rollout and node move. Chat
  and the game go on.
- **Enforcement lives in the realm.** It does not live in LiveKit: self-hosted LiveKit cannot revoke tokens or move
  participants. Plan/22 §2 records the publisher-permission design.

## Alternatives considered

- **coturn or LiveKit TURN with a port range:** a far larger exposure. ADR-0054 already declined it.
- **A Cloudflare tunnel:** it carries no UDP and was rejected in ADR-0038.
- **A hosted SFU (LiveKit Cloud and others):** voices would leave the house. The owner refused.
- **No voice (plan/19's old row):** reversed by the owner for plan/22.
