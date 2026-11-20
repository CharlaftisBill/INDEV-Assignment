# 0010 — Monitoring with kube-prometheus-stack

Status: Accepted · Date: 2026-11-19

## Context
Requirement 6: Prometheus and Grafana, with node and etcd health alerts that reach Alertmanager.
The VM has about 7.7 GiB of RAM. The llama.cpp pod needs at least 2.5 GiB and the base cluster about 2 GiB,
so monitoring gets about 3 GiB.

## Decision
kube-prometheus-stack (Helm release `kps` in namespace `monitoring`). It ships Prometheus, Alertmanager, Grafana,
and ready-made node, etcd and kubelet alerts and dashboards. All 8 images pinned by digest.

## Details
- **node-exporter** runs in its own namespace `node-exporter`, labelled `privileged`, because it needs host network,
  host processes and host folders. Everything else stays `restricted` ([ADR 0007](0007-pod-security-restricted.md)).
  The exporter still has no privilege escalation, no capabilities, `RuntimeDefault` seccomp and a read-only root (B-040).
- **Webhook certificate**: from the chart's own self-signed chain. Our CA can't sign it: it only signs `*.local`
  names ([ADR 0005](0005-internal-ca-and-renewal.md)), and the webhook uses `*.svc`. `failurePolicy: Ignore`, because
  the chart applies its rules before the operator is up.
- **Scrape targets** (19 up): API server, kubelet, etcd (HTTP on 2381), controller-manager, scheduler, kube-proxy,
  node-exporter, kube-state-metrics, Traefik (9101). The `kubeadm` role makes them listen on the node IP.
- **Extra alerts** (after B-038): `TraefikDown` (Traefik target down or missing) and `TraefikIngressNotSynced`
  (Ingresses with TLS exist, but Traefik loaded no certificate). The second covers TLS Ingresses only.
- **Pod Security**: `monitoring` is `restricted`; the chart's settings pass, read-only root included.
- **Grafana**: `https://grafana.local` through Traefik, certificate from our CA. The admin password is generated on the
  Mac in `.secrets/grafana-admin-password`, stored in Secret `grafana-admin`, never printed (B-039). No anonymous
  access. Its service account reads only ConfigMaps in `monitoring`. No storage: the data source and 27 default
  dashboards are provisioned. Use: [runbook](../runbooks/grafana.md).
- **NetworkPolicies**: deny all, DNS, then one policy per component. Host-network peers (API server, kubelet, etcd,
  node-exporter, Traefik) are allowed by node IP /32 ([ADR 0003](0003-traefik-ingress.md)). `check_6` proves the
  policies work with a probe pod from outside the namespace.
- **Alertmanager**: no receivers (alerts only need to reach Alertmanager) and no volume, so silences are lost on restart.
- **Memory**: all monitoring pods together request at most 1536 MiB and are limited to 3072 MiB (2880 used); `check_6`
  asserts this (B-041). Prometheus: 1280 MiB limit, `GOGC=50`, at most 2 queries at once and 1.2M samples per
  query, 1 minute timeout (B-042). Why these numbers: [runbook](../runbooks/prometheus-memory.md).
- **Storage**: Prometheus keeps 3 days or 3 GB on a 5 GiB volume.
- **Alert proof**: `check_6` shows rules loaded, the always-on `Watchdog` alert in Alertmanager, and `promtool` unit
  tests (`files/alert-tests.yaml`) that fire `KubeNodeNotReady`, `NodeFilesystemAlmostOutOfSpace`, `etcdNoLeader`,
  `etcdInsufficientMembers`, `etcdMembersDown` and both Traefik alerts. Breaking a real node or etcd in an automatic
  check would be disruptive, so firing real alerts is a manual [demo](../runbooks/alert-demo.md). The SRE review ran
  it: `etcdInsufficientMembers` and `NodeNetworkInterfaceFlapping` both reached Alertmanager.

## Alternatives
| Option | Why not |
|---|---|
| Hand-written Prometheus and Grafana manifests | We would maintain all rules, dashboards and scrape configs |
| Separate Prometheus and Grafana charts | Loses the operator and its bundled node and etcd rules |
| node-exporter in `monitoring` | The whole namespace would have to be `privileged` |
| Webhook certificate from our CA | Our CA can't sign `*.svc` names |
| Unit tests only as alert proof | Doesn't show alerts reaching Alertmanager; the demo adds that |
| Bigger Prometheus limit, no query limits | Leaves no room for llama.cpp; one wide query could still crash Prometheus |

## Consequences
- A query over more than 1.2M samples fails with "too many samples". Raise the limits together
  ([runbook](../runbooks/prometheus-memory.md)).
- `/api/v1/series` is not covered by the query limits (B-043, accepted risk, deferred to M10).
- Only 3 days of metrics; they are not backed up.
- The Grafana password exists only on the Mac and in the Secret.
