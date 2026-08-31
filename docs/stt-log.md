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
- **`session_id` is client-chosen and the bearer token is shared**, so any caller
  can interleave audio into another's session. Accepted at this trust boundary
  (ADR-0046) and untenable the moment tokens become per-client.
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
