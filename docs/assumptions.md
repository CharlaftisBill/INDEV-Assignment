# Assumptions and accepted risks

Where the assignment is unclear, this is how we read it. Add new ones here.

## How we read the assignment

| Assignment says | We read it as |
|---|---|
| A Debian 13 VM on the host | The host is an Apple Silicon Mac, so the VM is **arm64** under Lima. Linux amd64 hosts (QEMU) are tested, so the VM is then amd64; Linux arm64 is untested ([install](install.md#linux)). Intel Macs are unsupported, Windows is out of scope (Ansible needs WSL2) |
| Pinned package versions | Every apt package a role installs by name is pinned and held. Their dependencies are not pinned |
| Debian apt pins stay installable | `snapshot.debian.org` at one pinned timestamp is a fallback next to the live mirrors, not the only source: it is slower and can rate-limit. `apt update` needs it reachable (B-027) |
| Pinned versions in general | We take the newest release that is **at least 2 weeks old**, with arm64 and amd64 builds |
| Requirement 3: app pods accept only the traffic they need | Traffic from other pods and networks. Traffic from the node itself is always allowed by Kubernetes and Calico ([ADR 0003](decisions/0003-traefik-ingress.md)). Accepted by the user, 2026-11-19 |
| Requirement 6: node and etcd alerts fire in Alertmanager | The default node and etcd rules are loaded and healthy, the always-on `Watchdog` reaches Alertmanager, and `promtool` tests show the alerts fire on bad input. Breaking a real node or etcd takes minutes and disrupts the cluster, so that is a manual [demo](runbooks/alert-demo.md). Alerts only need to reach Alertmanager, so it has no receivers |
| The VM is "almost air-gapped" (Lima or the reviewer's; user, 2026-11-23: the only scenario) | Open: SSH from the reviewer's machine to the VM, and internet on that machine (it clones the repo and runs the `curl`). Closed: the VM's own internet and DNS, except NTP (udp/123) to pinned server IPs so the clock syncs (B-094). So the VM downloads through the reviewer's machine (`egress=host`), only from the pinned sources, and a firewall on the VM blocks everything else; `egress=proxy` covers a VM behind the reviewer's proxy ([install guide](install.md#internet-access-from-the-vm)). The VM still needs an IPv4 default route for kubeadm |
| "From a clean VM" with a reviewer's own VM | The VM is a fresh Debian 13 install with nothing container- or Kubernetes-related on it; the playbook takes over swap, kernel settings, apt holds, containerd and kubeadm. Over SSH the host's 443/80/6443 come from a tunnel that accepts local connections only, like Lima's forwards ([install guide](install.md#your-own-debian-13-vm-over-ssh-instead-of-lima)) |
| Requirement 7: snapshots stored outside the cluster | Outside the VM too: in `./backups` on the Mac. With your own VM over SSH (`external-vm.conf`) there is no host mount and the VM may be air-gapped, so the host pulls them into `./backups/external` every 30 minutes while its tunnel runs (B-063). Accepted (2026-11-23): while the host is off or the tunnel is down, the newest snapshots exist only on the VM |
| Requirement 8: application workloads | Pods in `app_namespaces` (today `llm`). Platform parts (network plugin, monitoring, ingress, storage) may get host access where they really need it ([ADR 0007](decisions/0007-pod-security-restricted.md)) |
| Requirement 8c: every API request recorded | Audit log at `Metadata` level for all requests, no `None` rules. The `RequestReceived` stage is skipped; each request is still logged when it finishes |

## Accepted risks

Decided by the user. Smaller (Low) risks are listed in each ADR under Consequences.

| Risk | Why accepted | Until |
|---|---|---|
| **runc 1.1.15** has known container-escape CVEs (CVE-2025-31133, 52565, 52881). Debian trixie has no fixed build (B-026) | Single-user local VM that runs only our own workloads, all `restricted` | trixie-security ships a fix, or before any shared use |
| **Many parallel unbounded `/api/v1/series` calls** can crash Prometheus: no server-side cap exists, the query limits skip that path (B-043) | Needs admin access (port-forward or API proxy) or Grafana admin via the datasource proxy. Grafana is capped (`seriesLimit` 5000); 4 parallel full calls fit, 8 do not ([runbook](runbooks/prometheus-memory.md)). Prometheus restarts in seconds with its data intact | Prometheus adds a series cap, or before any shared use |
| **Cluster CA keys and ServiceAccount signing key on the Mac** (`.secrets/kubeadm-pki/`, 0600): whoever reads them can mint cluster-admin certificates and tokens, and they no longer change with a VM rebuild ([ADR 0006](decisions/0006-etcd-backups-outside-cluster.md#restore-on-a-rebuilt-vm)) | Same protection as the ingress CA key next to them; lets an etcd snapshot restore onto a rebuilt VM without restarting every pod or reissuing tokens. A rebuild no longer revokes leaked credentials: delete the folder and rebuild for that | Before any shared use |
| **Switching between Lima and your own VM keeps the old egress tunnel** (one socket per user, not per target): the new VM's downloads fail until the tunnel is restarted (B-095) | Fails closed (downloads stop, nothing leaks); only when one checkout drives both VMs. Fix: `make vm-down` (Lima) or stop the tunnel before switching | A workflow that switches targets |
| **A firewall rules file that fails to load leaves the VM without the air gap** (the reload handler restarts the unit: delete, then load) until the next good `make provision` (B-099) | Only an edited, broken template triggers it; `make provision` then fails loudly and `make verify` check 1 fails. The shipped rules load (e2e) | Before any change to the air-gap rules |
| **Node and host-network processes** can reach app pods ([ADR 0003](decisions/0003-traefik-ingress.md)) | Kubernetes always allows node-to-pod traffic; only platform parts run there | — |
