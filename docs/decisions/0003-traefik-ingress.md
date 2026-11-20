# 0003 — Traefik as ingress controller

Status: Accepted · Date: 2026-11-19

## Context
Requirement 4 needs an ingress controller with TLS. The community ingress-nginx project was retired in March 2026.
The Mac reaches the VM through Lima, which forwards only ports a process really listens on.

## Decision
Traefik from its Helm chart, on the host network, and **non-root** (user 65532, no capabilities, read-only root; B-009).
Normal Kubernetes Ingress objects, with TLS certificates from cert-manager.

| VM port | Use | Mac port |
|---|---|---|
| 8443 | HTTPS | 443 |
| 8000 | HTTP, redirects to HTTPS | 80 |
| 9101 | metrics | not forwarded |
| 9102 | health ping | not forwarded |

Port 9100 stays free for node-exporter; 9102 avoids the common 8080. Traefik sends no usage data and does not check
for updates. Its Service is off (it listens on the node), and the IngressRoute CRDs are skipped (Ingress only).

## Details

**RBAC (B-036, B-038).** The chart's RBAC is off. The role makes its own:
- one ClusterRole for `ingressclasses` and `nodes`;
- a Role in each namespace of `ingress_traefik_watched_namespaces` (`llm`, `monitoring`, `ingress-check`).
  So Traefik can read Secrets only there, and never the CA key in `cert-manager` or `kube-system`.
  `check_4` tests this.
- The role creates the watched namespaces and nothing deletes them. If one is missing, Traefik stops serving
  **all** routes. A new Ingress namespace must be added to the list. Test namespaces (`verify-tmp`) are never watched;
  a leftover Role there is removed.
- `ingress-check` is `check_4`'s test namespace: `restricted`, deny all, plus the node-IP allow on 8080.
- The chart's `rbac.namespaced` option was rejected: it removes the ClusterRole, so Traefik loses IngressClass access.

**NetworkPolicy (B-008).** Traefik reaches pods from the node IP, which pod selectors cannot match. App policies
allow the node IP (/32) on the app port. That rule documents intent but enforces nothing: Calico always lets the
node reach its own pods (removing the rule still gave HTTP 200). Kubernetes documents the same behaviour.
`check_3b` proves that other pods are blocked.

## Alternatives
| Option | Why not |
|---|---|
| ingress-nginx | Retired upstream |
| CNI hostPort | iptables forwarding with no listening socket; Lima can't see it |
| NodePort | Needs extra port mapping and odd port numbers |
| Traefik on 443/80 directly | Needs root or `NET_BIND_SERVICE`; Lima remaps the ports instead |
| Gateway API | Fine, but the assignment says "ingress controller" and Ingress keeps app manifests simple |

## Consequences
- Traefik's namespace needs host-network rights, so it is not `restricted`. It is platform, not an app.
  The container itself is unprivileged.
- Only one Traefik pod can hold the ports. Fine for one node.
- Lima binds Mac ports 80 and 443 on all interfaces, but LAN connections are reset (tested). The ingress is not
  reachable from other machines.
- Accepted risk: any process on the node or on the host network can reach app pods.
- Traefik can read every Secret in `monitoring`, including Grafana's. Idea: give Grafana's Ingress its own namespace.
