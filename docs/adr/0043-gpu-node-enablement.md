# ADR-0043: GPU node enablement — driver, container runtime, device plugin

**Status:** Proposed

## Context

`ARCHITECTURE.md` §2 has claimed since the cluster was designed that
`k8s-worker-01` runs "NVIDIA driver + container toolkit inside the VM;
NVIDIA Device Plugin via Helm; GPU workloads scheduled via
taints/tolerations" (`ARCHITECTURE.md:151-156`), and
`inventory/ukubi/README.md:49` claims `nvidia_accelerator_enabled: true`
and `nvidia_gpu_nodes` are set by the initial `cluster.yml` run.

Investigating how to place a GPU workload on the cluster found that none
of that is true:

- `inventory/ukubi/group_vars/k8s_cluster/k8s-cluster.yml:53-54` sets
  `nvidia_accelerator_enabled: **false**`, with the comment "No GPU on test
  VMs — re-enable when k8s-worker-gpu is added". There is no
  `nvidia_gpu_nodes` key anywhere in `inventory/ukubi/`. The only
  device-plugin references in the repo are in the unused legacy
  `inventory/mycluster/group_vars/k8s_cluster/k8s-cluster.yml:317-331`,
  which name `registry.k8s.io/nvidia-gpu-device-plugin` and a
  driver-installer container — a GKE-era pattern.
- There is **no** NVIDIA device plugin, gpu-operator, `RuntimeClass`, or
  `nvidia.com/gpu` resource request anywhere in `gitops/`. No chart
  template references `runtimeClassName`.
- There is **no** GPU-related task in `ansible/playbooks/`. Nothing in this
  repo installs the NVIDIA driver or `nvidia-container-toolkit` into the
  VM.

So the hypervisor half is real and done — RTX 2070 SUPER at PCI `0b:00`,
all four functions bound to `vfio-pci`, IOMMU group 2, re-enforced each
boot by `vfio-pci-bind-gpu.service`, PVE PCI Resource Mapping named `gpu`,
and `terraform/k8s-vms.tf:25-45,128-133` attaching it to `k8s-worker-01`
via `dynamic "hostpci"` — while the Kubernetes half does not exist. **No
pod can request a GPU today.**

Two further complications found while scoping the fix:

1. **The passthrough itself is unprovable from this repo.**
   `terraform/*.tfstate` is gitignored (`.gitignore:36-37`) and no state
   file is committed. `docs/infrastructure-actual.md:135-138` (2026-07-14)
   says the `hostpci` block is "not yet merged/applied" and the GPU is "not
   yet attached to any VM", while `:185`, `:220` and `:244` (2026-07-30)
   describe `k8s-worker-01` as running with the passthrough. The repo
   contradicts itself and cannot settle it.
2. **`k8s-worker-01` is the tightest node in the cluster** — 94% of
   allocatable CPU requested, per ADR-0037, which is itself still
   Proposed. Any scheduling change here interacts with that.

## Decision

Enable GPU scheduling in three parts, and **do not** take the two shortcuts
that look cheaper.

### 1. Driver and container toolkit via a new ansible playbook

`ansible/playbooks/gpu-node-configure.yml`, `hosts: k8s-worker-01`.
Installs the NVIDIA driver and `nvidia-container-toolkit` from NVIDIA's apt
repository, enables `nvidia-persistenced`, and reboots the node once.

`nvidia-persistenced` is not optional polish: without it the driver
unloads whenever no process holds the device, so every cold inference pays
a full driver re-initialisation.

The reboot is safe unattended because `ansible/playbooks/self-drain-configure.yml`
already installed `drain-self.service`/`uncordon-self.service` on this
node — it cordons and evicts itself on graceful shutdown and uncordons on
rejoin.

### 2. containerd runtime declared in kubespray inventory, as a NON-default runtime

A new `inventory/ukubi/host_vars/k8s-worker-01.yml`:

```yaml
containerd_additional_runtimes:
  - name: nvidia
    type: "io.containerd.runc.v2"
    options:
      BinaryName: /usr/bin/nvidia-container-runtime
      SystemdCgroup: true
```

Two things this deliberately avoids:

- **Not `nvidia-ctk runtime configure`.** That command edits
  `/etc/containerd/config.toml`, which kubespray owns and rewrites on the
  next `cluster.yml` run. The GPU would silently stop working at the next
  unrelated cluster operation — a failure that would present months later
  as "GPU pods broke and nobody touched them".
- **Not `containerd_default_runtime: nvidia`.** See Decision 3.

`SystemdCgroup: true` is explicit because `config.toml.j2` renders
`runtime.options` verbatim and injects nothing; kubespray's own
`containerd_runc_runtime` sets it from `containerd_use_systemd_cgroup`.
Omitting it gives that runtime cgroupfs while kubelet uses systemd — a
cgroup-driver mismatch.

Note also that the correct kubespray variable name is
`containerd_default_runtime`, not `containerd_default_runtime_name`; the
latter is silently ignored, which is exactly the kind of no-error failure
this ADR is trying to design out.

### 3. Per-pod selection via `RuntimeClass`, NOT a default runtime

Create a `RuntimeClass` named `nvidia` and add a one-line
`runtimeClassName` passthrough to `common-app-chart`'s `deployment.yaml`.

**Making nvidia the node's default runtime would silently reopen ADR-0011.**
`nvidia/cuda:*` base images ship `ENV NVIDIA_VISIBLE_DEVICES=all`, and
`nvidia-container-toolkit` defaults
`accept-nvidia-visible-devices-envvar-when-unprivileged` to true. With
nvidia as the node default, **any** pod scheduled onto `k8s-worker-01` that
happens to use an NVIDIA base image would get the entire GPU injected
*without requesting `nvidia.com/gpu`* — invisible to the scheduler's
resource accounting. That is GPU multi-tenancy by accident, which ADR-0011
explicitly rejected and `DECISION.md:212` lists as forbidden.

