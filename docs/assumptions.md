# Assumptions and accepted risks

Where the assignment is unclear, this is how we read it. Add new ones here.

## How we read the assignment

| Assignment says | We read it as |
|---|---|
| A Debian 13 VM on the host | The host is an Apple Silicon Mac, so the VM is **arm64** under Lima. Intel hosts are untested, Linux hosts are planned ([Backlog](../TODO.md#backlog)), Windows is out of scope (Ansible needs WSL2) |
| Pinned package versions | Every apt package a role installs by name is pinned and held. Their dependencies are not pinned |
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
| **Many parallel `/api/v1/series` calls** can crash Prometheus; the query limits don't cover that path (B-043) | Needs admin access (port-forward or API proxy); Prometheus restarts in seconds with its data intact | M10 |
| **Node and host-network processes** can reach app pods ([ADR 0003](decisions/0003-traefik-ingress.md)) | Kubernetes always allows node-to-pod traffic; only platform parts run there | — |
