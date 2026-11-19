# 0010 — Monitoring stack (kube-prometheus-stack)

Status: Accepted · Date: 2026-11-19

## Context
Requirement 6: Prometheus + Grafana, with node and etcd health alerts visible in Alertmanager. The VM has ~7.7 GiB; the llama.cpp pod (M9) needs >= 2.5 GiB and the base cluster ~2 GiB, so the stack gets ~3 GiB.

## Decision
- **kube-prometheus-stack 92.18.0** (operator v0.94.2), Helm release `kps` in `monitoring`, 8 images pinned by multi-arch digest (`versions.yml`). Ships the default node/etcd/kubelet rules and dashboards.
- **node-exporter in its own namespace** `node-exporter`: it needs hostNetwork/hostPID/hostPath, so PSA `privileged`. Everything else stays PSA `restricted` ([ADR 0007](0007-pod-security-restricted.md)). The exporter still has no privilege escalation, drops ALL caps, uses seccomp RuntimeDefault and a read-only rootfs (B-040).
- **Webhook certificate** from the chart's own self-signed cert-manager chain, not `internal-ca`: that CA is name-constrained to `.local` ([ADR 0005](0005-internal-ca-and-renewal.md)) and the webhook uses `*.svc` names. `failurePolicy: Ignore`, because the chart's rules are applied before the operator serves.
- **Scrape targets** (19 UP): apiserver, kubelet, etcd (plain HTTP :2381), controller-manager, scheduler, kube-proxy, node-exporter, kube-state-metrics, Traefik (PodMonitor :9101). Components are bound to the node IP by the `kubeadm` role.
- **Custom alerts** `TraefikDown`, `TraefikIngressNotSynced` (follow-up to B-038).
- **Grafana** at `https://grafana.local` through Traefik, certificate from `internal-ca`. Admin password generated on the host into `.secrets/grafana-admin-password`, loaded into Secret `grafana-admin`, never printed (B-039). Anonymous access off; its ServiceAccount reads only ConfigMaps in `monitoring`.
- **NetworkPolicies**: default-deny plus one per component.
- **Sizing**: requests 1536Mi / limits 3072Mi caps (2880Mi used), asserted by `check_6` (B-041). Prometheus: 5Gi local-path PVC, retention 3d / 3GB, 1280Mi limit (GOMEMLIMIT ~1152Mi), `GOGC=50`, query caps 2 concurrent x 1.2M samples, 1m timeout (B-042). Rationale: ~600Mi idle heap leaves ~500Mi for queries; a wide raw result costs ~85 B per sample, and queued queries overlap the running ones, so concurrency x 2 x samples x 100 B must fit it; numbers in `ansible/roles/monitoring/defaults/main.yml`.
- **Alert proof**: `check_6` shows rules loaded and healthy, `Watchdog` active in Alertmanager, and `promtool` unit tests (`files/alert-tests.yaml`) firing `KubeNodeNotReady`, `NodeFilesystemAlmostOutOfSpace`, `etcdNoLeader`, `etcdInsufficientMembers`, `etcdMembersDown` and both Traefik alerts. Breaking a real node or etcd in an automated check would be disruptive, so the real firing is a reversible manual demo: [runbook](../runbooks/monitoring.md#real-alert-demo). It was run during the SRE review: `etcdInsufficientMembers` and `NodeNetworkInterfaceFlapping` both reached Alertmanager.

## Alternatives considered
| Option | Why not |
|---|---|
| Hand-written Prometheus/Grafana manifests | Rules, dashboards and ServiceMonitors would be ours to maintain |
| Separate prometheus + grafana charts | Loses the operator CRDs and the bundled node/etcd rules |
| node-exporter in `monitoring` | Forces the whole namespace to PSA `privileged` |
| Webhook cert from `internal-ca` | Name constraint `.local` rejects `*.svc` names |
| Alert proof by unit tests only | Does not show delivery to Alertmanager; demo added |
| Larger Prometheus limit, no query caps | Starves the llama.cpp pod; one wide query could OOM Prometheus |

## Consequences
- Queries over more than 1.2M samples fail with "too many samples"; raise caps with the limits together ([runbook](../runbooks/monitoring.md#series-grew-raise-query-caps-and-limits)).
- Retention is short (3d); metrics are not a backup target.
- The Grafana password lives only on the host and in the Secret.
