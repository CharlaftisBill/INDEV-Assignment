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
| 4 | `cni_calico` | tigera-operator, calico-system | 3 |
| 5 | `storage` | local-path-storage | 5 |
| 6 | `pki` | cert-manager | 4 |
| 7 | `ingress_traefik` | traefik | 4 |
| 8 | `monitoring` | monitoring | 6 |
| 9 | `etcd_backup` | — (systemd on the node) | 7 |
| 10 | `hardening` | — (cluster RBAC) | 8a |
| 11 | `llm_app` | llm | 9, 3, 8b |

## Components and versions

Filled from `ansible/group_vars/all/versions.yml` as milestones land.

| Component | Version | Source |
|---|---|---|
| Debian | 13 (trixie) genericcloud arm64 | cloud.debian.org |
| containerd | — | M1 |
| Kubernetes (kubeadm/kubelet/kubectl) | — | M2 |
| Calico | — | M3 |
| local-path-provisioner | — | M4 |
| cert-manager | — | M5 |
| Traefik | — | M5 |
| kube-prometheus-stack | — | M6 |
| llama.cpp server image | — | M9 |
| Model | Qwen2.5-0.5B-Instruct GGUF Q4 | M9 |

## Traffic allowed into application pods (`llm` namespace)

| From | To | Port | Why |
|---|---|---|---|
| Traefik pods (`traefik` ns) | llama.cpp | 8080/TCP | ingress |
| Prometheus (`monitoring` ns) | llama.cpp | 8080/TCP `/metrics` | monitoring |
| everything else | — | — | denied (default-deny ingress + egress) |

Only the model-fetch Job gets egress (DNS + 443) to download the model once.
