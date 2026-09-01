# ADR-0047: Persian speech-to-text — a third model, on the CPU, and Arabic that was already working

**Status:** Accepted — decided 2026-09-01, gate passed the same day on
`k8s-worker-01`. Decisions 1-4 are built and merged (`ukubi-stt` 0.9.0); Decision 5
is designed and unbuilt.
**Date:** 2026-09-01
**Related:** [ADR-0044](0044-stt-grpc-service.md) (the service; its Consequences
deferred Persian and Arabic), [ADR-0046](0046-streaming-recognition.md) (Nemotron,
which turns out to cover Arabic), [ADR-0045](0045-model-weights-out-of-the-image.md)
(where this model's weights live), [ADR-0043](0043-gpu-node-enablement.md) (the card
this deliberately does *not* use)

## Context

ADR-0044's Consequences deferred Persian and Arabic together, on the grounds that
neither is in Parakeet TDT's 25 languages. ADR-0046 then added Nemotron for
streaming and predicted it would keep both "on the same trajectory". Nobody checked.

Measured against the live service on 2026-09-01:

| request | result |
|---|---|
| streaming, no `language` or `auto`, Arabic speech | **correct Arabic script** — auto-detect finds it unaided |
| streaming, `language: "ar-AR"` | same, correct |
| **offline**, `language: "ar-AR"` | `"Ahlan wasahlan Hada ihtibar..."` — **Latin transliteration, silently** |
| streaming, `language: "fa-IR"` | `<unk><unk><unk>-l--<unk>...` — **accepted, returns garbage** |
| streaming, `language: "fa"` / `"ar-EG"` | `InvalidArgument`, correctly rejected |

So **Arabic has worked since 0.7.0 and the deferral expired unnoticed.** It is in
Nemotron's top transcription-ready tier.

Persian is genuinely absent and fails in the worst available way.
`parakeet-rs`'s `PROMPT_DICTIONARY` maps `fa-IR` to prompt index 38, so validation
passes, but NVIDIA's card lists no Persian in any tier. The crate's own doc comment
says it: codes exist "that the model has prompt slots for but are not in the model
card — those will run, but accuracy is not guaranteed."

## Decision

### 1. Arabic gets routing, not a model

Nothing to build for the streaming path — it already works, in both consumers,
today. What Arabic still needs is for the **offline** path to stop handing it to a
model that can only spell it in Latin. That is Decision 5.

### 2. Shenava Koochik v1.0 for Persian

114M FastConformer **CTC**, fine-tuned from `nvidia/stt_fa_fastconformer_hybrid_large`,
Apache-2.0. Published 10.64% WER / 3.79% CER on FLEURS-fa — the author's own
measurement on the author's own split.

The **`-tract-streaming` export**, `model.onnx`, 458,882,745 bytes fp32,
self-contained, opset 17. fp32 not int4/int8 per `fetch-model.sh`'s existing rule.
"tract" names the runtime the author validated against, not a format restriction;
its `.patch` only relaxes tract's own `Cast`/`Clip11` strictness, which is positive
evidence the export is ordinary ONNX.

Rejected: Whisper needs a hand-written autoregressive decoder loop and does not fit
VRAM at a size where its Persian is good. `whisper-rs` would need whisper.cpp's CUDA
backend built with `nvcc` on the build-runner, putting a second independently
compiled CUDA runtime in ORT's process — the coupling ADR-0045 spent a day removing.
MMS bakes one language adapter into the export at 1.93 GB fp16. SeamlessM4T
publishes no ONNX at all.

**NVIDIA does have a Persian model** — `stt_fa_fastconformer_hybrid_large`, the
parent of this one — it is simply outside the Parakeet/Canary/Nemotron families.

### 3. It runs on the CPU execution provider, and that is measured

Gate on `k8s-worker-01`, 0.9.0 image, a 3.99 s clip:

```
CER 0.000    44.8 ms per model step    RTF 0.045    0 <unk>
```

A step is 1.12 s of audio, so **4% duty per stream** — about 0.32 of a core at the
session cap of 8, against a `limits.cpu` of 3.

This is the most valuable decision in the ADR, because of what it deletes. Two
models already occupy **6880 MiB of 8192**. A third on the card would have meant a
VRAM measurement under load, an eviction policy, a thrash risk on the first `fa`
request after an `en` stream, and a third surface for the silent-CUDA-fallback bug
ADR-0044 exists to prevent. On the CPU provider none of those exist.

The published "83.9 ms/chunk" that first suggested CPU might work is a **tract**
number of unknown thread count and predicts neither ORT provider; it was not relied
on. An earlier draft argued tract is CPU-only — it is not (`tract-cuda`,
`tract-metal` exist) — so the figure was treated as unattributed and replaced with
the measurement above.

Revisit trigger: a step above ~400 ms, which is where 8 concurrent streams would
start competing for the 3-core limit.

### 4. Chunked streaming at 1.12 s, with the client unchanged

The graph takes 121 log-mel frames and advances 112, so a step is 1.12 s — twice
Nemotron's 560 ms. Clients keep sending 560 ms chunks and the server buffers two
into one step. **No change to either vendored copy of `stt-capture.js`.**

