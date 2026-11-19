# 0003 — Traefik as ingress controller

Status: Accepted · Date: 2026-11-19

## Context
Requirement 4 needs an ingress controller with TLS. The community ingress-nginx project was retired in March 2026, so a maintained controller is needed. The Mac reaches the VM through Lima port-forwarding, which only sees real listening sockets in the guest.

## Decision
Traefik via its Helm chart (pinned), `hostNetwork: true`, **non-root** (UID 65532, drop ALL, no added caps, read-only rootfs; B-009).

| Port | Use | Lima forward |
|---|---|---|
| 8443 | websecure (HTTPS) | Mac 443 → guest 8443 |
| 8000 | web, permanent redirect to HTTPS | Mac 80 → guest 8000 |
| 9101 | metrics | none |
| 9102 | ping | none |

All other guest ports are ignored by Lima. 9100 stays free for node-exporter (M6). Standard `networking.k8s.io/v1` Ingress resources with TLS secrets issued by cert-manager.

Traefik sends no anonymous usage data and does not check for new versions (`checkNewVersion`/anonymous usage off).

**RBAC (B-036, B-038):** the chart's RBAC is off. The role creates its own:
- one ClusterRole for `ingressclasses` and `nodes` (cluster-scoped);
- a Role + RoleBinding in each namespace of `ingress_traefik_watched_namespaces` (`llm`, `monitoring`, `ingress-check`), so Secrets are readable only there. The CA key in `cert-manager` and `kube-system` stay out of reach (`check_4` asserts `auth can-i get secrets` is `no`).
- The role creates the watched namespaces (bare; the owning roles add PSA labels and policies later) and nothing deletes them: Traefik's informers do not sync if a watched namespace is missing, and all routes vanish. A new Ingress namespace must be added to the list. Scratch namespaces (`verify-tmp`) are never watched.
- Chart `rbac.namespaced` was rejected: it drops the ClusterRole, so Traefik loses IngressClass access.

**NetworkPolicy (B-008, verified in M9):** hostNetwork traffic reaches pods from the node IP, which pod/namespace selectors cannot match. App policies carry an `ipBlock` /32 allow for the node IP on the app port, but that rule is documentation of intent, not enforcement: Calico always allows host-to-local-pod traffic (deleting the node-IP allow still returned 200). This matches Kubernetes' documented rule that node-to-pod traffic is always allowed. `check_3b` (M9) proves pod-to-pod denial.

## Alternatives considered
- **ingress-nginx**: retired upstream.
- **NodePort / CNI hostPort**: hostPort is iptables DNAT with no listening socket, invisible to Lima's forwarder; NodePort would need extra host port mapping and non-standard ports.
- **Traefik binding 443/80 directly**: needs root or `NET_BIND_SERVICE`; rejected to keep it non-root, with Lima remapping the ports instead.
- **NGINX Gateway Fabric / Gateway API**: fine, but the assignment says "ingress controller" and Ingress keeps the app manifests simple.

## Consequences
- Traefik's namespace needs host-network privileges (exempt from PSA `restricted`; it is platform, not an application workload), but the container itself is unprivileged.
- Only one Traefik replica can bind the ports on the node, which matches a single-node cluster.
- Lima binds Mac `*:80`/`*:443` (macOS allows low ports), but LAN connections are reset (tested), so the ingress is not reachable off-host.
- Accepted risk: any node-local or hostNetwork process can reach app pods, because node traffic is always allowed (see above). Single node, platform components only.
- After M6 Traefik can read every Secret in `monitoring` (Grafana's). Candidate: give Grafana's Ingress its own namespace in M6.
