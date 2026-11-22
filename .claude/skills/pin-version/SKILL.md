---
name: pin-version
description: Find, verify and record an exact version (apt package, Helm chart, image tag+digest with arm64+amd64, binary, collection, base image) in ansible/group_vars/all/versions.yml. Use when a role needs a new dependency or a version bump.
effort: medium
---

# Pin a version

Everything ends up in `ansible/group_vars/all/versions.yml`:
```yaml
kubernetes_version: "1.xx.y-1.1"   # pkgs.k8s.io/core:/stable:/v1.xx/deb, apt-cache madison, 2026-11-18
```
Never `latest`, never a floating tag (`:server`, `:v1`), never an unpinned apt install.

## Where to look (run lookups against the VM when the answer depends on the OS/arch)
| Kind | Lookup |
|---|---|
| apt package | `limactl shell k8s -- apt-cache madison <pkg>` (after the repo is added). Pin with `name: "<pkg>={{ ver }}"` and hold it with `ansible.builtin.dpkg_selections: selection=hold`. A binNMU suffix (`+bN`) is per arch: check the amd64 pool too and use `{arm64: …, amd64: …}` if they differ |
| Kubernetes | repo path pins the minor (`/v1.xx/`); `apt-cache madison kubeadm` gives the full `1.xx.y-1.1`. kubelet/kubeadm/kubectl/cri-tools must agree |
| Helm chart | `helm repo add <r> <url> && helm search repo <r>/<chart> --versions | head` (on the VM, helm is installed in M2). Record `chart_version`, and the app version it ships in the comment |
| Image | `skopeo inspect --raw docker://<image>:<tag>` or `crane manifest` / `docker buildx imagetools inspect <image>:<tag>` on the Mac. Confirm `arm64` and `amd64` entries, then pin `<image>:<tag>@sha256:<index digest>` |
| GitHub binary | release page / `gh release list -R <owner>/<repo>`; also pin the checksum (`ansible.builtin.get_url` with `checksum: sha256:...`) |
| Model file | Hugging Face file page; record URL with an exact revision (commit) and `sha256` |
| Lima base image | dated directory under `https://cloud.debian.org/images/cloud/trixie/` + its `SHA512SUMS` → `digest: sha512:...` in `lima/k8s.yaml` |

## Compatibility checks before committing a pin
- Kubernetes ↔ Calico, cert-manager, kube-prometheus-stack, Traefik: check each project's supported-versions table for the chosen Kubernetes minor.
- etcdctl/etcdutl must match the etcd version kubeadm deploys (`kubeadm config images list`).
- Prefer the newest patch of a release that is at least ~2 weeks old.

## After pinning
- Comment = source + date. Mention notable constraints (e.g. "max k8s 1.xx per Calico docs").
- If `docs/versions.md` lists the component, the docs-writer agent will sync it; mention the bump in your report.
