# ADR-0008: Reject Flatcar as VM OS

**Status:** Rejected

## Context

Flatcar Container Linux was considered for its immutable-OS properties.

## Decision

Rejected. Ubuntu 24.04 cloud-init remains the VM OS (cloud-init template
VMID 9000, login user `core`, not `ubuntu`). Debian/Ubuntu plus GitOps
already gives adequate immutability for this cluster's needs, with less
Day-2 friction than adopting a new OS family.

## Consequences

All K8s and Postgres VMs stay on the same Ubuntu 24.04 cloud-init base
image, keeping provisioning (Terraform + cloud-init) uniform.
