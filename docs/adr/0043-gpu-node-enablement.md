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

1. **The passthrough was unprovable from this repo — and has since been
   verified on the node.** `terraform/*.tfstate` is gitignored
   (`.gitignore:36-37`) and no state file is committed.
   `docs/infrastructure-actual.md`'s GPU paragraph (written 2026-07-14) said
   the `hostpci` block was "not yet merged/applied" and the GPU "not yet
   attached to any VM", while `:185`, `:220` and `:244` (2026-07-30)
   described `k8s-worker-01` as running with the passthrough. The repo
   contradicted itself and could not settle it, so it was settled against the
   node instead: on **2026-08-31** all four TU104 functions are present in
   the guest at `01:00.0-3` (`10de:1e84`, `10de:10f8`, `10de:1ad8`,
   `10de:1ad9`), with no driver bound. **The apply landed**, the 2026-07-14
   paragraph was the stale half, and it has since been corrected in place.
2. **`k8s-worker-01` was believed to be the tightest node in the cluster** —
   ADR-0037 records 94% of allocatable CPU requested. **That figure no longer
   holds.** Measured on 2026-08-31 the node reports `cpu 3061m (56%)`
   requested against `6600m (122%)` limits. The node is committed but not
   full. ADR-0037 is still Proposed and now also needs re-measuring; this
   ADR does not do that.

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

That is the whole argument, and it does not depend on how full the node is.
ADR-0037's 94%-requested-CPU figure is stale — the node measured 56%
requested (122% limits) on 2026-08-31 — but the conclusion is unchanged:
tainting would strand real capacity and push that load onto
`k8s-worker-02`, buying nothing a countable resource does not already give.

Revisit only if a GPU workload is measurably starved by neighbours. If so,
the scheme is `nvidia.com/gpu=present:NoSchedule` plus a matching
toleration through `common-app-chart`'s existing `tolerations` passthrough
— and it must be paired with reducing agent-fleet's worker requests
(ADR-0037's lever 1), or the cluster will not fit.

### 6. Verify the passthrough before installing anything

Because the repo could not prove the GPU is attached (Context, point 1),
the first step is a check, not an install:

```bash
ssh -i ~/.ssh/id_k8s_vms core@192.168.1.202 'lspci -nn | grep -i nvidia'
```

No device means the `hostpci` apply never landed, and that is separate
work — a terraform apply against `.165`, not a driver install.

**Run 2026-08-31: the device is present.** The check keeps its place as the
playbook's first task regardless — it is still correct on a rebuilt or
re-provisioned node, and installing a driver for absent hardware
"succeeds" while leaving a node that looks configured and schedules
nothing.

## Consequences

- **`ARCHITECTURE.md:148,151-156` and `inventory/ukubi/README.md:49` are
  wrong today and must be corrected** as part of implementing this ADR —
  not silently, and not by this ADR: they are canonical documents, and per
  `DECISION.md` §5 the spec changes first, then the implementation.
  `inventory/ukubi/README.md:10` is separately wrong about
  `k8s-worker-01`'s size (says 4 vCPU / 8GB; `terraform/variables.tf:226-227`
  and `ARCHITECTURE.md:148` say 6 vCPU / 15GB) and should be fixed in the
  same pass.
- **`docs/infrastructure-actual.md` contradicted itself** on whether the GPU
  is attached — its 2026-07-14 GPU paragraph vs `:185,:220,:244`. Decision
  6's check settled it on 2026-08-31 (the card is attached) and that
  paragraph has been corrected accordingly. This is the one item on this drift list that the
  verification pass could resolve; the rest still stand.
- **The `nvidia_accelerator_enabled: false` line and its stale comment stay
  as they are**, but the comment ("re-enable when k8s-worker-gpu is added")
  now names a VM that ADR-0016 retired. Worth a correction so a future
  reader does not go looking for it. `.claude/skills/terraform-ops/SKILL.md:118-121`
  has the same stale name.
- **The device plugin needs a node label the hostname nodeSelector does not
  provide.** Chart 0.17.1 ships a default `nodeAffinity` requiring one of
  `feature.node.kubernetes.io/pci-10de.present`,
  `feature.node.kubernetes.io/cpu-model.vendor_id=NVIDIA`, or
  `nvidia.com/gpu.present`. With no NFD in the cluster none existed, so the
  DaemonSet computed `DESIRED=0` — pinning by hostname in `nodeSelector` does
  not override the chart's own affinity. Found on 2026-08-31 after the merge,
  when the Application went Synced/Healthy with zero pods: **a Healthy ArgoCD
  Application is not evidence that a DaemonSet scheduled anything.** Fixed by
  adding `nvidia.com/gpu.present: "true"` to this node's `node_labels`, which
  is the escape hatch the chart documents and the label Decision 4 already
  named. Applying it needs `--tags node-label` alongside `container-engine`.
  Note `affinity: {}` in a values file would *not* have worked as an
  alternative — Helm merges maps, so only `affinity: null` clears a chart
  default.
