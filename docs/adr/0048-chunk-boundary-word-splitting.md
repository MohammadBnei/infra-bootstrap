# ADR-0048: A word split across a chunk boundary — the correction model we did not build

**Status:** Accepted — decided 2026-09-02. The fix is built and merged
(`ukubi-stt` PR #24); the rejections are the durable half of this record.
**Date:** 2026-09-02
**Related:** [ADR-0046](0046-streaming-recognition.md) (chunked unary, per-session
state, and the append-only transcript this leans on), [ADR-0047](0047-persian-speech-to-text.md)
(the Persian engine, which is the control group here), [ADR-0044](0044-stt-grpc-service.md)
(the service and its shared-token trust boundary)

## Context

Streaming dictation on `stt.bnei.dev` rendered `bonjour` as `bon jour` whenever
the word straddled a 560 ms chunk boundary. Reported across languages.

The obvious reading is that chunking hurts the model at boundaries, and the
obvious remedy is a small model reviewing and repairing the output. That was the
first proposal. It would have added an inference to a path whose entire value is
being ~560 ms behind speech.

**It was not a model problem, and there was no accuracy trade-off to make.** The
server had already sent the right answer and the test page threw it away.

SentencePiece marks a word-**initial** piece with `▁`. `parakeet-rs` renders that
mark as a leading space and does not trim (`nemotron.rs:276-282`, `:754-763`), so
on the wire **the leading space is the word boundary** — a chunk that continues a
word arrives without one. `web/index.html:322` then did:

```js
if (r.text.trim()) {
  transcript += ((transcript && " ") || "") + r.text.trim();
}
```

`.trim()` deletes the signal; a space is then fabricated between every pair of
chunks. `" bon"` + `"jour"` → `"bon" + " " + "jour"`.

Three facts pinned it to the client rather than the model:

- **Streaming only.** The offline path is a single request with nothing to join.
- **All languages.** Persian is an entirely different model with its own
  detokeniser (ADR-0047). The client join is the only code both engines share.
- **`stt.bnei.dev` only.** `agent-fleet` appends verbatim (`MicButton.tsx:98`
  `onText(res.text)`, `Composer.tsx:79` `onChange(prev => prev + t)`) and never
  had the bug.

## Decision

### 1. Fix the join, in the client, verbatim

`transcript += r.text`. No trim, no fabricated separator — **and no guard.** The
`if (r.text.trim())` had to go as the third change, not survive as the second:
appending `""` is already a no-op, and after the fix a chunk whose entire text is
one separator has to survive or it glues the words either side of it together.
Keeping the guard would have traded one boundary bug for another.

### 2. Drop the leading separator server-side for Nemotron, for the right reason

`Recognizer::Nemotron` gains the `emitted` flag `PersianStream` already carried.

**This does not defend against a client that trims, and claiming otherwise was
the one wrong idea in the plan.** Dropping the *first* chunk's separator cannot
help chunks 2..N, which is exactly where a mid-word boundary lands. Persian is
the proof: it has had this flag since 0.10.1 and its words split in the browser
anyway.

What it removes is the **bait**. Without it, a correctly-concatenating transcript
opens with a stray leading space, visible under `white-space: pre-wrap` and in
any consumer's textarea. That stray space is very plausibly why someone reached
for `.trim()` in the first place. Deleting the space is what stops the trim
coming back — the durable half of the fix, and a weaker claim than the one first
written down.

`parakeet-rs` already agrees this is the right semantics: its whole-utterance
decoder trims exactly one leading separator (`nemotron.rs:264-274`) while its
per-token decoder deliberately does not. Streaming simply had nowhere that
happened, so the job fell to clients — who did it per *chunk* rather than per
*utterance*.

### 3. The contract goes in the proto and the README, and the reference client loses

`RecognizeResponse.text` is documented as a fragment: concatenate verbatim, never
trim. The README says the same next to its existing append guidance, with the
`▁` mechanism spelled out so nobody has to rediscover it.

The README was **already right** (`onChange(prev => prev + text)`) and the
reference page next to it was wrong. A consumer that copied the page rather than
the paragraph inherited the bug. Where the two disagree, the paragraph wins, and
it now says so.

## The remedies rejected, and what each would have cost

| Option | Latency | Why not |
|---|---|---|
| **Fix the join** | none | **Chosen.** It is the measured cause. |
| Correction model, per chunk | inference on every 560 ms chunk, on the critical path | Pays latency forever to repair a bug that was free to fix. The card already holds two models in 6880 MiB of 8192 (ADR-0046/0047); a third resident model was the decision ADR-0047 spent its most valuable paragraph avoiding. |
| Correction model, at `last: true` only | none perceived | The right *shape* if a real model-level split ever appears, and still rejected. It revises text the client has already appended, so the final response must carry the whole corrected utterance and the client must **replace** rather than append — `is_final` semantics, which ADR-0046 designed out on purpose ("the transcript is append-only, not revised"). Full bill: a proto field, per-session transcript accumulation the server does not currently keep, a coordinated change in every consumer, and an old-client path that appends the full utterance and duplicates the transcript. It also lands at the worst moment: the user has stopped talking and is waiting. |
| Correction in the consumer, on submit | none | Strictly better than the above if it is ever wanted. The consumer already holds the complete transcript in an editable box. Costs `ukubi-stt` zero lines and zero proto changes. Recorded so the service is not asked to do it. |
| Wire-level chunk overlap + merge | re-decode per chunk | Nemotron already carries 9 mel frames of `pre_encode_cache` and recomputes mel across the whole buffer precisely to avoid boundary effects (`nemotron.rs:812-843`). Adding overlap duplicates that and breaks the strict-ordering contract streaming depends on. |
| Per-token logprob merge gate | negligible | `transcribe_chunk_with_tokens` exposes `TokenInfo { id, text, logprob, local_frame }` and could gate a merge. There is nothing to gate: the boundary is known **exactly** from `▁`. A probabilistic test to recover information we were throwing away is strictly worse than not throwing it away. |
| VAD-aligned chunk boundaries | buffering to find silence | No VAD anywhere in the stack. It moves boundaries rather than fixing the join, and 560 ms is the encoder's own granularity. |

## Consequences

- **Split words stop, at zero added latency.** The streaming path keeps its
  560 ms floor and the GPU gains nothing to schedule.
- **The transcript no longer opens with a leading space** for Nemotron, matching
  Persian. Consumers that already appended verbatim see this as their only change.
- **`agent-fleet` required no change** and `web/stt-capture.js` was not touched,
  so neither vendored copy needed re-vendoring. The file carries no text at all —
  it is `send(pcm, last)` — which is why it could not have been the cause.
- **The proto's no-`is_final` contract got stronger, not weaker.** Every rejected
  remedy above that would have needed it is now recorded as rejected.
- **There is still no automated check that transcription quality survives
  chunking on the Nemotron path.** `--selftest-fa` does exactly this for Persian
  at browser-identical 8960-sample granularity, and its six-clip result (mean CER
  0.022, five character-exact) is the measurement that ruled out a model-level
  cause. Nemotron has no equivalent: `--selftest-stream` loads both models and
  decodes nothing. A `--selftest-stream [wav] [reference]` arm mirroring the
  Persian one is the gap this ADR leaves open.
- **The bug was unfalsifiable from the assembled transcript alone.** Cause-1 and
  cause-2 are only distinguishable in the *per-chunk* strings: a join bug shows
  `" bon"` then `"jour"` on consecutive responses, a model bug shows `" bon jour"`
  inside one. Any future report of this shape should look at the wire first.

## What this corrected about our own operating assumptions

- **"Make the contract uniform so no consumer can get it wrong" was wrong here.**
  The server cannot defend a client against destroying its own copy of the data.
  The honest justification for the server-side change is narrower — it removes the
  thing that tempts the mistake — and Persian was sitting there as a
  counterexample the whole time.
- **The reference client is documentation.** It contradicted the README for as
  long as the bug existed, and it is the artefact people copy.
- **Third time at this boundary.** The tail flush (ADR-0046), the Persian
  detokenise (ADR-0047), and now the join have each lost text at a chunk edge.
  All three were invisible in review and visible in one dictation.

## Out of scope

Any correction model, in this service. `is_final` / tail-replacement semantics.
VAD. Punctuation restoration. The streaming model's general accuracy gap
(`README.md`: "UQB cluster" for "Yukie cluster") — real, unfixed, and unrelated
to chunk boundaries.