Two consequences that are properties of the model, not defects:

- **First text arrives ~1.68 s in, not ~1.12 s.** With `center_pad 256`, available
  frames after *k* client chunks are 55, 111, 167 — 111 is short of 121, so the
  first step cannot fire until the third chunk. The steady-state pattern is
  empty, empty, text, empty, text.
- **Persian dictation feels about twice as laggy as English.**

Because every other response carries no audio, `RecognizeResponse`'s timing fields
go bimodal for Persian — and `stt.proto` calls those "part of the contract, not a
debug log", because they are how a client detects decoding on the wrong device. The
replacement signal is a **per-model-step timing metric**: steps are a fixed 121
frames wide, so the number is comparable across runs where a per-request RTF is not.

### 5. `language` becomes the routing key, and the consumers must send it

Exactly as `stt.proto` has promised since 0.4.0: *"It becomes the routing key when a
second model lands for Persian/Arabic."* No proto change is needed.

- Streaming: `fa*` routes to Shenava, everything else to Nemotron.
- Offline with a language the batch model cannot *write* decodes on the correct
  streaming engine instead of transliterating.
- Normalisation must reach the value handed to the engine, not just the routing
  predicate: `set_target_lang` is an exact string match, so `ar_AR` would route
  correctly and then fail where today it decodes.

**Persian cannot work the way Arabic does, and this is not a detail.** Arabic works
because it is inside Nemotron's auto-detect. Persian is a *different model* and can
only be reached by naming it — so a caller that sends no `language` gets Nemotron
and `<unk>` soup. Verified: `agent-fleet` never sends one; `dream-analyst` sends
`?lang=` from a `<select>` defaulting to `fr`. **Both consumers need a Persian
option or the server work is unreachable from either UI.**

## Consequences

- **Persian dictation becomes possible at all**, at a measured CER of 0.000 on
  clean read speech and ~0.13 on colloquial speech with heavy ZWNJ usage.
- **The GPU is untouched.** The card keeps its 6880 MiB of two models and gains
  nothing to evict.
- **`fetch-model.sh` gains one entry and the PVC gains 438 MB.** `local-path`
  enforces no quota, so the real constraint is `k8s-worker-01`'s OS disk — 19 GB
  free of 96 GB, shared with agent-fleet.
- **The feature pipeline is ours now.** `parakeet-rs` computes log-mel internally
  and exposes none of it (`mod audio` is private), so `src/fbank.rs` is the first
  audio arithmetic this service owns. It is verified by a golden vector whose
  provenance is a numpy reference that decoded real Persian correctly *before* its
  intermediate frames were frozen — not by a fixture written from the same prose as
  the code.
- **Only one feature-pipeline trap is real.** Measured against the model: applying
  per-feature CMVN — NeMo's default, and what `parakeet-rs` itself does — takes CER
  from 0.033 to **1.000 with empty output**. Placing the 400-tap window at offset 0
  instead of centring it scores 0.042, and dropping preemphasis entirely scores
  0.056. The first is catastrophic and loud; the other two are nearly harmless. The
  expectation going in was that all three were silent hazards.
- **Numbers come out spelled** (`پنجاه و سه`, not `۵۳`) and there is no punctuation
  restoration. Fine for dictation into an editable box.
- **Persian is RTL and `text` is a bare string** with no direction marker. Mixed
  with the Latin punctuation the model emits it renders mangled in an LTR container;
  `dir="auto"` is needed in the test page and in each consumer.
- **A behaviour change once Decision 5 lands:** bare non-European subtags (`ja`,
  `zh`, `vi`, `he`, `ur`) are absent from `PROMPT_DICTIONARY`, so offline
  `language: "ja"` goes from 200 to `InvalidArgument`. More honest than today, but
  it is a wire-behaviour change.
- **The offline-with-no-language gap stays open.** Routing keys on `language`, so a
  caller that sends none and speaks Arabic still auto-detects on the batch model and
  still transliterates. Closing it needs output script-detection or a language-ID
  model — a fourth model. Neither live consumer uses the offline path, so this is an
  API-correctness gap rather than a user-facing bug.

## What the gate corrected about our own operating assumptions

Recorded because both would otherwise be repeated:

- **A gate pod does not need the Deployment stopped.** `local-path` RWO means one
  *node*, not one *pod*. The gate mounted the same PVC as the running service
  because both land on `k8s-worker-01`, and `stt.bnei.dev` served 200 throughout. An
  outage window was requested and turned out to be unnecessary.
- **`kubectl scale` on an ArgoCD-managed Deployment does nothing.** The
  ApplicationSet restores `syncPolicy.automated`, so selfHeal returns the replica
  within seconds. Anything that genuinely needs a scale-down has to go through git.
- **`kubectl exec`-ing a selftest into the running pod OOMs the live service**, now
  that two models are resident. `README.md` recommended exactly that.

## Out of scope

Punctuation restoration and inverse text normalisation (`persian_itn.py` in the
model repo is the reference). Dari — the model is Iranian-Persian fine-tuned, and
`fa-AF` has to be decided explicitly rather than falling through normalisation.
Server-side language identification, which is the only thing that would make
Persian work without a caller naming it. Any use of the GPU for this model.
