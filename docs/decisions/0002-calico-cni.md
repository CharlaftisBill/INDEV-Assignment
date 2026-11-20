# 0002 — Calico as network plugin (CNI)

Status: Accepted (M3) · Date: 2026-11-17

## Context
Requirement 3: we pick the network plugin, and app pods must accept only the traffic they need.
So the plugin must enforce NetworkPolicy.

## Decision
Calico, installed with the tigera-operator Helm chart. All images pinned by digest.
Pod network `10.244.0.0/16`, because Lima's network `192.168.5.0/24` overlaps Calico's default `192.168.0.0/16`.
Apps use standard Kubernetes NetworkPolicies: deny everything, then allow what is needed.

## Details
- **CRDs**: since Calico 3.32 they come in a separate chart. Some are larger than Helm's 1 MiB release limit,
  so the role renders that chart with `helm template` and applies it with `kubernetes.core.k8s`.
- **IP pool**: one pool, `VXLANCrossSubnet`, BGP off. One node never needs a tunnel, and a second node on Lima's
  network would not need one either. No BGP daemon, no port 179.
- **Node address**: taken from the default-route network card (Lima has one).
- **CNI folder**: Debian's containerd looks for plugins in `/usr/lib/cni`, not `/opt/cni/bin`. The role reads the
  folder from `containerd config dump` and passes it to Calico.
- **Off**: Goldmane and Whisker (flow UI). **On**: the Calico API server, because the operator reports Degraded without it.
- **Pod Security**: `tigera-operator` and `calico-system` are labelled `privileged`; Calico needs host access.
- **Images by digest** (B-030; they run privileged). The operator uses `<tag>@<digest>`. Calico's own images use an
  `ImageSet` named `calico-v<version>`. `check_3a` compares running images with `versions.yml`.
- **Upgrade**: set a new `calico_chart_version`, operator version and digests in `versions.yml` (check arm64), then
  provision. The role adds a new ImageSet. Delete the old one by hand.

## Alternatives
| Option | Why not |
|---|---|
| Cilium | More moving parts and more kernel-version sensitive, for one node |
| Flannel | Does not enforce NetworkPolicy |

## Consequences
- Mature NetworkPolicy support; the operator handles upgrades.
- Standard policies only, so they work with any other plugin.
- Accepted risks (Low):
  - The operator's RBAC is close to cluster-admin.
  - `force_conflicts`: our chart values override the operator's defaults.
  - Calico's `calico-tiered-policy-passthrough` binding gives every logged-in user access to tiered policies.
    See [ADR 0011](0011-operator-identity.md) for how this affects the read-only user.
