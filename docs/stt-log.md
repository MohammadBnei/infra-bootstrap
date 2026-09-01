# `ukubi-stt` — running log

Working log for the GPU speech-to-text service (ADR-0044) and the GPU node it
runs on (ADR-0043). **Append, do not rewrite.** Newest section last.

Companions, and what belongs where:
- `docs/adr/0043-*.md`, `docs/adr/0044-*.md` — the decisions and their rationale
- `docs/bootstrap-test-notes.md` — infrastructure incidents in full detail
- this file — the STT project's own thread: where we are, what we learned, what is next

---

## Where this stands (2026-08-31)

**Gate 0 has run and FAILED. That is the current blocker and the only one.**

```
gpu.used before load : 1 MiB
model loaded in      : 2.4s
gpu.used after warmup: 1 MiB (delta 0 MiB)
audio_seconds        : 3.00
decode_seconds       : 0.24
real-time factor     : 0.081
transcript           : ""

GATE FAILED: GPU memory grew by only 0 MiB (< 128 MiB)
```

**CUDA did not engage; ORT silently fell back to CPU.** The gate did its job —
0.081 RTF is 12x faster than realtime and looks like a healthy GPU result. Without
the memory-delta assertion this would have shipped as a working GPU service
running entirely on CPU. That is ADR-0044 Decision 3 paying for itself on first
contact.

### What the numbers narrow it to

- `gpu.used before load: 1 MiB` — `nvidia-smi` works **inside the container**, so
  the RuntimeClass, device plugin and `nvidia.com/gpu` request are all correct.
  The GPU is visible; ORT is choosing not to use it.
- `model loaded in 2.4s` — far too fast for CUDA context creation plus cuDNN
  algorithm selection on a 1.1GB model. That is a CPU session.

So the fault is inside the ORT / parakeet-rs layer, **not** the Kubernetes
plumbing. Everything in ADR-0043 is confirmed working.

### Next step

Re-run with ORT logging raised (`ORT_LOG_SEVERITY_LEVEL` / session log severity)
so ORT reports *why* it declined CUDA, instead of guessing between:

1. **ORT cannot find its CUDA provider at runtime** — the provider `.so`s are not
   in the runtime image, or need `load-dynamic` / `ORT_DYLIB_PATH`. Most likely.
   CI explicitly could not test this; it proved only that the code *builds*.
2. **CUDA/cuDNN major mismatch** between what `ort 2.0.0-rc.13` links and the
   `nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04` base.
3. `ExecutionProvider::Cuda` not reaching `from_pretrained` — least likely, the
   code passes it explicitly and it compiles under that cfg.

Note parakeet-rs registers CPU as ORT's fallback *behind* CUDA with
`error_on_failure()` on the **CPU** provider, so a CUDA failure is silent by
construction. That is why the assertion exists and why ORT's own logs are needed.

---

## Verified working (do not re-litigate)

| | evidence |
|---|---|
| GPU passthrough | all 4 TU104 functions at guest `01:00.0-3` |
| Driver | `580.173.02`, DKMS, persistence **Enabled** (survives reboot) |
| Container toolkit | 1.20.0, `/usr/bin/nvidia-container-runtime` present |
| containerd `nvidia` runtime | non-default, `SystemdCgroup = true` (bare bool) |
| Device plugin | Running, node advertises `nvidia.com/gpu: 1` |
| **Negative test (ADR-0011 guard)** | pod without RuntimeClass **cannot** see the GPU — `runc create failed: exec: "nvidia-smi": not found` |
| Positive test | `nvidia/cuda` pod with RuntimeClass prints the full GPU table |
| Image builds | `0.1.3` builds, pushes, and **pulls** on the GPU node |

---

## Merged 2026-08-31 (#210–#221)

| PR | |
|---|---|
| #210 | ADR-0043 GPU enablement + the `SystemdCgroup` bool→string fix |
| #211 | Device plugin never scheduled (chart affinity); driver pin was a shim |
| #212 | `nvidia-persistenced` ran with persistence mode **off** |
| #213 | ADR-0043 → Accepted; ADR-0037 re-measured; 6 drift corrections |
| #214 | ADR-0044 proposed; thin-pool near-miss logged |
| #215 | Fourth build-runner instance for `ukubi-stt` |
| #216 | `discard=on` on all 10 VM disks |
| #217 | `ukubi-stt` Infisical project + `STT_AUTH_TOKEN` documented |
| #218 | 3 terraform drifts reconciled (hermesagent node, k9s DNS, **pg01 RAM**) |
| #219 | zot retention: 2 tags for `ukubi-stt`, 3 elsewhere |
| #220 | server1 NIC stuck at 100Mb → gigabit, persisted as IaC |
| #221 | zot `readTimeout`/`writeTimeout` 60s → 30m |

---

## The build chain, and what each failure taught

Six distinct failures, each further along than the last. Recorded because the
*sequence* is the lesson: none of them was the "real" problem, and each was only
visible once the previous was cleared.

| tag | failed at | cause | fix |
|---|---|---|---|
| 0.1.0 | `cargo build` | no `libssl-dev` in the CUDA image | added |
| 0.1.1 | linking | ORT prebuilt needs glibc 2.38+/libstdc++ 13+; 22.04 is 2.35/12 | `ubuntu24.04` |
| 0.1.2 | runtime stage | PEP 668 blocks `pip3` on 24.04 (self-inflicted by the 24.04 move) | dropped Python, `curl` |
| 0.1.3 | layer commit | build-runner disk full | removed the orphaned 22.04 base (8.15GB) |
| 0.1.3 | **push** | 100Mb NIC, then Longhorn rebuild contention, then zot's 60s timeout | see below |
| 0.1.3 | **pull** | containerd snapshotter debris from the aborted pulls | prune + restart containerd |

### The push: zot's undocumented 60s read timeout

The headline infra finding. `pkg/cli/server/root.go` (v2.1.20):

```go
const defaultReadTimeout = 60 * time.Second
if config.HTTP.ReadTimeout == nil { ... }
```

zot injects a 60s HTTP read timeout when config omits one, and does not document
it. Go's `ReadTimeout` covers the **entire request including the body**, so it
hard-caps a blob upload regardless of progress.

The getter actively misleads: `GetHTTPReadTimeout()` returns `0` when unset, so
reading it suggests no timeout. The CLI populates the field *before* the server
is constructed. **Checking the getter and not its writer cost hours.**

Measured, on two network paths:

```
2400MB throttled to 9MB/s (its share under 11-way concurrency)
  via MetalLB VIP:   killed at 60.098s, sent 541 MiB
  direct to pod IP:  killed at 60.100s, sent 541 MiB   ← IPVS/MetalLB bypassed
```