The mitigation for that hazard lives in
`/etc/nvidia-container-runtime/config.toml` — a file kubespray does not own
and `nvidia-ctk` does, i.e. precisely the trap Decision 2 exists to avoid.
A `RuntimeClass` sidesteps the whole class of problem: a pod that does not
ask for the nvidia runtime does not get the nvidia runtime.

The counter-argument considered and rejected was that adding
`runtimeClassName` "touches every app in the cluster". It does not — it is
`{{- with .Values.runtimeClassName }}`, inert for every chart consumer that
does not set it, exactly as `.Values.strategy` already is (rendered at
`gitops/platform/common-app-chart/templates/deployment.yaml:18-21`,
undocumented in `values.yaml`).

### 4. Device plugin as a GitOps platform app, not a kubespray addon

An entry in `gitops/bootstrap/platform.applicationset.yaml` plus
`gitops/platform/values/nvidia-device-plugin/values.yaml`, node-selected to
`k8s-worker-01` and using `runtimeClassName: nvidia`.

Chosen over flipping `nvidia_accelerator_enabled: true` for a specific
reason: that variable is a leftover whose only in-repo trace is the
GKE-era `inventory/mycluster/` block, **and the `kubespray/` submodule is
not checked out here** (`git submodule status` reports
`-1c9add48975060f45396b34d8e022c30d7f80dab`), so the role backing it cannot
be read. Building on a variable whose implementation nobody in this repo
can inspect is how the drift in the Context section happened in the first
place. The GitOps route is also adjustable without a `cluster.yml` run,
which matters on a node that reboots for gaming.

The device plugin is a platform app, so it goes in
`platform.applicationset.yaml`, **not** `gitops/apps/registry.yaml` —
that registry is for user apps under GitOps Pattern C (ADR-0004).

### 5. No node taint

`nvidia.com/gpu` is a countable resource, so exactly one pod can hold the
GPU whether or not the node is tainted. A `NoSchedule` taint's only effect
would be keeping non-GPU pods off the node's CPU and RAM.

ADR-0037 records `k8s-worker-01` at 94% requested CPU and is still
undecided. Tainting it would strand 6 vCPU / 15GB and push that load onto
`k8s-worker-02`, trading a capacity incident for tidiness.

Revisit only if a GPU workload is measurably starved by neighbours. If so,
the scheme is `nvidia.com/gpu=present:NoSchedule` plus a matching
toleration through `common-app-chart`'s existing `tolerations` passthrough
— and it must be paired with reducing agent-fleet's worker requests
(ADR-0037's lever 1), or the cluster will not fit.

### 6. Verify the passthrough before installing anything

Because the repo cannot prove the GPU is attached (Context, point 1), the
first step is a check, not an install:

```bash
ssh -i ~/.ssh/id_k8s_vms core@192.168.1.202 'lspci -nn | grep -i nvidia'
```

No device means the `hostpci` apply never landed, and that is separate
work — a terraform apply against `.165`, not a driver install.

## Consequences

- **`ARCHITECTURE.md:148,151-156` and `inventory/ukubi/README.md:49` are
  wrong today and must be corrected** as part of implementing this ADR —
  not silently, and not by this ADR: they are canonical documents, and per
  `DECISION.md` §5 the spec changes first, then the implementation.
  `inventory/ukubi/README.md:10` is separately wrong about
  `k8s-worker-01`'s size (says 4 vCPU / 8GB; `terraform/variables.tf:226-227`
  and `ARCHITECTURE.md:148` say 6 vCPU / 15GB) and should be fixed in the
  same pass.
- **`docs/infrastructure-actual.md` contradicts itself** on whether the GPU
  is attached (`:135-138` vs `:185,:220,:244`) and needs reconciling once
  Decision 6's check has produced a real answer.
- **The `nvidia_accelerator_enabled: false` line and its stale comment stay
  as they are**, but the comment ("re-enable when k8s-worker-gpu is added")
  now names a VM that ADR-0016 retired. Worth a correction so a future
  reader does not go looking for it. `.claude/skills/terraform-ops/SKILL.md:118-121`
  has the same stale name.
- **A negative test becomes part of the verification contract.** Decision 3
  is only worth anything if it is checked: a pod on `k8s-worker-01` with no
  `runtimeClassName` and no `nvidia.com/gpu` limit must **fail** to see the
  GPU. If it succeeds, ADR-0011 has been reopened silently and the runtime
  configuration is wrong.
- **Kubespray must be re-run to apply Decision 2.** Whether
  `--tags container-engine --limit k8s-worker-01` is sufficient, or whether
  a full `cluster.yml` is required, is not yet established. A full run is
  an ingress outage per ADR-0040's consequences, so this needs answering
  before the run, not during it.
- **The driver version is not yet pinned.** `nvidia-driver-570-server` is
  the intended target but its availability on Ubuntu 24.04 has not been
  confirmed; check `apt-cache madison` before writing it into the playbook.
  Any CUDA 12.x consumer needs ≥ 525.60.13.
- **This adds a pod to the cluster's tightest node** while ADR-0037 is
  still open. The two decisions interact and ADR-0037 should be settled
  rather than left to drift further.
- GPU workloads inherit `k8s-worker-01`'s availability, which is
  deliberately poor — `.165` is rebooted for gaming. That is accepted for
  GPU work by design, and is why Decision 1 leans on the existing
  self-drain units rather than adding new lifecycle machinery.
