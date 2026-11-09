# talos/

Source for the **throwaway Talos pilot** on the two Esprimos.

- Decision: [ADR-0070](../docs/adr/0070-talos-pilot.md) (Proposed).
- Procedure, tests and go/no-go: [`docs/plan-talos-pilot-esprimo.md`](../docs/plan-talos-pilot-esprimo.md).
- Why: [`docs/evaluation-drop-proxmox-talos.md`](../docs/evaluation-drop-proxmox-talos.md).

**Nothing here touches prod.** `addons.sh` refuses to run unless the
kubeconfig points at the pilot API (`https://192.168.1.21:6443`), and
refuses a MetalLB range overlapping prod's `.233-.250`. If the go/no-go
says no, this directory is deleted.

**No secrets live here.** The `talosctl gen secrets` bundle, `talosconfig`
and kubeconfig come from the `talos-pilot` Infisical project into `0600`
files on the Pi and are deleted after use. `rendered/`, `secrets.yaml`,
`talosconfig`, `kubeconfig` and Terraform state are gitignored.

## Layout

| Path | What |
| --- | --- |
| `schematic.yaml` | Image Factory schematic: `intel-ucode`, `iscsi-tools`, `util-linux-tools`, `net.ifnames=0`. Record its ID in the file once created |
| `patches/common/` | Both nodes: no Flannel/kube-proxy, prod's pod/service ranges, Pi-hole as only resolver, zot mirror, EPHEMERAL cap + `longhorn` user volume, kubelet serving certs + graceful shutdown, log shipping, user namespaces |
| `patches/controlplane/` | Esprimo 1: control plane schedulable and allowed to announce MetalLB IPs; metrics ports matching prod |
| `patches/nodes/` | Per machine: hostname, static `eth0`, Wake-on-LAN, install disk (serial **to fill in** from the hardware session) |
| `values/` | Helm values for Cilium and Longhorn; the MetalLB pool template |
| `render.sh` | Renders and validates both machine configs into `rendered/` |
| `addons.sh` | Installs Cilium → serving-cert approver → MetalLB → Longhorn → metrics-server, all versions pinned by the caller |

`terraform/` (the `siderolabs/talos` provider, for the T22 rebuild) is
written after the hand-run tests, from what actually worked.

## Use (on the Pi)

1. Create the schematic and record its ID (header of `schematic.yaml`).
2. Fetch the secrets bundle from Infisical into a `0600` file, then:
   ```bash
   SECRETS=/tmp/secrets.yaml SCHEMATIC_ID=<id> TALOS_VERSION=v1.14.<n> talos/render.sh
   ```
3. Install headless (plan §1.5):
   ```bash
   talosctl apply-config --insecure -n <maintenance-ip> -f talos/rendered/esprimo-1.yaml
   ```
   Same for Esprimo 2, then `talosctl config endpoints` / `config nodes`,
   `talosctl bootstrap -n 192.168.1.21`, `talosctl kubeconfig`.
4. Add-ons:
   ```bash
   CILIUM_VERSION=... METALLB_VERSION=... LONGHORN_VERSION=... METRICS_SERVER_VERSION=... CERT_APPROVER_VERSION=... PILOT_LB_RANGE=... talos/addons.sh
   ```
5. Always `talosctl reset --reboot`; every `talosctl upgrade` passes
   `--image factory.talos.dev/metal-installer/<schematic-id>:<version>`.

## Not yet verified

These are marked `UNVERIFIED` in the files themselves. `render.sh` runs
`talosctl validate`, which catches schema errors, and the rendered
controlplane config must still be read once by eye.

- **Field shapes** of 1.14's `KubeNetworkConfig`, `ResolverConfig`,
  `LinkConfig`, `HostnameConfig` and `EthernetConfig`.
- **The `$patch: delete` form** that removes the control-plane taint and
  the exclude-LB label from `KubeNodeConfig`.
- **Mixing old and new config forms:** the `v1alpha1` sections (`logging`,
  `sysctls`, etcd and controller extraArgs, install disk) coexisting with
  1.14 documents.
- **Cilium's `defaultLBServiceIPAM`** key.
- **Longhorn backup-target keys** for the pinned chart version.