Why only this image: 5580MB across 11 layers, including 2468/2042/828MB.
buildah pushes **all layers concurrently** against ~56MB/s aggregate, so a big
layer gets ~1/11th and needs minutes. A single *unthrottled* 2468MB layer takes
**57.6s** and squeaks under — which is why it looked intermittent, and why no
other image here ever reached the limit.

`writeTimeout` was raised symmetrically: it bounds how long zot may take to
**serve a pull**. Nothing had hit it because pulls run at LAN speed, but the same
60s against a multi-GB layer on a contended link would break pulls cluster-wide.

Set to 30m, not 0 — zero disables the slowloris protection these exist for.

### The pull: containerd tripping over its own debris

After the push finally succeeded the image would not pull:
`failed to extract layer ... gzip: invalid checksum`, reproducible in ~40s.

The data was innocent, proven four ways: digest matched the manifest, `gzip -t`
passed, it decompressed all 2.41GB cleanly, and `tar -xzf` extracted it by hand
on that very node with exit 0 and 29G free.

The cause was **20GB of leftover overlayfs snapshots** from the dozen aborted
pulls. `crictl rmi --prune` + `systemctl restart containerd` (8.2GB after) and
the pull succeeded immediately.

---

## Wrong theories, and what killed each

Kept deliberately — knowing what it *is not* is most of the value, and several of
these were confidently argued before dying.

| theory | killed by |
|---|---|
| zot OOM on a 2.3GB blob (1Gi limit) | 304Mi in use, 0 restarts, `lastState: {}` |
| A 2GiB blob cliff (weights are 2323MB) | first by a 200MB blob failing identically; later properly by 1900MB **and** 2200MB round-tripping clean through both `PUT` and buildah's `PATCH→PUT` path |
| build-runner memory / socket throttling | cgroup counters were **cumulative** and included my own failed test commands. At 8GB the build failed again with `max 0 oom 0 sock_throttled 0`. The 8GB bump was reverted |
| Traefik's 60s `readTimeout` | `registry.bnei.lan` → `192.168.1.234` (zot LB); Traefik is `.233` and not in the path at all |
| Longhorn rebuild contention | real, and it did slow things — but the failure reproduced on a fully healthy cluster |
| Corrupt blob in the registry | I verified a **stale digest** (`cd73f539`) that had already been deleted; the live manifest referenced `8d8b16dd`, which verified clean |
| Flaky USB NIC hardware | both carrier flaps that day were **self-inflicted** — my `ethtool` fix and the ansible playbook re-running it. 3 events in 5d20h uptime, `tx_errors: 12` of 458M packets |

### My own measurement errors, recorded so they are not repeated

- **`head` on a diff.** `head -20` on a `terraform plan` attribute list hid
  `pg01 memory 4096 -> 2048` — an apply would have **halved the Postgres
  primary's RAM**. `head -12` on `ethtool` showed one line of a three-line
  `Supported link modes` list and produced a confident, wrong "this adapter
  cannot do gigabit". Read the whole diff, every time.
- **`curl --data-binary @file` buffers the entire body in RAM.** It OOM-killed my
  own 2.4GB test inside a 4GB container with `swap: 0`, which I then briefly
  mistook for evidence about the real push. `-T` streams.
- **Timing from the wrong origin.** I measured push-failure elapsed from *push
  start*; a per-request deadline runs from when *that blob's* PATCH began, and
  each retry restarts it. That made a constant 60s deadline look random, and I
  nearly abandoned the timeout theory because of it.
- **Cumulative counters as point-in-time evidence.** cgroup `memory.events` is
  cumulative since cgroup creation.

---

## Open items

**Blocking Gate 0**
- Why ORT declined CUDA. Next action: raise ORT log severity and re-run.

**Design question, unresolved**
- **Model in the image vs fetched at runtime.** Currently baked in: 2.4GB of
  weights inside a 5.58GB image. Argument for runtime fetch: the giant layer is
  what made every push a fight. Argument against: the push is a *one-time* cost
  (blobs are content-addressed and skipped on later pushes), pulls come from
  `registry.bnei.lan` at LAN speed, and `.165` reboots for gaming so an
  `emptyDir` would re-download 2.4GB over WAN each restart — meaning a PVC plus
  init container, not a simple change. **Note removing the model alone would not
  have fixed the push**: the 2042MB CUDA layer still exceeded the old 60s budget.
  Decide with real pull-time numbers once Gate 0 passes.

**Infrastructure, not blocking**
- **cp-01 at 105% and cp-02 at 103% of allocatable memory** (3.9GB nodes running
  etcd + apiserver + Loki/Prometheus). This evicted the Longhorn instance-manager
  and wedged a rebuild. **`ADR-0037:29` claims control planes are tainted — they
  are not, they have no taints at all.** A naive taint would break Longhorn:
  `longhorn-manager`, `longhorn-csi-plugin`, `engine-image` and `platform-alloy`
  have **no tolerations**, and with 3 replicas + hard anti-affinity + only 2
  workers, Longhorn is *forced* onto control-plane nodes. Options were narrowed to
  targeted pinning, or a third worker. Nothing committed.
- **zot's Deployment has no `checksum/config` annotation**, so ConfigMap changes
  are inert until someone restarts the pod manually. Hit this applying #221.
- **Nothing monitors the LVM thin pools.** server1 reached 94.96% unnoticed;
  `blackbox-exporter` probes `pveproxy` but nothing watches `lvs data_percent`.
- **`.165` reboot re-test** for ADR-0043 still outstanding (VM-level reboot passed;
  a host reboot has not been tried).
- **ADR-0037 remains undecided**, now with corrected numbers.
- **pg02 is the Postgres primary** as of today (failover during the `discard`
  reboots; pg01 rejoined as `replica streaming lag=0`).

---

## Operational gotchas worth remembering

- **`qm reboot` is wrong for a self-draining node.** `drain-self.service` outran
  its shutdown timeout on `k8s-cp-01`, leaving the VM **stopped rather than
  rebooted**. Use `qm shutdown --timeout 600` then `qm start`.
- **`pct resize` on LVM-thin costs nothing when you run it and everything when
  you write into it.** server1's pool was at 94.96% with 527G provisioned against
  348G; the resize would have looked fine and taken every filesystem read-only,
  Postgres included. `pct fstrim` reclaimed 37.8GB instead — more than the resize
  would have provided.
- **`discard=on` only enables propagation.** The guest must still `fstrim`, and
  qemu re-reads the flag on disk attach, so a running VM needs a restart. ~265GiB
  reclaimed across the fleet this way.
- **A Healthy ArgoCD Application is not evidence anything ran.** The device plugin
  reported Synced/Healthy with `DESIRED=0` for hours.
- **A chart's own `nodeAffinity` is ANDed with your `nodeSelector`**, not
  overridden by it.
- **`apt-cache madison` proves a version exists, not that the metapackage installs
  it.** `nvidia-driver-570-server` is a shim for 580.

---

## Gate 0 root-caused, 2026-09-01 — two bugs, both in the Dockerfile

