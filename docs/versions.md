# Versions

The source of truth is [`ansible/group_vars/all/versions.yml`](../ansible/group_vars/all/versions.yml).
It also holds every image digest and checksum. This page is a readable copy; update it when a pin changes.
Host tools (Python, Lima, kubectl …) are listed in the [install guide](install.md#tools-it-installs).

All apt packages are held (`apt-mark hold`), so upgrades never change them.

## Node

| Component | Version | Source |
|---|---|---|
| Debian | 13 (trixie) build 20261103-2651: genericcloud arm64 (Mac), generic amd64 (Linux, has 9p; B-058) | cloud.debian.org; sha512 in `lima/k8s.yaml` |
| containerd | 1.7.24~ds1-6+deb13u1 | Debian |
| runc | 1.1.15+ds1-2+b4 | Debian. Known CVEs accepted (B-026) |
| Base packages (9) | see `os_base_packages` | Debian |
| kubeadm, kubelet, kubectl | 1.35.10-1.1 | pkgs.k8s.io; signing key `DE15B144…9A296436` checked |
| cri-tools, kubernetes-cni | 1.35.0-1.1, 1.8.0-1.1 | pkgs.k8s.io |
| pause image | 3.10.1 | from `kubeadm config images list` |
| python3-kubernetes | 30.1.0-2 | Debian. Ansible's `kubernetes.core` modules run on the VM |
| Helm | v4.3.1 | get.helm.sh, sha256 pinned |
| etcdctl, etcdutl | v3.6.6 | GitHub releases, sha256 pinned. Matches kubeadm's etcd `3.6.6-0` |

Notes:
- **Kubernetes 1.35** is the last minor version that supports containerd 1.x, and trixie has no containerd 2.x.
  Moving past 1.35 needs containerd 2.x. containerd's release notes recommend 1.7.28+ for 1.35; Debian's 1.7.24 is
  used as is. kubelet logs `RuntimeConfig not implemented` and uses its own `cgroupDriver: systemd`; this is expected.
- **containerd 1.7** uses config `version = 2`. Its pause image is set to kubeadm's (`pause_image_tag`).
- **Debian keeps only the newest point release**, so `os_prep` also adds `snapshot.debian.org` sources at one pinned
  timestamp (`debian_snapshot_timestamp`). The live mirrors stay first (faster); apt falls back to the snapshot for a
  version the mirror no longer has. Packages from `pkgs.k8s.io` are unaffected (B-027).
- **`apt-transport-https`** is not installed: it is an empty package; apt 3.x has HTTPS built in.
- **python3-kubernetes** comes from Debian, not a pip venv. A venv needs `python3.13-venv`, whose version changes
  with every Python security update, and pip would pull unpinned dependencies.
- **pkgs.k8s.io signing key** expires 2026-12-29. The role downloads it on each run and checks the fingerprint, so a
  renewed key is picked up.

## Cluster add-ons

Images are pinned by digest (`tag@sha256:…`), and each has an arm64 build.

| Component | Version | Source |
|---|---|---|
| Calico | v3.33.0 (tigera-operator v1.44.0) | docs.tigera.io/calico/charts |
| local-path-provisioner | v0.0.37 | own templates, copied from upstream `deploy/local-path-storage.yaml` |
| busybox | 1.38.0 | storage helper pod and the `check_5` test pod |
| cert-manager | chart v1.21.3 | charts.jetstack.io |
| Traefik | chart 42.3.0, image v3.7.17 | traefik.github.io/charts |
| kube-prometheus-stack | chart 92.18.0 | prometheus-community.github.io/helm-charts |
| llama.cpp server | `ghcr.io/ggml-org/llama.cpp:server-b12110` | github.com/ggml-org/llama.cpp; also used by the model download Job |
| Model | Qwen2.5-0.5B-Instruct Q4_K_M, 491400032 bytes | Hugging Face `Qwen/Qwen2.5-0.5B-Instruct-GGUF`, commit `9217f5db…`, sha256 `74a4da8c…d7a9db` |

kube-prometheus-stack images:

| Image | Version |
|---|---|
| prometheus-operator, config-reloader | v0.94.2 |
| Prometheus | v3.15.1-distroless |
| Alertmanager | v0.34.2 |
| Grafana | 13.3.0-distroless |
| k8s-sidecar | 2.14.3 |
| kube-state-metrics | v2.20.0 |
| node-exporter | v1.12.1 |

To change a version, use the `pin-version` skill.
