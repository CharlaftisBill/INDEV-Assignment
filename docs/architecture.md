# Architecture

```
 macOS host (Apple Silicon)
 ┌──────────────────────────────────────────────────────────────────────────┐
 │  ansible-playbook ──ssh (Lima ssh.config)──┐                              │
 │  curl https://llm.local ──► 127.0.0.1:443 ─┼─ Lima port-forward ──┐       │
 │  kubectl (out/admin.conf, out/operator.conf) ─► 127.0.0.1:6443 ───┤       │
 │  ./backups  ◄──────── virtiofs mount (rw) ──────────────────┐     │       │
 │                                                             │     │       │
 │  Lima VM "k8s": Debian 13 arm64, 4 vCPU / 8 GiB / 40 GiB    │     │       │
 │  ┌──────────────────────────────────────────────────────────┼─────┼─────┐ │
 │  │ containerd · kubelet · kubeadm control plane (etcd, apiserver+audit) │ │
 │  │ etcd-backup.timer ──► /mnt/host-backups ─────────────────┘     │     │ │
 │  │                                                                ▼     │ │
 │  │ Traefik (hostNetwork :8443/:8000) ──► Service llm ──► llama.cpp pod  │ │
 │  │      ▲ TLS cert from cert-manager CA issuer (internal root CA)  │      │ │
 │  │      │                                       PVC (local-path) ◄┘      │ │
 │  │ Calico (NetworkPolicy) · kube-prometheus-stack (Prometheus,          │ │
 │  │ Alertmanager, Grafana, node-exporter)                                │ │
 │  └──────────────────────────────────────────────────────────────────────┘ │
 └──────────────────────────────────────────────────────────────────────────┘
```

## Provisioning order (`ansible/site.yml`)

| # | Role | Namespace(s) | Requirement |
|---|---|---|---|
| 1 | `os_prep` | — | 1 |
| 2 | `containerd` | — | 1 |
| 3 | `kubeadm` | kube-system | 2, 8c |
| 4 | `cni_calico` | tigera-operator, calico-system | 3a |
| 5 | `storage` | local-path-storage | 5 |
| 6 | `pki` | cert-manager (+ root CA on the host) | 4 |
| 7 | `ingress_traefik` | traefik; creates `llm`, `monitoring`, `ingress-check` | 4 |
| 8 | `monitoring` | monitoring (PSA restricted), node-exporter (PSA privileged) | 6 |
| 9 | `etcd_backup` | — (systemd on the node) | 7 |
| 10 | `hardening` | — (cluster RBAC) | 8a |
| 11 | `llm_app` | llm | 9, 3b, 8b |

## Components and versions

Filled from `ansible/group_vars/all/versions.yml` as milestones land.

