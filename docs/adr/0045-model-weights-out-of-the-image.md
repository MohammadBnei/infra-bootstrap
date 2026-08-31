# ADR-0045: Model weights on node-local storage; CUDA libraries stay in the image

**Status:** Accepted — decided 2026-08-31, immediately after Gate 0 passed.
**Date:** 2026-08-31
**Related:** [ADR-0044](0044-stt-grpc-service.md) (the service whose image this
is), [ADR-0043](0043-gpu-node-enablement.md) (the single GPU node this pins
to), [ADR-0034](0034-in-cluster-oci-registry-zot-garage-backed.md) (the
registry and build-runner whose costs this is paying), [ADR-0036](0036-nfs-storage-class-for-k8s.md)
(the `nfs` class considered and rejected here), [ADR-0002](0002-storage-longhorn-over-ceph-nfs.md)
(why `longhorn` is the default and why that is wrong for this data)

## Context

`ukubi-stt:0.1.3` was **5.85 GB**: a `nvidia/cuda:*-cudnn-runtime` base at
3.26 GB, ~2.4 GB of Parakeet TDT weights, and a 31 MB binary. That size has
already been paid for three times, and none of them were hypothetical:

- **zot's undocumented 60s `readTimeout`** (#221) — a 2.4 GB blob push against
  a default nobody had read.
