# 0003 — Traefik as ingress controller

Status: Proposed (accepted when implemented) · Date: 2026-11-17

## Context
Requirement 4 needs an ingress controller with TLS. The community ingress-nginx project was retired in March 2026, so a maintained controller is needed. The Mac reaches the VM through Lima port-forwarding, which only sees real listening sockets in the guest.

## Decision
Traefik via its Helm chart (pinned), running with `hostNetwork: true` and binding 80/443 on the node. Lima forwards host 127.0.0.1:443 → guest :443. Standard `networking.k8s.io/v1` Ingress resources with TLS secrets issued by cert-manager. HTTP redirects to HTTPS.

## Alternatives considered
- **ingress-nginx**: retired upstream.
- **NodePort / CNI hostPort**: hostPort is iptables DNAT with no listening socket, invisible to Lima's forwarder; NodePort would need extra host port mapping and non-standard ports.
- **NGINX Gateway Fabric / Gateway API**: fine, but the assignment says "ingress controller" and Ingress keeps the app manifests simple.

## Consequences
- Traefik's namespace needs host-network privileges (exempt from PSA `restricted`; it is platform, not an application workload).
- Only one Traefik replica can bind 443 on the node, which matches a single-node cluster.
