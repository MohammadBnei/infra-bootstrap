# ADR-0044: `ukubi-stt` — a GPU speech-to-text gRPC service

**Status:** Proposed
**Date:** 2026-08-31
**Related:** [ADR-0043](0043-gpu-node-enablement.md) (the GPU this runs on),
[ADR-0011](0011-reject-multi-region-dr-service-mesh.md) (GPU multi-tenancy
rejected), [ADR-0038](0038-cloudflare-proxy-dns01-and-origin-lock.md) (the
proxied wildcard this hostname opts out of), [ADR-0039](0039-authentik-identity-layer.md)
(the identity layer this deliberately does *not* use),
[ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (where the image
is built and stored), [ADR-0037](0037-worker-cpu-capacity-vs-agent-fleet-burst.md)
(the node capacity this consumes)

## Context

A general-purpose, locally-running speech-to-text service: Rust, gRPC,
GPU-accelerated. Not embedded in one app — a service other things call.

Owner-set constraints, recorded so they are not re-litigated:

- **Callers:** browsers plus the owner's own machines, over LAN and WAN. Not
  anonymous public, but reachable from the internet.
- **Modes:** streaming realtime *and* batch files.
- **Availability is explicitly not a goal.** Single replica, node-pinned to
  `k8s-worker-01`, no HA, no CPU fallback, no queue. `.165` reboots for gaming
  and the service goes with it. This is a decision, not an oversight.
- **New standalone repo** `MohammadBnei/ukubi-stt`, not a directory in this one.
- Grey-cloud hostname, shared bearer token.

ADR-0043 made the GPU schedulable: one RTX 2070 SUPER (8GB, Turing CC 7.5, FP16
tensor cores, no BF16), reachable only by a pod that asks for
`runtimeClassName: nvidia` *and* `nvidia.com/gpu: 1`.

## Decision

### 1. Engine: `parakeet-rs` with the `cuda` feature, behind a hard gate

`parakeet-rs` (`features = ["cuda"]`, backed by `ort`), running Parakeet TDT
0.6B. Chosen over `sherpa-onnx`, which was the obvious pick until its source was
read: `sherpa-onnx-sys`'s `build.rs` contains **zero occurrences of `cuda` or
`gpu`** and only ever downloads the CPU tarball. Its `provider: Some("cuda")`
compiles, links a CPU-only ONNX Runtime, logs a warning, and runs on CPU. The
GPU asset exists in the same upstream release and the crate never references
it. Using it on a GPU would have meant hand-fetching that tarball plus
`SHERPA_ONNX_LIB_DIR` — a build hack — to obtain what `parakeet-rs` gives
behind a feature flag.

Two caveats accepted rather than hidden:

- `ort` is a **release candidate**. Pin it exactly, never with `^`.
- `parakeet-rs` **auto-falls back to CPU if CUDA initialisation fails.** This is
  the single most dangerous property in the stack, and it is why Decision 3
  exists.

**This decision is gated, not assumed.** Before anything else is built: an
image with the `cuda` feature runs on `k8s-worker-01` and must show a non-zero
GPU memory delta and a real-time factor consistent with GPU decode. A zero
delta means CUDA silently fell back, and the engine changes to Whisper via
`ort` (same backend, same CUDA story, ~99 languages, offline-only) or
`whisper-rs`. Everything downstream survives that swap; **the streaming proto
does not**, which is why the gate comes first.

Language coverage is 25 European languages, not Whisper's ~99. Accepted. See
Consequences for what that defers.

### 2. gRPC, with gRPC-Web conversion at the edge — not `tonic-web`

`tonic` + `prost` + `tokio`, `:9090` gRPC, `:8080` HTTP health.

Browsers **cannot** do gRPC client-streaming or bidirectional streaming.
gRPC-Web and Connect offer unary and server-streaming only; `duplex: 'full'`
fetch ships in no stable browser as of early 2026. So Phase 1 is **chunked
unary** — utterance-level latency, no partials, one transport, one auth path.

WebSocket is the 2026 industry default for realtime STT and is the likely
eventual answer, but it costs a second listener, a second auth path (browsers
cannot set headers on a WS handshake), a second rate-limit surface, and its own
timeout exposure. That is a decision to make **with real usage data**, not
upfront.

The gRPC-Web translation is Traefik's `grpcWeb` middleware, not the `tonic-web`
crate — the edge already terminates TLS and routes; doing it twice is one more
thing to keep in sync.

### 3. Assert CUDA engaged at startup, and crash if it did not

Sample GPU memory before and after model load plus a warmup decode, require a
delta, exit non-zero otherwise.

This cannot be a build-time check: `terraform/build-runner.tf` pins the
build-runner LXC to `server1`, which has no GPU, and PCI passthrough is
exclusive by construction so it cannot be moved to `.165`.

A `CrashLoopBackOff` is loud and attributable. A ready pod quietly decoding at
30× realtime on CPU is the failure this service is most likely to suffer, and
the one least likely to be noticed. Downtime is already accepted (Context), so
crashing costs nothing that was promised.

`--selftest` stays as a manual flag runnable on the GPU node, not a gate.

### 4. One decode at a time, and a different model for streaming

Phase 1: one recognizer behind a mutex and a `Semaphore(1)`, via
`spawn_blocking`; excess callers get `RESOURCE_EXHAUSTED`. One 8GB GPU doing one
decode at a time is honest, and doubles as abuse protection.

Streaming will **not** reuse that shape. An online recognizer is built for N
concurrent streams, and holding a single permit for a stream's lifetime lets one
browser tab starve every batch caller — the rate limiter cannot help, because
the connection is already established. Streaming gets one shared recognizer with
per-session streams and its own small semaphore, while unary keeps its permit.

Note this is a **recognizer-layer** change, not a transport one. Batch and
streaming also need **two different models** (offline TDT; a separate online
export), both GPU-resident — budget the memory for both. Use the fp16/fp32
exports, never int8: int8 is a CPU optimisation and typically runs *slower* on
the ORT CUDA execution provider.

### 5. Auth: a shared bearer token in-band, not authentik forwardAuth

`authorization: Bearer <token>`, constant-time compare, a `tonic` interceptor on
every RPC. The token comes from Infisical via `common-app-chart`'s `infisical`
block.

**forwardAuth is rejected on a technical ground, not a preference.** authentik's
proxy provider answers an unauthenticated request with a 302 to a login page. A
native gRPC client cannot follow that — it sees a non-`application/grpc`
response and fails opaquely. It would also add a round-trip to
`platform-authentik-server` on every RPC. This is a deliberate exception to
ADR-0039's direction, scoped to non-browser protocol clients.

`:8080` health is unauthenticated and never routed externally. Only `:9090` is.

### 6. Grey-cloud DNS, and edge middleware written from scratch

`stt.bnei.dev` as an explicit **DNS-only A record** overriding ADR-0038's
proxied `*.bnei.dev` wildcard — the same mechanism and the same file as `fleet`
(streaming vs Cloudflare's 100s idle ceiling), `s3` and `*.ente`. Mirrored into
`docs/dns/bnei.dev.zone` with its reason, as those three are.

Three things about the Traefik side that are easy to get wrong:

- **`grpcWeb` does not do CORS.** It exposes exactly one property,
  `allowOrigins`. Every browser call carries `authorization`, so every call is
  preflighted, and `accessControlAllowHeaders` lives on the **`headers`**
  middleware. A `headers` middleware is mandatory, not optional.
- **With `ingress.enabled: false` the chart renders no middleware at all**, so
  both are written by hand. `rateLimit` must omit `sourceCriterion`:
  `CF-Connecting-IP` is absent on a direct (grey) connection, and bucketing on
  an absent header collapses every caller into one empty-key bucket.
- The IngressRoute service reference needs **`scheme: h2c`**, which is an
  unconstrained string with no enum — a typo passes admission and fails at
  Traefik. Verify after deploy, do not trust the apply.

## Consequences

- **The hostname is public knowledge minutes after issuance.** `certResolver: le`
  publishes `stt.bnei.dev` to Certificate Transparency logs. Grey cloud means no
  Cloudflare WAF and no origin lock. "Not anonymous public" therefore rests
  entirely on one shared secret with no second factor — so the token is
  **≥256 bits and generated, never chosen**, and the real defences are
  `Semaphore(1)`, a hand-written `rateLimit`, and
  `max_decoding_message_size(16MB)`.
- **Token rotation breaks browsers silently.** `autoReload: true` restarts the
  pod; every browser client then 401s with no re-prompt path, because the token
  lives in `localStorage`. A 401 handler that clears storage and re-prompts is
  part of the browser client, not a nice-to-have — without it, rotation is an
  outage nobody diagnoses.
- **One XSS on any page holding the token exfiltrates the credential that also
  authorizes the owner's machines.** If that is unacceptable, the browser gets
  its own token — same interceptor, different secret. Not doing that today is a
  choice, and it is reversible.
- **`RollingUpdate` would wedge this deployment permanently.** The new pod
  requests the only `nvidia.com/gpu` while the old pod still holds it, so it
  stays `Pending` forever. `strategy.type: Recreate` is mandatory, and the first
  thing to trip it would be an Infisical `autoReload` token rotation.
- **`limitRange` must be disabled for this app.** The chart's default max of
  `{cpu: 2, memory: 4Gi}` is an *admission-time* rejection, and a
  CUDA + cuDNN + ORT process with a resident model has no headroom under 4Gi.
  `common-app-chart`'s own values comment names the GPU worker as the case.
- **This consumes most of the cluster's remaining CPU headroom.** At
  `requests.cpu: 500m` it takes `k8s-worker-01`'s baseline to a point where
  roughly *one* agent-fleet session trips `KubeCPUOvercommit` — see ADR-0037's
  2026-08-31 re-measure. It does not make the underlying failure worse (if that
  node dies the GPU dies with it, so this pod is unschedulable in exactly the
  scenario the alert describes), but it makes ADR-0037's lever 1 more urgent.
- **Traefik's timeouts are an open question, not a solved one.**
  `gitops/platform/values/traefik/values.yaml` sets no `transport:` key, so v3
  defaults apply: `readTimeout` 60s, `idleTimeout` 180s. If `readTimeout` is
  connection-level for HTTP/2, a browser mic session doing chunked unary over
  one reused connection exceeds it within a minute of speech — and **Phase 1
  breaks, not just streaming**. This must be *tested* before it is concluded.
  If it bites, the fix is scheduled maintenance: Traefik is `replicas: 1` with
  `Recreate` on an RWO `acme.json` PVC behind MetalLB
  `externalTrafficPolicy: Local`, so changing its values is a cluster-wide
  ingress blackhole bounded by a Longhorn detach/attach.
- **Persian and Arabic are deferred, and the deferral is already paid for.**
  Neither is in Parakeet's 25 languages. Whisper runs on the *same* `ort`
  runtime, so adding it later is a model file plus a config branch — same
  container, same CUDA setup, no new dependency, no architecture change.
  Whisper large-v3-turbo fp16 (~1.6GB) alongside Parakeet (~1.2GB) fits inside
  8GB. The proto already carries `RecognitionConfig.language`, honoured only by
  the offline model today and becoming the routing key later. **Do not build an
  engine-abstraction trait now** — one implementation is speculative
  scaffolding.
- **A fourth build-runner instance is needed** (ADR-0034: one runner per repo),
  which requires widening the `ACCESS_TOKEN` PAT first — a GitHub UI action,
  since `gh` cannot edit PAT scopes.