- **A negative test becomes part of the verification contract.** Decision 3
  is only worth anything if it is checked: a pod on `k8s-worker-01` with no
  `runtimeClassName` and no `nvidia.com/gpu` limit must **fail** to see the
  GPU. If it succeeds, ADR-0011 has been reopened silently and the runtime
  configuration is wrong.
- **Kubespray must be re-run to apply Decision 2 — scoped, not full.**
  `--tags container-engine --limit k8s-worker-01` is sufficient, established
  2026-08-31: `kubespray/playbooks/cluster.yml:16` carries
  `tags: "container-engine"` on the role, and `roles/kubespray_defaults/`
  holds only `defaults/` and `vars/` with no tasks, so `--tags` cannot skip
  it and its variables still load. That was the risk, and it is not one.
  A full `cluster.yml` would be an ingress outage per ADR-0040 — the limited
  run is not: **Traefik runs on `k8s-cp-01`**, and Prometheus, Grafana and
  Loki on `k8s-worker-02`, so `--limit k8s-worker-01` touches neither
  ingress nor monitoring. The cost is the `restart containerd` handler on a
  node carrying 53 pods (see the self-drain note below).
- **A quoted-string trap in `containerd_additional_runtimes`.** Option
  values must be YAML *strings*, never bare booleans:
  `config.toml.j2:59-65` quotes any value whose `| string` is not literally
  `"true"`/`"false"`, and Jinja renders a Python bool as `"True"` — so
  `SystemdCgroup: true` emits `SystemdCgroup = "True"`, a TOML string into a
  Go bool field. The option is then dropped (this runtime silently gets
  cgroupfs while kubelet uses systemd — the exact mismatch Decision 2 sets
  it to avoid) or containerd rejects the config and does not start. Caught
  before the first run, on 2026-08-31; guarded since by
  `ansible/scripts/check-containerd-runtime-options.py` in CI, because
  nothing else catches it — the YAML is valid, ansible-lint is happy, and
  the damage only appears mid-`cluster.yml`.
- **The driver pin is `nvidia-driver-580-server`, and the 570 one was a
  fiction.** On noble `nvidia-driver-570-server` is a transitional shim whose
  entire dependency list is `nvidia-driver-580-server`; installing it pulls
  the 580 branch, and the first real run (2026-08-31) came up on
  **580.173.02**, not the 570.211.01 the playbook claimed to pin. A
  metapackage named for a branch is not evidence it installs that branch —
  check `apt-cache depends`, not just `apt-cache madison`. Both are in
  `noble-updates/restricted`, and either way it is far above the ≥ 525.60.13
  any CUDA 12.x consumer needs. Separately
  confirmed: `nvidia-container-toolkit` is in **no** Ubuntu pocket, so
  Decision 1's NVIDIA apt repository is genuinely required rather than
  belt-and-braces.
- **This adds a pod to a node that is committed but not full**, while
  ADR-0037 is still open. ADR-0037's 94% figure did not survive
  verification (56% requested / 122% limits on 2026-08-31), so that ADR
  needs re-measuring on its own terms; the two still interact and it
  should be settled rather than left to drift further.
- GPU workloads inherit `k8s-worker-01`'s availability, which is
  deliberately poor — `.165` is rebooted for gaming. That is accepted for
  GPU work by design, and is why Decision 1 leans on the existing
  self-drain units rather than adding new lifecycle machinery.
  `drain-self.service` and `uncordon-self.service` were confirmed `enabled`
  on the node 2026-08-31.
- **The reboot is not a small event.** `k8s-worker-01` was carrying 53 pods
  on 2026-08-31 — the whole single-replica ArgoCD stack, authentik, the
  infisical backend, a coredns replica, the longhorn CSI controllers, the
  actions-runner and agent-fleet's provisioner. Self-drain handles the
  eviction, and ingress and monitoring are unaffected (they live
  elsewhere), but expect an ArgoCD UI gap while it moves. Worth knowing
  before starting, not during.