- **Registry retention cut to 2 tags for this repo alone** (#219), against 3
  everywhere else, purely because of image size.
- **21 GB pruned off the build-runner** on 2026-08-31 to make room for the CUDA
  13 bases. That box is a 40 GB rootfs on a thin pool shared with three other
  build repos.

Underneath the cost is a coupling problem. The weights are a ~2.4 GB immutable
third-party artifact that changes when *upstream publishes a new model*. The
binary is 31 MB and changes when *we write code*. Shipping them as one layer
stack means every code change re-downloads and re-pushes the weights, and
ADR-0044's Phase E adds a **second** model for streaming.

The enabling observation, and the reason node-local storage is even on the
table: ADR-0044 pins this service to `k8s-worker-01`, single replica, no HA,
GPU downtime explicitly accepted. There is exactly one node this can ever run
on. Node-local storage loses nothing that was promised.

## Decision

### 1. Model weights move to a `local-path` PVC, fetched only when absent

Not `longhorn`, which is the cluster default: three replicas of a
re-downloadable third-party file is 7.2 GB of replicated storage protecting
data whose recovery procedure is `curl`. Not `nfs` either — it is
policy-legal (ADR-0036 names "regenerable bulk data" as exactly its case) but
it makes `nfs-storage.bnei.lan` a *startup* dependency and reads 2.4 GB over
the network on every pod start, for a workload that already cannot survive
losing its own node.

`local-path` is a node-pinned hostPath RWO volume on a workload that is itself
node-pinned. The match is exact and it costs nothing.

**The PVC is a cache, not a dependency.** An init container tests for the
weight file and fetches from HuggingFace only if it is missing. A node rebuild
therefore costs one 2.4 GB fetch, not a broken deployment.

Two details that are easy to get wrong and expensive to get wrong:

- **Test for the weight file, not the directory.** A `mkdir` that outran a
  failed download leaves a directory that exists and a model that does not,
  and the pod then starts and fails at session creation instead of re-fetching.
- **The init container is our own image**, which already carries `curl` and
  `ca-certificates` and is already on the node. A separate `curlimages/curl`
  would be one more upstream dependency and one more pull for no gain.

### 2. CUDA libraries stay in the image, and that is not a size oversight

`libonnxruntime_providers_cuda.so` requires an exact soname set —
`libcudart.so.13`, `libcublas.so.13`, `libcublasLt.so.13`, `libcurand.so.10`,
plus `libcudnn.so.9` and `libcufft.so.12` dlopened lazily by name. **We did not
choose that set. pyke did**, when they built the ONNX Runtime that `ort-sys`
downloads, and they will change it without asking — `dist.tsv` already has a
`cuda13` row where a `cuda12` row never existed.

While those libraries are in the image, the requirement and the thing that
satisfies it ship as one atomic artifact. Moving them to the node splits that
into two independent lifecycles — a `Cargo.lock` in `MohammadBnei/ukubi-stt`
and an apt package in a playbook in *this* repo — with no CI anywhere able to
check that they still agree. That is the same failure class that cost a day on
2026-08-31, relocated from build time to runtime, where it is strictly harder
to see.

`libcuda.so.1` is the one library that correctly comes from outside the image,
and it already does: the container toolkit injects it from the host driver.
That is the boundary, and it is already in the right place.

**Revisit trigger, named so it is not re-argued from scratch:** a *second* GPU
workload on this node. At that point two images carry an identical 3.3 GB CUDA
stack and the amortisation argument becomes real rather than a size complaint.
It is not real with one.

### 3. Dropping cuDNN was tested and rejected — by measurement

`-cudnn-runtime` → `-runtime` looked like ~1.5–2 GB for a one-word change,
justified by `libonnxruntime_providers_cuda.so` having no `DT_NEEDED` entry for
cuDNN. Gate 0's own run settles it:

```
INFO ort::logging: cuDNN version: 91400
```

It is dlopened and used. The `-cudnn-` variant stays. Recorded because the
reasoning that made it look free — "it is not in `DT_NEEDED`" — is correct and
still leads to the wrong answer, and someone will have it again.

### 4. The *builder* does not need CUDA at all

`nvidia/cuda:13.0.3-cudnn-devel` is **8.23 GB** on a 40 GB build-runner shared
with three other repos, and nothing in the compile touches CUDA: `ort-sys`
downloads a prebuilt ONNX Runtime, links `libonnxruntime.a` statically, and the
CUDA provider is dlopened rather than linked. No `nvcc`, no CUDA headers.

The builder becomes plain `ubuntu:24.04` — same distro as the runtime, so the
glibc rule that forced 24.04 in the first place still holds. This is the single
largest build-runner win available, larger than anything in Decisions 1–3, and
its risk profile is inverted from theirs: a wrong guess here is a loud compile
error, never a silent CPU fallback.

The Dockerfile's original comment hedged — *"ort's `cuda` feature **may** want
CUDA headers present at build time"* — which was an assumption, never tested.

## Consequences

- **Image: 5.85 GB → ~3.4 GB. Build-runner: ~8 GB reclaimed** on top of that,
  from the builder base. Registry retention for this repo can go back to 3 tags
  if wanted; left at 2 until there is a reason to change it.
- **`ukubi-stt:<tag>` is no longer a standalone artifact.** It needs either a
  populated PVC or a reachable HuggingFace. This is a real loss — it is the
  property that made the 2026-08-31 diagnosis possible, since inspecting the
  image was enough to prove what was *not* in it. Accepted for the weights,
  explicitly refused for the CUDA libraries (Decision 2).
- **Cold start after a node rebuild pulls 2.4 GB from the internet**, in a
  service whose whole point is running locally. Ordinary restarts do not — the
  hostPath outlives them. The failure is loud (init container fails, pod does
  not start) rather than silent.
- **`common-app-chart` needs an `initContainers` value.** It has `persistence`
  and `extraVolumes`/`extraVolumeMounts` but no init containers at all. Adding
  it there rather than reaching for a per-app chart is the only option the
  locked decisions allow, and it is the right one — any future model-backed
  workload needs the same hook.
- **`local-path` shares `k8s-worker-01`'s OS disk with agent-fleet's session
  volumes** (`SESSION_STORAGE_CLASS`, per that node's `host_vars`). ~2.4 GB
  today against ~85 GB allocatable is comfortable; Phase E's second model makes
  it ~5 GB. Worth re-checking then, not now.
- **Nothing here is backed up, deliberately.** The weights are re-fetchable and
  the PVC is a cache. There is no restore path because none is wanted.

## Alternatives considered

| Option | Why rejected |
|---|---|
| Everything in the image (status quo) | Couples a 2.4 GB immutable artifact to a 31 MB binary that changes daily; Phase E doubles the weight payload |
| Weights on `longhorn` | 3x replication of data whose recovery procedure is `curl`; Longhorn is already under memory pressure on the control-plane nodes |
| Weights on `nfs` | Policy-legal per ADR-0036, but makes `nfs-storage.bnei.lan` a startup dependency and reads 2.4 GB over the network at every pod start |
| Weights in a separate image, used as an init container | Removes the internet dependency and versions the weights in the registry, but doubles registry storage for them and adds a moving part |
| CUDA libraries on the node too | ~150 MB image, but splits an ABI contract across two repos with no CI able to check it — see Decision 2 |
| Drop `-cudnn-` from the runtime base | Rejected by measurement: `cuDNN version: 91400` in Gate 0's log — see Decision 3 |

## Out of scope

Moving the CUDA libraries (trigger named in Decision 2). Whether `local-path`
still fits once Phase E's streaming model lands. Backing up the weights.
ADR-0044's Decisions 2–6 — transport, auth, ingress — are untouched by this.