| Component | Version | Source |
|---|---|---|
| Debian | 13 (trixie) genericcloud arm64, build 20261103-2651 (sha512 in `lima/k8s.yaml`) | cloud.debian.org |
| containerd | 1.7.24~ds1-6+deb13u1 | Debian trixie, held |
| runc | 1.1.15+ds1-2+b4 | Debian trixie, held (known CVEs accepted, B-026) |
| Base packages (9) | see `os_base_packages` in `versions.yml` | Debian trixie, held |
| Kubernetes (kubeadm/kubelet/kubectl) | 1.35.10-1.1 (v1.35 is the last minor supporting containerd 1.x) | pkgs.k8s.io, held; key `DE15B144…9A296436` checked |
| cri-tools / kubernetes-cni | 1.35.0-1.1 / 1.8.0-1.1 | pkgs.k8s.io, held |
| pause image | 3.10.1 | `kubeadm config images list`, set in containerd |
| python3-kubernetes | 30.1.0-2 | Debian trixie, held; `kubernetes.core` modules run on the VM (not the Mac) with the node's admin.conf |
| Helm | v4.3.1 (sha256 pinned) | get.helm.sh, `/opt/helm/<version>` |
| Calico (tigera-operator + CRDs charts) | v3.33.0 (operator v1.44.0) | docs.tigera.io/calico/charts; supports Kubernetes 1.35-1.37; all images pinned by index digest in `versions.yml` ([ADR 0002](decisions/0002-calico-cni.md)) |
| local-path-provisioner | v0.0.37 (`sha256:e757967a…0a86f`) | own templates mirroring upstream `deploy/local-path-storage.yaml` ([ADR 0004](decisions/0004-local-path-storage.md)); image pinned tag@digest |
| busybox | 1.38.0 (`sha256:a46257e0…e5fa4`) | helper pod and `check_5` test pod; arm64 digest pinned |
| cert-manager | chart v1.21.3; controller, webhook, cainjector by digest (`versions.yml`) | charts.jetstack.io, 2026-11-18; internal CA ([ADR 0005](decisions/0005-internal-ca-and-renewal.md)) |
| Traefik | chart 42.3.0, image v3.7.17 (`sha256:f4bb143d…86f5a`) | traefik.github.io/charts, 2026-11-18; Ports 8443 (HTTPS) and 8000 (redirect) on the node, Lima maps Mac 443/80 ([ADR 0003](decisions/0003-traefik-ingress.md)) |
| kube-prometheus-stack | chart 92.18.0; operator and config-reloader v0.94.2, Prometheus v3.15.1-distroless, Alertmanager v0.34.2, Grafana 13.3.0-distroless, k8s-sidecar 2.14.3, kube-state-metrics v2.20.0, node-exporter v1.12.1 (all by digest, `versions.yml`) | prometheus-community.github.io/helm-charts, 2026-11-19 ([ADR 0010](decisions/0010-monitoring-stack.md)) |
| etcdctl / etcdutl | v3.6.6 (tarball sha256 pinned per arch) | github.com/etcd-io/etcd/releases, 2026-11-19; matches kubeadm's etcd `3.6.6-0`; `/opt/etcd`, linked in `/usr/local/bin` ([ADR 0006](decisions/0006-etcd-backups-outside-cluster.md), [restore](runbooks/etcd-restore.md)) |
| llama.cpp server image | `ghcr.io/ggml-org/llama.cpp:server-b12110` (`sha256:1145e8de…10bbe3e`) | github.com/ggml-org/llama.cpp releases, 2026-11-19; also used by the model-fetch Job (curl + sha256sum) |
| Model | Qwen2.5-0.5B-Instruct Q4_K_M, 491400032 bytes (`sha256:74a4da8c…d7a9db`) | Hugging Face `Qwen/Qwen2.5-0.5B-Instruct-GGUF` at commit `9217f5db…`, 2026-11-19 ([ADR 0008](decisions/0008-model-caching.md)) |

## Control plane notes (`kubeadm` role)

- Pod CIDR 10.244.0.0/16 (Lima uses 192.168.5.0/24); systemd cgroups; API cert SANs add `127.0.0.1`, `localhost` so `out/admin.conf` verifies through the Lima forward.
- Metrics bind to the node IP for Prometheus (M6): kube-controller-manager and kube-scheduler `bind-address`, kube-proxy `:10249`, etcd `listen-metrics-urls` `127.0.0.1:2381` (first, for the probe) plus node IP:2381. Lima forwards none of these.
- The kubeadm config is read only by the first `kubeadm init`; later changes need `make vm-reset`. Audit policy and PSA config are re-read by an API server restart handler.
- Pod Security defaults: [ADR 0007](decisions/0007-pod-security-restricted.md).

## Monitoring ports (`monitoring` role)

Prometheus scrapes the node IP: apiserver 6443, kubelet 10250, etcd 2381 (HTTP), controller-manager 10257, scheduler 10259, kube-proxy 10249, node-exporter 9100, Traefik 9101. Grafana is served at `https://grafana.local` through Traefik. Operation: [monitoring runbook](runbooks/monitoring.md).

## Traffic allowed into application pods (`llm` namespace)

| From | To | Port | Why |
|---|---|---|---|
| Node IP /32 (Traefik is hostNetwork) | llama.cpp | 8080/TCP | ingress ([ADR 0003](decisions/0003-traefik-ingress.md)) |
| everything else | — | — | denied (default-deny ingress + egress) |

The llama.cpp pod has no egress. Only pods labelled `component=model-fetch` get DNS + TCP 443 to public IPs (RFC1918, 169.254/16, 100.64/10 excluded), and only while the fetch Job runs ([ADR 0008](decisions/0008-model-caching.md)).
