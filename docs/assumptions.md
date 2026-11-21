# Assumptions and accepted risks

Where the assignment is unclear, this is how we read it. Add new ones here.

## How we read the assignment

| Assignment says | We read it as |
|---|---|
| A Debian 13 VM on the host | The host is an Apple Silicon Mac, so the VM is **arm64** under Lima. Intel Macs are unsupported, Linux hosts (QEMU) are untested ([install](install.md#linux-untested)), Windows is out of scope (Ansible needs WSL2) |
| Pinned package versions | Every apt package a role installs by name is pinned and held. Their dependencies are not pinned |
| Debian apt pins stay installable | `snapshot.debian.org` at one pinned timestamp is a fallback next to the live mirrors, not the only source: it is slower and can rate-limit. `apt update` needs it reachable (B-027) |
| Pinned versions in general | We take the newest release that is **at least 2 weeks old**, with an arm64 build |
| Requirement 3: app pods accept only the traffic they need | Traffic from other pods and networks. Traffic from the node itself is always allowed by Kubernetes and Calico ([ADR 0003](decisions/0003-traefik-ingress.md)). Accepted by the user, 2026-11-19 |
| Requirement 6: node and etcd alerts fire in Alertmanager | The default node and etcd rules are loaded and healthy, the always-on `Watchdog` reaches Alertmanager, and `promtool` tests show the alerts fire on bad input. Breaking a real node or etcd takes minutes and disrupts the cluster, so that is a manual [demo](runbooks/alert-demo.md). Alerts only need to reach Alertmanager, so it has no receivers |
| Requirement 7: snapshots stored outside the cluster | Outside the VM too: in `./backups` on the Mac |
| Requirement 8: application workloads | Pods in `app_namespaces` (today `llm`). Platform parts (network plugin, monitoring, ingress, storage) may get host access where they really need it ([ADR 0007](decisions/0007-pod-security-restricted.md)) |
| Requirement 8c: every API request recorded | Audit log at `Metadata` level for all requests, no `None` rules. The `RequestReceived` stage is skipped; each request is still logged when it finishes |

## Accepted risks

Decided by the user. Smaller (Low) risks are listed in each ADR under Consequences.

| Risk | Why accepted | Until |
|---|---|---|
| **runc 1.1.15** has known container-escape CVEs (CVE-2025-31133, 52565, 52881). Debian trixie has no fixed build (B-026) | Single-user local VM that runs only our own workloads, all `restricted` | trixie-security ships a fix, or before any shared use |
| **Many parallel unbounded `/api/v1/series` calls** can crash Prometheus: no server-side cap exists, the query limits skip that path (B-043) | Needs admin access (port-forward or API proxy) or Grafana admin via the datasource proxy. Grafana is capped (`seriesLimit` 5000); 4 parallel full calls fit, 8 do not ([runbook](runbooks/prometheus-memory.md)). Prometheus restarts in seconds with its data intact | Prometheus adds a series cap, or before any shared use |
| **Cluster CA keys and ServiceAccount signing key on the Mac** (`.secrets/kubeadm-pki/`, 0600): whoever reads them can mint cluster-admin certificates and tokens, and they no longer change with a VM rebuild ([ADR 0006](decisions/0006-etcd-backups-outside-cluster.md#restore-on-a-rebuilt-vm)) | Same protection as the ingress CA key next to them; lets an etcd snapshot restore onto a rebuilt VM without restarting every pod or reissuing tokens. A rebuild no longer revokes leaked credentials: delete the folder and rebuild for that | Before any shared use |
| **Node and host-network processes** can reach app pods ([ADR 0003](decisions/0003-traefik-ingress.md)) | Kubernetes always allows node-to-pod traffic; only platform parts run there | — |
