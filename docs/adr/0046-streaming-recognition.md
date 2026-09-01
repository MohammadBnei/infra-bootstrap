# ADR-0046: Realtime streaming recognition — a second model, per-session state, still chunked unary

**Status:** Accepted — decided 2026-08-31.
**Date:** 2026-08-31
**Related:** [ADR-0044](0044-stt-grpc-service.md) (the service; its Decision 4
predicted this shape and its Decision 2 deferred the transport choice to "real
usage data"), [ADR-0045](0045-model-weights-out-of-the-image.md) (where the
second model's weights live), [ADR-0043](0043-gpu-node-enablement.md) (the 8GB
card both models have to share)

## Context

`stt.bnei.dev` went live on 2026-08-31 doing 4-second chunked unary at 131x
realtime. Decode is not the problem — the GPU is idle 99% of the time. The
problem is that **a word is spoken up to 4 seconds before it appears**, because
latency is dominated entirely by how long we wait to fill a chunk.

Three things stand between that and "it writes as you speak", and only one of
them is the transport.

### The model is the actual blocker

Parakeet TDT 0.6B is an **offline** model. Its Conformer encoder attends over
the whole utterance; feeding it 200ms slices returns garbage rather than partial
text. Shrinking the chunk buys latency and pays for it in accuracy at every
boundary, because there is no cross-chunk context to lose gracefully.

ADR-0044 Decision 4 already said batch and streaming need two different models.
This is that.

### The timeout question ADR-0044 left open is now answered

ADR-0044's Consequences flagged Traefik's defaults (`readTimeout` 60s,
`idleTimeout` 180s, no `transport:` key in
`gitops/platform/values/traefik/values.yaml`) as an untested risk, with the
worst case being *"Phase 1 breaks, not just streaming"* — if `readTimeout` were
connection-level, a browser holding one HTTP/2 connection would die inside a
minute of speech.

**Measured against the live service, 2026-08-31.** One HTTP/2 connection,
gRPC-Web POSTs at fixed marks:

| traffic pattern | result |
|---|---|
| requests at t = 0, 30, 65, 125s | all 4 succeed on one connection |
| requests every 20s for 220s (12 requests) | **all 12 succeed, no GOAWAY, no error** |
| a 65s idle gap | connection closed by the server |

So `readTimeout` is **per-request, not connection-level**, and the close is
**idle-based, not age-based** — a connection carrying traffic lives
indefinitely. Streaming sends a chunk every 560ms and is therefore never idle.

**No Traefik change is needed, and no maintenance window.** That matters
disproportionately: ADR-0044 notes Traefik is `replicas: 1` with `Recreate` on
an RWO `acme.json` PVC behind MetalLB `externalTrafficPolicy: Local`, so any
values change is a cluster-wide ingress blackhole. Not having to do it is the
single most valuable finding here.

The idle close is benign even when it happens: a browser transparently opens a
new connection. It costs a TCP+TLS handshake, not an error.

## Decision

### 1. Nemotron 3.5 ASR Streaming 0.6B, as a second GPU-resident model

