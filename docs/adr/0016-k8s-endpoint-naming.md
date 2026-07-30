# ADR-0016: K8s API endpoint naming

**Status:** Accepted

## Context

Two candidate DNS names existed for the K8s API endpoint:

- `k8s-proxmox-gpu.bnei.lan` — current test-build isolation name,
  pointing at `.201` (`k8s-cp-01` directly, no VIP).
- `k8s.bnei.lan` — the legacy/libvirt-era name, mapped to a reserved API
  VIP `.180` that was, until now, unused.

## Decision

`k8s.bnei.lan` → `192.168.1.180`, superseding the test-build name. `.180`
stops being a bare reservation: it's now the kube-vip control-plane VIP
(ARP/L2 mode, matching MetalLB's own L2-only constraint since the Freebox
blocks BGP) floating across all 3 control-plane members
(`k8s-cp-01`/`.165`, `k8s-cp-02`/server1, `k8s-cp-03`/ex-laptop — see
ADR-0017's resolution). `kube_proxy_strict_arp` was already `true`
(locked decision), which is kube-vip's one hard requirement for ARP mode.

Config lives in `inventory/ukubi/group_vars/k8s_cluster/addons.yml`:
`kube_vip_enabled`/`kube_vip_arp_enabled`/`kube_vip_controlplane_enabled: true`,
`kube_vip_address: 192.168.1.180`.

## Consequences

- External access (operator `kubectl`, anything outside the cluster)
  should move to `https://k8s.bnei.lan:6443` (or `192.168.1.180:6443`
  until DNS is actually stood up — see the open DNS-step discussion) once
  the VIP is live, instead of pointing at `k8s-cp-01`'s own IP directly.
  In-cluster clients (kubelet, ArgoCD) don't need this — they already
  fail over across control-plane members via kubespray's own per-node
  apiserver proxy and standard k8s Service endpoints.
- The API server's cert SANs need `192.168.1.180` and `k8s.bnei.lan`
  added (kubespray's `supplementary_addresses_in_ssl_keys` /
  `apiserver_loadbalancer_domain_name`-equivalent for a VIP) before this
  is truly usable externally over TLS — not yet configured, do that
  alongside rolling out the 2nd/3rd control-plane members.
- `k8s-proxmox-gpu.bnei.lan` is retired; nothing should keep referencing it.
