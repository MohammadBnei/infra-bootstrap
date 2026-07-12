# ADR-0012: Reject GitOps-managed Proxmox

**Status:** Rejected

## Context

Since K8s workloads are GitOps-managed via ArgoCD, extending that same
model to Proxmox host/VM lifecycle was raised as a consistency option.

## Decision

Rejected. Proxmox VM/LXC provisioning stays Terraform + manual
`cv4pve-cli`/`qm` operations (see `terraform/README.md`), not
gitops-reconciled. ArgoCD's reconciliation loop is a poor fit for
infrastructure that includes physical-host state (disk images, PCI
passthrough) rather than pure Kubernetes manifests.

## Consequences

Proxmox changes go through Terraform plan/apply, not an ArgoCD sync.
