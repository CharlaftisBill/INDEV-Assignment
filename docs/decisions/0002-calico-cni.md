# 0002 — Calico as CNI

Status: Accepted (M3) · Date: 2026-11-17

## Context
Requirement 3: a CNI of our choice, and application pods accept only the traffic they need, so the CNI must enforce NetworkPolicy.

## Decision
Calico, installed with the tigera-operator Helm chart (pinned). Pod CIDR `10.244.0.0/16` (Lima's user network uses 192.168.5.0/24, which overlaps Calico's default `192.168.0.0/16`). App namespaces use standard `networking.k8s.io/v1` NetworkPolicies: default-deny ingress and egress, then explicit allows.

## Implementation (M3)
- Chart `tigera-operator` v3.33.0 via `kubernetes.core.helm`; the CRDs chart (`crd.projectcalico.org.v1`, same version) is rendered with `helm template` and applied with `kubernetes.core.k8s`: since 3.32 they are a separate chart, and some CRDs exceed the 1 MiB helm release Secret.
- One IPPool `10.244.0.0/16`, `VXLANCrossSubnet`, BGP off: one node never encapsulates, a later node on Lima's /24 needs no overlay, no BGP daemon or port 179.
- Node address autodetection is pinned to the default-route interface (Lima has one NIC).
- Debian's containerd looks for CNI plugins in `/usr/lib/cni` (not `/opt/cni/bin`): the role reads `bin_dir` from `containerd config dump` and passes it as `cni.binDir`.
- Goldmane and Whisker (flow UI) are off. The Calico API server stays on: operator 1.44's `tiers` status is Degraded without it.
- `tigera-operator` is created with PSA `privileged` labels before the chart; the operator labels `calico-system` itself.

## Alternatives considered
- **Cilium**: eBPF, L7 policies and Hubble, but more moving parts for a single node and more kernel-version sensitivity.
- **Flannel**: does not enforce NetworkPolicy.

## Consequences
- Mature, well-documented NetworkPolicy enforcement; operator-managed upgrades.
- Standard policies only, so they stay portable to any CNI.