`ukubi-stt` [#1](https://github.com/MohammadBnei/ukubi-stt/pull/1). The
"Where this stands" section above listed three candidates and ranked them.
Candidate 1 was right, and it turned out to be *two* independent faults, either
of which alone produces the identical silent CPU fallback.

### Bug 1 — `libonnxruntime_providers_cuda.so` was never in the image

ONNX Runtime is linked **statically** into the binary, but its CUDA execution
provider is not part of that archive. It is a separate 79MB shared object that
ORT `dlopen`s at first use, resolved against the *calling module's own path* —
which for a static link is the directory of the executable. Read off the running
pod:

```
$ ldd /usr/local/bin/ukubi-stt | grep -Ei 'onnx|cud'      # nothing
$ find / -xdev -name 'libonnxruntime*'                     # nothing
$ grep -ao 'libonnxruntime_providers_[a-z]*\.so' /usr/local/bin/ukubi-stt
libonnxruntime_providers_cuda.so                           # the dlopen path is there
```

The build produced the file. The Dockerfile copied only the binary out of the
builder stage.

There is a trap behind the obvious fix: **ort-sys's `copy-dylibs` feature does
not copy on Unix, it symlinks** — into `target/release/` from
`~/.cache/ort.pyke.io/dfbin/`. A plain `COPY --from=build target/release/*.so`
lands dangling symlinks in the runtime image and fails in exactly the same way as
the file being absent. `cp -L` into a staging dir first, and name the files
explicitly so an upstream rename is a build failure rather than a silent CPU
fallback.

### Bug 2 — CUDA 12 was never available, so the base image could not have been right

`ort-sys` 2.0.0-rc.13 does not build ONNX Runtime. It downloads a prebuilt one
chosen from a hardcoded table, `build/download/dist.tsv`. For
`x86_64-unknown-linux-gnu` that table has exactly four rows: no-features,
`webgpu`, `nvrtx`, and `cuda13,tensorrt,nvrtx`. **No CUDA 12 build exists for
Linux.** Its own resolver states the consequence:

```rust
_ => { log::debug!("couldn't determine CUDA version, guessing 13");
       "cuda13" } // "fallback" to the lowest version we ship (we only ship 13 for now)
```

The CUDA 12.6.3 builder matched none of the CUDA-13 sniffs
(`NV_CUDA_CUDART_VERSION`, `CUDA_HOME`, `nvcc --version`), fell into that arm,
and downloaded the CUDA **13** distribution regardless — into a CUDA 12 runtime.

`DT_NEEDED`, read off the provider rather than assumed:

```
libcudart.so.13, libcublas.so.13, libcublasLt.so.13, libcurand.so.10, libcuda.so.1
```

plus `libcudnn.so.9` and `libcufft.so.12` **`dlopen`ed lazily by name**, which
linkage alone would never have shown — and which is why the runtime image keeps
the `-cudnn-` variant even though nothing links cuDNN.

Driver `580.173.02` is a CUDA 13.0 driver (>= 580.65.06 required) and the
provider's embedded arch list carries `sm_75`, so the Turing card is covered.
`ORT_CUDA_VERSION=13` is now set in the builder so the resolution is read rather
than guessed.

### What made this expensive, and the fix for next time

ORT names the provider it declined and the reason, at `debug` level, routed
through `tracing`. **parakeet-rs installs no subscriber**, so every one of those
events was dropped and the diagnosis had to come from reading `ort-sys`'s build
script and pulling the distribution tarball apart by hand. The gate binary now
installs a subscriber defaulting to `warn,ort=debug`.

The generalisable lesson, since this is the second time a variant of it has cost
a day: **a dependency that ships prebuilt binaries decides your base image, and
it will not tell you.** Read the crate's build script and the `DT_NEEDED` of what
it downloaded. `ADR-0044`'s own text said "read that from `ort`, do not assume" —
the assumption got made anyway, in a Dockerfile comment that called CUDA 12.6 a
"current best guess".

Also corrected in passing: `ukubi-stt`'s README claimed the registry keeps the
last 3 tags. It keeps **2** for this repo (#219) — the image is a ~5GB CUDA tree.

---

## Gate 0 PASSED, 2026-08-31 — the engine is settled

`ukubi-stt:0.2.0`, on `k8s-worker-01`, against a real 16 kHz mono WAV:

```
gpu.used before load : 1 MiB
gpu.used after warmup: 3488 MiB (delta 3487 MiB)
audio_seconds        : 9.23
decode_seconds       : 0.05
real-time factor     : 0.006
transcript           : "The quick brown fox jumps over the lazy dog, testing speech
                        recognition on the Yukie cluster with a parakeet model
                        running on an NVIDIA GPU."
```

Word-perfect with punctuation and casing. "ukubi" came back as "Yukie", which is
the right kind of wrong — a phonetic guess at a word in no vocabulary, not a
model failure.

ORT now says what it is doing, which is the whole point of the subscriber added
in `ukubi-stt#1`:

```
Discovered OrtHardwareDevice {vendor_id:0x10de, device_id:0x1e84, pci_bus_id=0000:01:00.0}
Successfully registered `CUDAExecutionProvider`  source=session options
Creating BFCArena for Cuda ...
cuDNN version: 91400
```

**165x faster than realtime, against 12x on the CPU fallback.** ADR-0044
Decision 1 is verified rather than assumed, and the streaming proto is
unblocked.

Two carry-forwards:

- **`cuDNN version: 91400` kills the "drop `-cudnn-runtime`" idea.** It looked
  free — the provider has no `DT_NEEDED` entry for cuDNN — and that reasoning is
  correct and still lands on the wrong answer, because it is dlopened by name.
  ~1.5-2GB that is not available. Recorded in ADR-0045 Decision 3 so it is not
  re-proposed.
- **`WARN: 2 Memcpy nodes are added to the graph ... may prevent CUDA graph
  capture`.** Irrelevant at 0.006 RTF. It matters in Phase E, where per-chunk
  overhead is the entire latency budget.

### Image composition decided — ADR-0045

Run as an architecture interview immediately after the gate passed, while the
numbers were fresh. Weights move to a `local-path` PVC fetched only when absent;
CUDA libraries stay in the image because the image is the ABI pin, not storage —
pyke chooses the soname set, not us, and splitting it across two repos gives no
CI anywhere the ability to check it still agrees.

The revisit trigger for the CUDA half is named rather than left open: **a second
GPU workload on this node**, at which point two images carrying an identical
3.3GB stack makes amortisation a real argument. It is not one today.

The largest single win turned out to be somewhere nobody was looking: the
**builder** base is `nvidia/cuda:13.0.3-cudnn-devel` at **8.23GB**, and nothing
in the compile touches CUDA — `ort-sys` downloads a prebuilt ONNX Runtime, links
it statically, and dlopens the provider. Plain `ubuntu:24.04` should do, and a
wrong guess there is a compile error rather than a silent fallback.

---

## The service is live, 2026-08-31 — `stt.bnei.dev`

Phase C done in one pass after Gate 0. `ukubi-stt` 0.3.0 is deployed, ArgoCD-managed,
and answering over the internet.

```
$ grpcurl -authority stt.bnei.dev -H "authorization: Bearer $T" \
    -d @ 82.65.231.50:443 stt.v1.Stt/Recognize < req.json
{
  "text": "The quick brown fox jumps over the lazy dog, testing speech recognition
           on the Yukie cluster with a parakeet model running on an NVIDIA GPU.",
  "audioSeconds": 9.2275,
  "decodeSeconds": 0.079
}
```

**117x realtime**, through the full path: WAN -> Freebox -> Traefik VIP -> the
hand-written `scheme: h2c` IngressRoute -> the pod -> the RTX 2070 SUPER.

Verified, not assumed:

| | result |
|---|---|
| CUDA at startup | `CUDA engaged (3367 MiB resident)`, health binds only after |
| no token | `Unauthenticated: missing authorization metadata` |
| wrong token | `Unauthenticated: invalid token` |
| `sample_rate_hertz: 44100` | `InvalidArgument`, with the ffmpeg line to fix it |
| in-cluster gRPC | 0.104s for 9.23s of audio |
| through Traefik + TLS | 0.081s |
| via the public WAN IP | 0.079s |
| cert | the existing `*.bnei.dev` wildcard already covers `stt` — no new issuance |

**ADR-0045 Decision 1 proved itself on the second pod.** The first pod's init
container downloaded the 2.4GB of weights; the replacement pod's logged
`model already present in /models/tdt` and skipped straight to serving. The PVC
behaved as a cache, exactly as designed.

### DNS: four cache layers, and only one of them was real

`stt.bnei.dev` was created grey (DNS-only) per ADR-0044 Decision 6. Verifying it
cost more than creating it, because the answer differed at every layer:

- `dig @<cloudflare NS>` returned the **proxied wildcard's** IPs with a
  *counting-down* TTL. An authoritative server returns a fixed TTL — the
  countdown was the tell that something local was intercepting port 53 and
  answering from cache. `dig @anything` is not a reliable check on this LAN.
- **DoH bypasses it.** `https://cloudflare-dns.com/dns-query?name=...&type=A`
  and Google's `dns.google/resolve` both showed `82.65.231.50` immediately.
  That is the check to use here.
- Plain `dig` came good on its own once the local cache expired.
- **macOS's own resolver was last.** `dig` bypasses mDNSResponder, so `dig` was
  right while `curl`/`grpcurl` still went to Cloudflare — a 403 with
  `server: cloudflare` and a `cf-ray` header, which reads like an origin
  problem and is not one. `dscacheutil -q host -a name <host>` shows what
  applications will actually get.

I spent several minutes convinced Cloudflare was ignoring `proxied: false`. The
API said `proxied: False` the whole time and was telling the truth.

### Open

- **No browser client yet**, so the `grpcWeb` + CORS `headers` middlewares are
  deliberately not deployed. `grpcWeb` exposes only `allowOrigins`; CORS lives
  on a separate `headers` middleware and every browser call is preflighted
  because it carries `authorization`. Both land with the client, when the origin
  is a real value rather than a guess.
- **`Cargo.lock` is still not committed**, so builds are not reproducible. The
  Dockerfile says to commit the one the first green build produces. Easiest fix
  is to pull it out of a build-runner container.
- **Traefik's `readTimeout` (60s default) is still untested** for a long-lived
  HTTP/2 connection. Irrelevant at 0.08s per call; it decides whether Phase E
  needs the Traefik maintenance window.
- `release-it` was added after the fact — 0.2.0 and 0.3.0 were tagged by hand,
  so neither has a changelog entry.
- ADR-0044 stays **Proposed**: Decisions 1-6 are now built, but streaming
  (Phase E) and the browser client are not.

---

## Realtime streaming, 2026-08-31 — ~4s to ~0.6s

ADR-0046, shipped as `ukubi-stt` 0.5.0 + 0.5.1. Same unary RPC, second model,
per-session state.

```
chunk  1/17  decode 5287ms  ''                 <- lazy load of the second model
chunk  2/17  decode   27ms  ' The quick brow'
chunk  3/17  decode   25ms  'n fox ju'
chunk  4/17  decode   25ms  'mps over the'
...
chunk 17/17  decode   26ms  'PU'   LAST
transcript: ' The quick brown fox jumps over the lazy dog.  Testing speech
              recognition on the UK cluster with a perikeed model running on
              an NVIDIA GPU'
```

| | measured |
|---|---|
| decode per 560ms chunk | **22-28ms** (the crate documents 20-50ms) |
| round trip | 230-320ms — latency is now **network**, not GPU |
| both models resident | **6880 MiB** of 8GB, ~1.3GB headroom |
| lazy load, first streaming request | 4.9s, `mode Multilingual` |
| RTF excluding the one-time load | ~0.045 |

**ADR-0046's one real estimate held.** It said "~6.8GB of an 8GB card" and hedged
the whole design on that being uncertain — lazy loading, so a bad fit would be
one failed RPC instead of an outage of the working batch service under
`strategy: Recreate`. Measured 6880 MiB. The hedge cost nothing and was still the
right call while it was a guess.

### The bug that only measuring would have found

The first run's transcript ended `...on an NVIDIA G`. The final `PU.` was gone.

Chunk 17 was a 270ms partial, and **the streaming encoder emits only on a
complete 560ms chunk** — so a final partial chunk is buffered and never decoded.
Every utterance would have silently lost its ending, with no symptom beyond a
transcript that is slightly short. Nothing in the code reads as wrong; the
`transcribe_chunk` contract is doing exactly what it says.

Fixed server-side on `last: true` by padding with silence to the next chunk
boundary plus one further full chunk, which pushes the model's right-context
window past the real speech. Silence decodes to nothing, so it costs one ~25ms
decode. Server-side rather than client-side because `last` already means
precisely "flush what you have", and a client that forgot would drop words
invisibly.

### Streaming is less accurate than offline, and that is the trade

"UK cluster" for "Yukie cluster", "perikeed" for "parakeet" — against the offline
model's word-perfect run on the same clip. Expected: less context. It is why file
uploads still route to the batch model, which sees the whole utterance.

### Traefik's timeout — the ADR-0044 open question, closed

Measured before building anything, because the answer decided whether Phase E
needed a maintenance window:

- requests at t=0/30/65/125s: all 4 on **one** HTTP/2 connection
- requests every 20s for 220s: **all 12 succeed, no GOAWAY, no error**
- a 65s idle gap: connection closed

So `readTimeout` is **per-request, not connection-level**, and the close is
**idle-based, not age-based**. Streaming sends every 560ms and is never idle.
**No Traefik change and no maintenance window** — which matters because Traefik
is `replicas: 1` with `Recreate` on an RWO `acme.json` PVC, so touching its
values is a cluster-wide ingress blackhole.

### CI: deploy after push, not before

0.4.0 deployed against a tag that was still uploading — `helm/values.yaml`'s
`image.tag` was hand-edited in the feature PR, ArgoCD synced main within seconds
of the merge, and the image landed minutes later. With `strategy: Recreate` the
old pod was already gone, so that was an **outage**, not a no-op upgrade.

`image.yml` now bumps the tag in a `deploy` job after a successful push, the
shape `agent-fleet`'s `docker.yml` already used. Verified on 0.5.0/0.5.1:
`Successfully pulled image ... in 832ms`, zero `ImagePullBackOff`.

Two details carried over from agent-fleet rather than rediscovered: `always()`
plus an explicit `needs.*.result` check (a job's implicit success()-on-needs
default was observed skipping deploy after a green build), and an assertion that
the `sed` actually matched (a no-op `sed` leaves the previous tag, ArgoCD
redeploys nothing, and the workflow is green — silence reading as success).

`release-it` was added at the same time, matching the other three build repos.
Two deviations, both forced by `image.yml`: bare `${version}` tags, and an
`after:bump` hook syncing `Cargo.toml` from `package.json`.

### The image got much smaller

**5.85GB -> 2.09GB**, which is ADR-0045's weights-out-of-the-image change
becoming visible. The init container fetched TDT once and logged `already
present in /models/tdt` on every pod since; only the new Nemotron weights were
downloaded when 0.5.0 rolled out.

### Open

- **`k8s-worker-01`'s OS disk is at 79%, 21G free**, and `/models` is a hostPath
  on it shared with agent-fleet's session volumes. Two models is ~5.1GB. It fits;
  it is now worth watching.
- ~~**`session_id` is client-chosen and the bearer token is shared**, so any
  caller can interleave audio into another's session.~~ **Closed 2026-09-01.**
  Tokens went per-client in 0.6.0 and both consumers turned out to be backend
  proxies that mint the `session_id` server-side from their own authenticated
  user — so the browser never picks one. See the reconciliation entry below.
- **`Cargo.lock` is still not committed**, so builds are not reproducible.
- Parakeet EOU 120M (160ms chunks, ~0.2s) remains the lower-latency option if
  0.6s ever proves too slow — at the cost of English-only and no punctuation.

---

## Streaming felt slower than the 4s chunks it replaced, 2026-08-31

The operator's report, and it was correct. Two latency bugs plus a third found by
reviewing the fix for the first two. `ukubi-stt` 0.5.2.

### First, a measurement I got wrong

I reported streaming RTT as **230-320ms**. That was an artefact of a Python test
client opening a **fresh TLS connection per chunk**. Measured over one persistent
HTTP/2 connection, which is what a browser actually uses:

| | |
|---|---|
| RTT | **84-102ms** |
| decode | 24-27ms |

The network was never the problem. Worth remembering when timing anything that a
browser will do over a reused connection — a naive client-per-request harness
adds a full handshake to every sample and quietly triples the number.

### Bug 1 — chunks were 768ms, and misaligned

`flush()` sent the **whole** client buffer. The audio callback delivers a fixed
block at a time, so the buffer crossed the 8960-sample threshold at 12288 and
shipped **768ms** per request instead of 560ms.

Worse, 12288 is not a multiple of the encoder's 8960: the server decoded one
chunk and **held a 3328-sample remainder until the next request arrived**. Some
audio waited an entire extra round for nothing.

```
before:  768ms fill + up to 560ms remainder-wait + 90ms RTT  ~= 1.4s, irregular
after:   560ms fill + up to 128ms jitter        + 90ms RTT  ~= 650-780ms, smooth
```

`flushChunk()` now takes exactly one encoder chunk and keeps the remainder,
drained in a loop. The callback block dropped 4096 -> 2048 frames to halve the
jitter on the boundary. Verified by replaying the buffer arithmetic over 200
callbacks: 45 chunks, all exactly 8960, no loss and no reorder.

### Bug 2 — a cold pod put the first ~6 seconds behind

The streaming model loaded on first use, so a cold pod made chunk 1 take ~5s. And
because chunks arrive every 560ms while a 5s backlog drains at ~470ms per chunk,
**the first several seconds of every session ran badly behind** before catching
up. Measured: chunk 1 rtt 5543ms cold, 365ms warm.

It now warms in a **background task** at startup. ADR-0046 Decision 2 made it
lazy because "~6.8GB of an 8GB card" was an *estimate* and, under `Recreate`, a
pod that cannot start is an outage of the working batch service. That is now
measured at 6866-6880 MiB, so the unknown the hedge protected against is gone —
and warming in the background rather than before `serve()` keeps the good half
regardless: the listener is already up, so a failed load costs streaming a
`FAILED_PRECONDITION` and costs batch nothing.

### Bug 3 — found reviewing the fix, not running it

`flushTail()` sends whatever is left when recording stops, which can be **zero
samples**: the buffer lands exactly empty on **1 callback in 35** (measured), and
on every Stop pressed before speaking. The server rejected empty audio *before*
looking at `last`, so that close failed with `INVALID_ARGUMENT` — the recognizer
leaked until the 120s idle sweep and **the tail was never flushed**. That is the
bug fixed an hour earlier, arriving by a different path.

`last` means "flush and release", so an empty one is now accepted; the existing
silence padding turns it into exactly the flush that was wanted. Proven live:

```
one real chunk, then a bare close with zero audio
  chunk -> OK text=''
  close -> OK text=' The quick'      <- the tail, which used to be lost
empty audio WITHOUT last  -> INVALID_ARGUMENT   (still rejected)
offline empty audio       -> INVALID_ARGUMENT   (still rejected)
```

### What this cost, and the lesson

Three latency bugs in code that compiled, passed clippy, passed its unit tests,
and demonstrably worked. None were visible by reading — the client arithmetic
looks right until you replay it, the cold-start cliff only exists on a fresh pod,
and the bare close only happens 1 time in 35.

**The operator noticing "it feels slower" was worth more than any of the tests.**
Perceived latency is a property of the whole chain, and the chain had no test.

---

## Consumable by other services, 2026-09-01 — `ukubi-stt` 0.6.0

Two additions, both aimed at "another service can actually use this".

**gRPC reflection**, so a caller needs no vendored `.proto`:

```
$ grpcurl -plaintext ukubi-stt:9090 list
grpc.reflection.v1.ServerReflection
stt.v1.Stt
```

Registered **unauthenticated**, which is deliberate and worth understanding
rather than trusting: the IngressRoute matches `PathPrefix(/stt.v1.Stt/)` while
reflection answers on `/grpc.reflection.v1.*`, so Traefik 404s it and only the
pod network can reach it. **That was a reasoned claim, so it was tested before
being believed** — externally `grpcurl stt.bnei.dev:443 list` returns "server
does not support the reflection API" while the RPC itself still works. Both v1
and v1alpha are served, because clients disagree about which they ask for and
serving one looks fine until someone else's tooling fails.

**Per-client bearer tokens.** ADR-0044 Decision 5 specified one shared token,
which was right when the callers were a browser and the owner's machines. Other
services calling it changes the arithmetic: one secret means **revoking any
caller revokes all of them** — and it is why ADR-0046 had to accept that a caller
can interleave audio into another's `session_id`, since the id was the only thing
separating callers holding identical credentials.

Credentials are now `STT_TOKEN_<NAME>`, one per caller, with `STT_AUTH_TOKEN`
still accepted as `default`. `common-app-chart`'s `infisical` block passes the
whole project as env vars, so **adding a caller is adding a secret and revoking
one is deleting it** — no redeploy, no code change. The matched name rides on the
request and is logged, so "who is calling this" is answerable.

The comparison loop deliberately does not exit on first match; stopping early
would make response time depend on *which* client is calling.

### `docs/secrets.md` is now stale, and that is a real problem

It documents a single `STT_AUTH_TOKEN` and contains **zero** occurrences of
`STT_TOKEN_`. `docs/stt-log.md` above still lists "the bearer token is shared" as
open. Both predate 0.6.0. **They must be corrected in the same change as the
first consumer wiring**, or `mission-drift` flags it and ADR-0046's
session-hijack caveat reads as open when it is mitigated.

**Done 2026-09-01**, alongside the agent-fleet wiring. `docs/secrets.md`'s
ukubi-stt row now lists the per-client tokens by name, ADR-0044 Decision 5
carries an amendment recording why one shared token stopped being acceptable at
two consumers, and ADR-0046's caveat is marked resolved rather than left to be
re-read as open. Worth noting *how* it resolved: the caveat predicted per-client
tokens would make the hijack a real problem, and the opposite happened — because
both consumers landed as backend proxies rather than browser clients, which was
not the shape assumed when the caveat was written. The prediction was right about
the mechanism and wrong about the architecture.

The secrets row also now records that `STT_TOKEN_FLEET` is **duplicated** into
`agent-fleet-nygh` rather than read cross-project. An `InfisicalSecret` syncs a
whole project env, so pointing fleet's identity at `ukubi-stt-bhr-m` would have
put `REGISTRY_PASSWORD` into its namespace — the same mistake made and reverted
for dream-analyst a few days earlier. Two copies to rotate is the accepted cost.

---

## A latency diagnosis I got wrong, 2026-09-01

Recorded because the wrong answer was plausible, published, and committed.

Chasing streaming latency turned up ~50ms per request that had nothing to do with
the service:

```
LAN VIP  (192.168.1.233)  ->  4.8 ms
WAN IP   (82.65.231.50)   -> 54.4 ms
```

I called it **Freebox hairpin NAT** — LAN traffic leaving and coming back — and
wrote that into a playbook comment, a commit message and a PR body (#231). It was
wrong, and the evidence was available before I wrote it:

```
route -n get 192.168.1.233  -> interface: en0     (direct LAN)
route -n get 82.65.231.50   -> interface: utun22  (VPN tunnel)
external IP                 -> 212.102.36.233, loc=CH
```

The measuring workstation was on a **VPN with a Swiss exit**, so the ~50ms was a
round trip to Switzerland — about right for that hop. I saw a large number,
reached for the plausible LAN explanation, and never checked the routing table.
Corrected in #232.

**The fix did not change**, because both failure modes have one cause: resolving
a LAN-reachable service to its public address. `stt.bnei.dev` now has a
split-horizon record on the Pi (`192.168.1.233`), scoped to that host only — safe
precisely because it is grey-cloud, so pointing LAN clients at the origin bypasses
nothing that exists. Verified that `fleet` (grey) and `wedding` (proxied) are both
unshadowed.

**But the corollary matters more than the fix:** a VPN'd client sends DNS to the
VPN's resolvers, so it never asks the Pi and this record cannot help it at all.
That needs split-DNS on the VPN, not a DHCP change — and my "point LAN DHCP at
the Pi" advice, while right in general, was useless for the machine I gave it to.

---

## How consumers will use this, 2026-09-01

Planned for `agent-fleet` and `dream-analyst`. Two facts from reading them
reshaped the design away from what seemed obvious:

- **Neither browser can call `stt.bnei.dev` directly.** agent-fleet's `core`
  never allows CORS and its `__Host-fleet_session` cookie is `SameSite=Lax`.
  dream-analyst has its own JWT cookie and its own non-authentik users.
- **Both apps are already backend-proxy shaped.** dream-analyst already
  transcribes through a server route that checks `locals.user` first. The
  architecture the design wanted was already built, pointed at a different
  backend.

So: **no browser ever holds an STT credential.** Each backend holds its own
`STT_TOKEN_<APP>` and dials
`ukubi-stt.ukubi-stt.svc.cluster.local:9090` over plaintext h2c — which means the
entire gRPC-Web edge, the hand-written `grpcWeb`/CORS middlewares and the Traefik
idle-close finding are all **irrelevant to consumers**. They exist for browsers
talking to `stt` directly, which now nothing does.

Three properties fall out: no CORS anywhere, no credential in any browser, and
**the session id stops being client-chosen** — the backend mints it per
authenticated user, which closes ADR-0046's interleaving caveat for these callers.

**authentik is still the gate for agent-fleet, indirectly.** The browser is
authenticated to `core` by an authentik-derived session; `core` then calls STT
with its own service credential. No forwardAuth on `stt` is needed, and
ADR-0044 Decision 5's rejection of it stays intact rather than being reversed.

---

## The doubt pass found two live bugs, 2026-09-01

The consumer plan was run through an adversarial review before implementation.
It found two defects **in already-deployed code**, neither of which any test or
demo would have surfaced.

### 1. A close could leak the session slot it was freeing

`decode_chunk` called `self.session()` *before* looking at `last`:

```
let recognizer = self.session(session_id, &handle, language)?;   // can return RESOURCE_EXHAUSTED
...
if last { map.remove(session_id); }
```

So a close for an already-swept session **created a recognizer purely to delete
it**. Harmless with capacity; with the cap full the create is *refused*, the close
fails, and the slot it was freeing leaks — so **a full cap stays full**, every
subsequent close hitting the same wall.

Invisible with one operator and one browser. Reachable the moment two consumers
share the 8-session pool, which is exactly what the plan proposes. Fixed in
`ukubi-stt` #12: `session()` takes `create` and returns `Option`.

The guard is `last && samples.is_empty()`, **not** `last` — a recording shorter
than one 560ms chunk sends exactly one request with `last` set, and refusing to
create there would lose the whole utterance. Same class as 0.5.1's tail bug.

### 2. dream-analyst had an unauthenticated transcription endpoint

`transcribeAudio` in `front/src/lib/remote/audio.remote.ts` had **no auth check
of any kind**, while the route it was written to replace does. A SvelteKit
`command` compiles to an addressable POST endpoint, reachable whether or not any
component imports it — and nothing imports this one. Audio transcription, and the
n8n spend behind it, were open to anyone who found the route on a public host.

Fixed in dream-analyst #12 with the same `getCurrentUser()` helper
`dream.remote.ts` uses. A guard rather than a deletion: `main` is 8 commits behind
an active local branch that may add a caller, so *authenticated* is correct either
way while *deleted* is only correct if that branch agrees.

**The plan would have wired this endpoint to a GPU.**

### What the review got wrong, and a pattern worth naming

Three separate agents claimed dream-analyst's `helm/values.yaml` does not exist on
`main`, and two claimed `/api/transcribe` does not exist. **All of it false** —
verified against `origin/main` via the GitHub API, with ArgoCD `Synced`/`Healthy`
against `$values/helm/values.yaml`. Every one of them read the local clone, which
is mid-merge-conflict and `[ahead 21, behind 8]`.

The lesson is not "agents are unreliable" — their substantive findings were
excellent and two of them were live bugs. It is that **a stale working tree
produces confident, specific, wrong claims**, and the cheap defence is to verify
any file-existence claim against the remote before planning on it.

### Amendments the review forced into the plan

- **Add both consumer tokens in one go.** Each Infisical addition triggers
  `autoReload` -> `Recreate` -> a two-model CUDA reload that destroys live
  sessions. Adding them one at a time kills the first consumer's users mid-
  dictation when the second lands.
- **Reject an empty computed `session_id` loudly.** `FLEET_AUTH_DISABLED=1`
  yields an empty identity, hence an empty id, which the server routes to the
  *batch* model behind `Semaphore(1)`: a garbage transcript, then
  `RESOURCE_EXHAUSTED` on the second chunk.
- **HMAC the session id, do not plain-hash it.** The client controls one input.
- **Extracting the capture module needs care.** The page is `include_str!`'d and
  the IngressRoute matches `Path(/)` *exactly*, so a `<script src=...>` would
  404. Either a third route, or ukubi-stt keeps an inline copy.

---

## First consumer live, 2026-09-01 — dream-analyst dictates to the GPU

`dream-analyst` 0.31.2 streams dictation to `ukubi-stt`, replacing an external
n8n webhook. Confirmed working by the operator, and from the service side:

```
recognize audio_seconds=0.56 decode=0.023 rtf=0.041 chars=8 streaming=true client="dreamer"
recognize audio_seconds=0.40 ...                                          <- the tail chunk
streaming session opened 12:08:49 -> closed 12:09:01
```

Each field confirms a different piece, which is why the log line carries them:

- `client="dreamer"` — the per-client token works and is attributed, so revoking
  one consumer would not touch the other.
- `audio_seconds=0.56` **exactly** — the capture module chunks correctly in a
  real browser, not only in the replay harness.
- the final `0.40s` chunk — the partial tail flushing via `last`. That is the
  0.5.1 bug (every utterance silently losing its ending) working for real.
- session **closed**, not swept — no leaked slot.

Shape: the browser holds no STT credential. It authenticates to dream-analyst
with its own cookie; the server calls STT with the app's token. No CORS anywhere,
and the session id is HMAC-derived server-side so one user cannot join another's
recognizer.

### Two bugs on the way in, both mine

**`JWT_SECRET is not set; cannot derive a session id`** — every transcription
500'd. I keyed the session HMAC on `JWT_SECRET` assuming it was configured, and
had *listed that project's secrets earlier in the same session* without noticing
it was absent. Re-keyed on the STT token, which makes the feature
self-contained: the secret that authorises the call derives the id, so it cannot
be half-configured. Verified in a pod with no `JWT_SECRET`, the exact failing
condition.

**A module-scope `throw` broke the image build.** Requiring `JWT_SECRET` at
import also fires during `vite build`, which evaluates server modules — so the
first attempt at hardening failed CI rather than the insecure default. The check
moved to the use sites, and in `verifyToken` it sits *outside* the `try`: inside,
a missing secret is caught and returned as `null`, indistinguishable from an
invalid token, so a misconfigured deploy would look like every session quietly
expiring.

### The serious finding, which was not mine

`front/src/lib/server/auth.ts` read:

```ts
const JWT_SECRET = env.JWT_SECRET || 'your_jwt_secret_here';
```

and `JWT_SECRET` was **not set on the deployment**. So production session cookies
were signed with a placeholder published in a public repository — anyone reading
that line could forge an `auth_token` for any user.

**The fallback is what hid it.** The app booted, logins worked, nothing anywhere
reported that the signing key was public. It surfaced only because unrelated code
hard-required the variable and crashed. A real secret is now set (users were
logged out, unavoidable when rotating a key that was public) and the fallback is
gone.

Worth generalising: a default that lets a security-critical value go unset does
not make the system tolerant, it makes the failure silent. The same shape exists
anywhere else `env.X || 'placeholder'` appears.

### Secret topology, and its cost

`STT_TOKEN_DREAMER` exists in **both** `ukubi-stt-bhr-m` and
`dream-analyst-8-fxf`, chosen over a cross-project read for simpler wiring.
Rotating it means editing **both**; change one and dictation fails
`UNAUTHENTICATED` -> 503, which reads like the GPU node being down rather than a
secret mismatch. Recorded next to the `infisical:` block in that repo, where
someone rotating it will actually be looking.

**A finding from the road not taken, kept because it generalises:** an
`InfisicalSecret` without `secretsScope.secretName` syncs the **whole project**.
Applying one to test put `REGISTRY_PASSWORD` — push rights on the registry every
node pulls from — into the consuming namespace. Anyone reaching for a
cross-project read later needs that field.

n8n secrets (`N8N_AUDIO_TRANSCRIBE_URL`, `N8N_AUTH`, `N8N_WEBHOOK_URL`) deleted
after confirmation, not before — they were the rollback. Note `infisical secrets
delete` defaults to `--type personal` and silently no-ops on shared secrets.

### Also shipped

`ukubi-stt` 0.7.0: `STT_MAX_SESSIONS` env-configurable, and `web/stt-capture.js`
extracted and served at an exactly-matched route so the page and consumers share
one copy. `/healthz` verified still unrouted afterwards — adding a second route
was the risk, and `Path()` rather than `PathPrefix()` is what contains it.

Remaining: agent-fleet.

---

## agent-fleet, and what shipping to a second consumer actually cost — 2026-09-01

The remaining item above. It landed, but the STT work was the small half of the
day: two of the three bugs were in the *consumer's* UI, and the thing that
blocked the deploy for an hour had nothing to do with speech at all.

### The wiring

`core` proxies. The dashboard cannot call `stt.bnei.dev` itself — core allows no
CORS and `__Host-fleet_session` is `SameSite=Lax`, so a cross-origin call carries
no identity — and handing the browser an STT bearer token to work around that
would give every dashboard user a credential for the GPU. So core holds
`STT_TOKEN_FLEET` and derives the recognizer id by HMAC over the authenticated
identity. Same shape as dream-analyst, arrived at for the same reason.

Chunked unary, not server-streaming: the browser cannot stream *up* under any
transport gRPC offers, so audio arrives as discrete requests regardless, and each
chunk's text comes back in its own response. A server stream would add lifecycle,
reconnect machinery and a cursor to deliver one message per request already made.

The stream id is per **dictation**, not per fleet session — a fleet session is a
conversation, an STT session is a recognizer lifecycle swept after 120s idle, and
two tabs can dictate into one conversation.

The proto is vendored under `core/` with its own buf module listing **Go plugins
only**. `proto/buf.gen.yaml` runs `protoc-gen-es` over the whole module into
`dashboard/src/gen`, so dropping `stt.proto` there would have emitted a
`stt_pb.ts` nothing imports — the dead generated code ADR-0048 deleted 8,692
lines of. Worth stating as a general rule: in a repo with a module-wide codegen
config, adding a proto is not a local decision.

### The token, and why it is a second copy

`STT_TOKEN_FLEET` was created in `agent-fleet-nygh`
(`ae771c2c-5115-452a-8f1c-1e03fa0e2b9a`) by copying the value out of the running
`ukubi-stt-infisical` Secret rather than out of Infisical — the CLI has no
project-listing command and `secrets get` needs a project id that was not to
hand, while the cluster already held the value under a name that identified it.

It is duplicated rather than read cross-project for the reason recorded a few
days earlier: an `InfisicalSecret` syncs a whole project env, so pointing fleet
at `ukubi-stt-bhr-m` would have put `REGISTRY_PASSWORD` in its namespace. Two
copies to rotate is the accepted cost. The operator picked the new key up with no
intervention.

### The deploy was blocked by something unrelated, and had been for five days

Merging to `main` shipped nothing. Chasing it:

- `Release It` fails at checkout — `fatal: could not read Username for
  'https://github.com'`. `secrets.PAT` is expired. No tag is cut, so **nothing
  downstream ever fires**.
- Before that, the 4.13.0 tag build failed on buildah (exit 125), so **#241's
  session-retention work had never deployed either**. The cluster had been
  running 4.12.1 from 2026-08-25 while `main` moved on.

Neither was visible from the repo: `main` looked healthy, PR checks were green,
and the only symptom was a running image that quietly stopped advancing. **A
green PR does not mean a shipped change**, and nothing was watching the gap
between the two.

Released by running `release-it` locally instead. It is configured
`github.release: false`, so it only commits, tags and pushes — the tag then
triggers the normal build, and the deploy job bumps the manifest with the
built-in `GITHUB_TOKEN`, which is unaffected. Three releases went out this way
(4.14.0, .1, .2). **The PAT is still expired**; until it is rotated, every
release needs that manual step.

One trap: `release-it --dry-run` executes `npm version` for real, leaving
`package.json` dirty so the next run refuses on "working dir must be clean". The
CI workflow's `git reset --hard` prefix exists for exactly this.

### Two UI bugs, both about time, neither in the audio path

**Dictation overwrote itself.** `onText={(t) => onChange(value + t)}` captured
`value` from the render that started the recording, and MicButton's send loop
holds the callback it was constructed with — so every chunk computed
`staleValue + chunk` and each one visibly replaced the last.

Fixed with a functional update, `onChange((prev) => prev + t)`, **not** the more
common latest-callback ref. The ref fixes the stale render but not two chunks
landing in the same tick, which `stop()` does when it flushes the tail right
after a regular chunk — both closures would read the same `value` and the second
would still clobber the first. The functional update removes the read entirely.

**The first words were never captured.** The click did four things in series
before any audio existed: fetch the code-split module, construct an
`AudioContext`, compile the worklet, then open the device. And `getUserMedia` —
the slow one at 100-300ms — was queued *behind* `addModule()`, which it has no
dependency on.

Fixed upstream in `ukubi-stt` (`prewarm()` plus starting `getUserMedia` before
awaiting the context work) and re-vendored, because that file is owned upstream
and two consumers copy it.

Three things worth keeping from it:

- Prewarming is safe **only** because building a context and compiling a worklet
  touch no device. That is what makes it legitimate on hover, before the user has
  committed to anything.
- A context built outside a user gesture starts **suspended**, and a suspended
  context runs no worklet. A naive prewarm would look live and record pure
  silence — a worse failure than the original, because nothing errors. `start()`
  resumes it, which is allowed because the click is what reached it.
- A failed warm must not be memoised, or the button is dead until reload.

The remaining delay is `getUserMedia` alone, and it is not removable without
holding the microphone open on a page the user has not asked to record on. So the
other half of the fix is honesty: the button now reads as *arming* and is
disabled until audio is genuinely being captured. **Silence about the gap was
half the bug** — warming shrinks it, showing it stops it costing a sentence.

### A correction: ArgoCD was never the problem

Two rollouts were reported here as needing a manual hard refresh, with a webhook
proposed as the fix. Both claims were wrong, and were caught only because the
operator said "don't hard refresh yet, and check whether the PAT affects ArgoCD".

- `argocd-cm` sets `timeout.reconciliation: 120s`. Both refreshes were inside
  that window — the observation was impatience, not a fault. Left alone, 4.14.2
  was `Synced/Healthy` before the first sample.
- ArgoCD does not use the PAT at all. There is exactly one repository secret in
  `argocd`: an **SSH deploy key** for `infra-bootstrap`. `agent-fleet` is reached
  **anonymously over HTTPS** because the repo is public. Nothing there can
  expire.

The generalisable part is the failure mode, not the facts: an intervention that
is followed by success reads as the cause of it. Both hard refreshes "worked",
which is precisely why the wrong explanation survived twice. Reaching for the
fix before establishing the baseline is what made it unfalsifiable — a
diagnosis that cannot fail to be confirmed is not a diagnosis.

### Open

- **`secrets.PAT` on `agent-fleet` is expired.** Every release needs a local
  `release-it` until it is rotated (fine-grained, `contents: write`).
- **`ukubi-stt`'s own image has not been rebuilt** since `prewarm()` merged, so
  the test page at `stt.bnei.dev` still serves the pre-fix module.
- **dream-analyst's vendored copy is stale** and carries the same cold start.
- No regression test for either UI bug: the dashboard has no jsdom/happy-dom
  (`Markdown.test.tsx` says so explicitly) and both bugs need two callbacks with
  no re-render between them. Flagged rather than hidden.
