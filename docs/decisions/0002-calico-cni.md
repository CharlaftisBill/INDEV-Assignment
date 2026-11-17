# 0002 — Calico as CNI

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 3: a CNI of our choice, and application pods accept only the traffic they need, so the CNI must enforce NetworkPolicy.

## Decision
Calico, installed with the tigera-operator Helm chart (pinned). Pod CIDR `10.244.0.0/16` (Lima's user network uses 192.168.5.0/24, which overlaps Calico's default `192.168.0.0/16`). App namespaces use standard `networking.k8s.io/v1` NetworkPolicies: default-deny ingress and egress, then explicit allows.

## Alternatives considered
- **Cilium**: eBPF, L7 policies and Hubble, but more moving parts for a single node and more kernel-version sensitivity.
- **Flannel**: does not enforce NetworkPolicy.

## Consequences
- Mature, well-documented NetworkPolicy enforcement; operator-managed upgrades.
- Standard policies only, so they stay portable to any CNI.
