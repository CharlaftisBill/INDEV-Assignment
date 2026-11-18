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
 │  │ Traefik (hostNetwork :80/:443) ──► Service llm ──► llama.cpp pod     │ │
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
| 6 | `pki` | cert-manager | 4 |
| 7 | `ingress_traefik` | traefik | 4 |
| 8 | `monitoring` | monitoring | 6 |
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
| Calico (tigera-operator + CRDs charts) | v3.33.0 (operator v1.44.0) | docs.tigera.io/calico/charts; supports Kubernetes 1.35-1.37 |
| local-path-provisioner | — | M4 |
| cert-manager | — | M5 |
| Traefik | — | M5 |
| kube-prometheus-stack | — | M6 |
| llama.cpp server image | — | M9 |
| Model | Qwen2.5-0.5B-Instruct GGUF Q4 | M9 |

## Control plane notes (`kubeadm` role)

- Pod CIDR 10.244.0.0/16 (Lima uses 192.168.5.0/24); systemd cgroups; API cert SANs add `127.0.0.1`, `localhost` so `out/admin.conf` verifies through the Lima forward.
- Metrics bind to the node IP for Prometheus (M6): kube-controller-manager and kube-scheduler `bind-address`, kube-proxy `:10249`, etcd `listen-metrics-urls` `127.0.0.1:2381` (first, for the probe) plus node IP:2381. Lima forwards none of these.
- The kubeadm config is read only by the first `kubeadm init`; later changes need `make vm-reset`. Audit policy and PSA config are re-read by an API server restart handler.
- Pod Security defaults: [ADR 0007](decisions/0007-pod-security-restricted.md).

## Traffic allowed into application pods (`llm` namespace)

| From | To | Port | Why |
|---|---|---|---|
| Traefik pods (`traefik` ns) | llama.cpp | 8080/TCP | ingress |
| Prometheus (`monitoring` ns) | llama.cpp | 8080/TCP `/metrics` | monitoring |
| everything else | — | — | denied (default-deny ingress + egress) |

Only the model-fetch Job gets egress (DNS + 443) to download the model once.