Chosen over Parakeet EOU 120M, which is the lower-latency option (160ms chunks
against Nemotron's 560ms):

| | EOU 120M | **Nemotron 3.5 0.6B** |
|---|---|---|
| chunk | 160ms | 560ms |
| perceived latency | ~0.2s | ~0.6s |
| languages | English | 40 language-locales, auto-detect |
| output | raw | casing, punctuation, drops disfluencies |

0.6s is already below the threshold where a human reads it as "live", and the
alternative would have made the streaming path visibly worse than the batch path
it sits next to — no punctuation, no casing, English only — for 400ms nobody
asked for. The multilingual coverage also keeps ADR-0044's deferred Persian and
Arabic on the same trajectory rather than forking it.

**Sourcing the export is a real constraint, not a formality.** `parakeet-rs`
loads exactly three filenames — `encoder.onnx`, `decoder_joint.onnx`,
`tokenizer.model` (`model_nemotron.rs:80-81`, `nemotron.rs:384`). Of the four
ONNX exports on HuggingFace:

- `tonythethompson/Nemotron-3.5-ASR-Streaming-0.6B-ONNX` — **matches**, and
  carries `LICENSE.OpenMDW-1.1` + `NOTICE.md`. Chosen.
- `pantinor/nemotron-3.5-asr-streaming-0.6b-onnx` — matches, byte-identical
  sizes, no license file. Viable fallback.
- `soniqo/...-ONNX-FP16` — **does not load**: ships `decoder.onnx` + `joint.onnx`
  separately and `vocab.json` instead of `tokenizer.model`.
- `onnx-community/...-int4` — does not load, *and* int4 is rejected on the same
  grounds ADR-0044 rejects int8: quantisation is a CPU optimisation and
  typically runs slower on the ORT CUDA execution provider.

fp32, 2.59GB (2.45GB of it `encoder.onnx.data`).

### 2. The streaming model is loaded lazily, on first use

Both models resident is **~6.8GB of an 8GB card** — TDT measured at 3367 MiB
live, Nemotron estimated at ~3.4GB from an identically-sized fp32 export. That
leaves ~1.2GB for two ORT BFC arenas, which may or may not be enough.

Loading it at startup would find out at *deploy* time, and `strategy: Recreate`
means a pod that cannot start is an **outage of the working batch service**, not
a failed upgrade. Loading it on the first streaming request makes the same
failure one failed RPC.

This is a deliberate inversion of the usual "fail early" instinct, and it is
narrow: the CUDA assertion still runs, it just runs later. `--selftest` gains a
mode that loads both, so the number can be measured on demand rather than
discovered in production.

If it does not fit, the options are an fp16 export (none currently published in
a loadable layout) or serving one model at a time. Both are decisions to make
with the measurement in hand.

### 3. Still chunked unary — `session_id`, not WebSocket

Browsers cannot stream *up*: no gRPC client-streaming, no bidi, and
`duplex: 'full'` fetch ships in no stable browser. The audio has to go up as
discrete requests regardless of transport.

So the client sends 560ms chunks as separate unary calls carrying a
`session_id`, and the server keeps the recognizer state keyed by that id.
**The proto already reserved field numbers 3-5 for exactly this** — they are
un-reserved here and land where they were always intended to.

WebSocket is rejected *for now*, on the cost ADR-0044 already itemised: a second
listener, a second auth path (browsers cannot set headers on a WS handshake, so
the token goes in a subprotocol or a query string — and query strings land in
access logs), a second rate-limit surface, and its own timeout exposure. ADR-0044
called it "a decision to make with real usage data, not upfront"; with the
timeout question now answered, chunked unary has no known ceiling, so there is
still no data arguing for it.

At 560ms chunks this is ~1.8 requests/second per client against a rate limit of
100/s, on a connection that measurement now shows lives indefinitely.

### 4. `Semaphore(1)` no longer applies to everything

ADR-0044 Decision 4 predicted this and it holds: holding a single permit for a
stream's lifetime would let one browser tab starve every batch caller, and the
rate limiter cannot help because the connection is already established.

`parakeet-rs` is built for the right shape. `NemotronHandle` is
`Arc<Mutex<NemotronModel>>` and `Clone`; `Nemotron::from_shared(&handle)` spawns
an instance with independent decoder state (~7.5MB) over the shared ONNX
session, and **the model lock is held only during inference — 20-50ms per 560ms
chunk**. So the GPU is busy roughly 5% of the time per stream, and several
concurrent streams fit comfortably.

Therefore:

- **Offline** (`session_id` empty) keeps `Semaphore(1)` and the TDT model.
  Unchanged, and deliberately so — a batch caller submitting 8 minutes of audio
  should still be serialised.
- **Streaming** (`session_id` set) uses the shared handle plus a per-session
  recognizer, bounded by a separate small session cap.

### 5. Sessions are evicted on `last`, on idle, and under pressure

An unbounded map keyed by a client-supplied string is a memory leak with an
attacker-controlled key. Three bounds, all of them necessary:

- `last: true` closes the session and returns the final text.
- An idle sweep drops sessions untouched for longer than a timeout — browsers
  close tabs without saying goodbye, and that is the normal case, not the edge.
- A hard cap on concurrent sessions, rejecting with `RESOURCE_EXHAUSTED` rather
  than admitting one more. At ~7.5MB of state each the memory is not the binding
  constraint; the GPU's 20-50ms-per-chunk duty cycle is.

## Consequences

- **Perceived latency goes from ~4s to ~0.6s**, and the floor is the model's
  560ms chunk, not the network and not the GPU. Decode is 20-50ms per chunk on
  a card already measured at 131x realtime.
- **The PVC now holds two models, ~5.1GB** (TDT 2.49GB + Nemotron 2.59GB)
  against an 8Gi claim. `local-path` does not enforce quotas, so the claim is
  advisory and the real constraint is `k8s-worker-01`'s OS disk — which it
  shares with agent-fleet's session volumes.
- **First streaming request after a pod start pays the model load** (~4s
  observed for TDT). Deliberate, per Decision 2. A batch-only deployment never
  pays it at all.
- **Two models means two silent-CPU-fallback surfaces.** The startup assertion
  covers TDT; the lazy path must assert on Nemotron too or ADR-0044 Decision 3's
  guarantee quietly halves.
- **The transcript is append-only, not revised.** `transcribe_chunk` returns the
  new text for that chunk rather than a corrected running hypothesis, so the
  client concatenates. That is simpler than the usual partial/final dance and it
  is a property of this model — an engine that revises would need `is_final` on
  the response and a client that replaces its tail.
- **`session_id` is client-supplied and unauthenticated beyond the shared
  bearer token.** Every caller already holds the same token (ADR-0044
  Decision 5), so one caller can guess another's session id and interleave audio
  into it. Accepted: the population of callers is the owner's own machines and
  browsers, which is the same trust boundary the single shared token already
  assumes. It becomes a real problem the moment tokens are per-client.

  **Resolved 2026-09-01.** Tokens did become per-client (0.6.0, ADR-0044
  Decision 5 as amended), which by the sentence above should have made this a
  real problem — instead it removed it. Both consumers are backend proxies:
  each holds its own `STT_TOKEN_<NAME>` server-side and derives the STT
  `session_id` by HMAC over its own authenticated user identity, so a browser
  never chooses a raw session id and cannot name another user's. The caveat now
  applies only to the `stt.bnei.dev` test page, which holds `STT_AUTH_TOKEN` in
  `localStorage` and is a single-operator tool.

## Out of scope

WebSocket (revisit trigger: a measured ceiling on chunked unary, which does not
currently exist). Parakeet EOU as a second streaming tier. Speaker diarization,
which `parakeet-rs` also ships. Server-side revision of past hypotheses.
Per-client tokens, which is what would make `session_id` need real
authorisation.
