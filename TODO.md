# TODO

Live project state and bug tracker. Agents read this first and update it last (protocol in `CLAUDE.md`).

## Status
Current milestone: **M1 — VM up + os_prep + containerd** · Last verified: — (no cluster yet)

## Milestones
- [x] M0 Scaffolding: repo layout, agentic layer (`.claude/`), Makefile, lint configs, Lima config, docs skeleton, commit tooling (`split-commits` skill, `.githooks/commit-msg`)
- [ ] M1 VM up + `os_prep` + `containerd` (req 1)
- [ ] M2 `kubeadm`: init, untaint, audit policy, PSA admission config, metrics binds, `out/admin.conf` (req 2, 8c)
- [ ] M3 `cni_calico` (req 3)
- [ ] M4 `storage`: local-path-provisioner as default StorageClass (req 5)
- [ ] M5 `pki` + cert-manager + `ingress_traefik` (req 4)
- [ ] M6 `monitoring`: kube-prometheus-stack, node + etcd alerts, Grafana ingress (req 6)
- [ ] M7 `etcd_backup`: systemd timer → host `./backups`, staleness alert (req 7)
- [ ] M8 `hardening`: operator read-only role + kubeconfig (req 8a, 8b)
- [ ] M9 `llm_app`: llama.cpp + model cache + NetworkPolicies + TLS ingress (req 9, 3)
- [ ] M10 Final: `make e2e` from a destroyed VM, full security review, docs pass (Backlog items marked "before M10" must be done first)

## Backlog
- [ ] **Linux host support** (target: before M10). Today the host side is Mac-only; everything inside the VM is already portable.
  - [ ] `lima/k8s.yaml`: drop the hard-coded `vmType: vz` and `mountType: virtiofs` so Lima picks its default (vz on macOS, qemu on Linux)
  - [ ] `Makefile` `deps`: detect the OS; Homebrew on macOS, distro packages / Lima release binary on Linux
  - [ ] Port 443 on Linux: unprivileged users can't bind ports < 1024, so Lima can't forward 443. Add a Makefile preflight that checks `net.ipv4.ip_unprivileged_port_start` and prints the `sysctl` fix
  - [ ] `scripts/hosts-entry.sh`: only flush the macOS DNS cache on macOS
  - [ ] README + `CLAUDE.md`: list host support (tested: Apple Silicon macOS; expected to work, untested: Linux, Intel macOS; unsupported: Windows without WSL2) and Linux install steps
  - [ ] Test on a Linux host if one is available; otherwise keep "untested" in the docs

## Bugs
| ID | Title | State | Milestone | Found | Solved | Notes / fix commit |
|----|-------|-------|-----------|-------|--------|--------------------|
| B-001 | ansible-lint warns "ansible-core 2.21.6 supports Python up to 3.14 and we found 3.15.2" | Open | M10 | 2026-11-17 | | Homebrew builds ansible-lint on Python 3.15. Lint passes; revisit if a rule misbehaves (option: pipx/venv on Python 3.14) |
| B-002 | Pinned collections not installed into `ansible/collections/` ("Nothing to do") | Solved | M0 | 2026-11-17 | 2026-11-17 | 34d85b7 — galaxy skipped because Homebrew's ansible bundles the same collections; `make collections` now uses `--force` behind a stamp file |
| B-003 | First commit run swept 5 previously staged files into the "assignment brief" commit | Solved | M0 | 2026-11-17 | 2026-11-17 | adf6d89 — `git rm --cached` without `-f` failed before `set -e`; local commits redone. `split-commits` skill now requires `-f` on unborn branches and checks the staged list before each commit |

## Assumptions / open questions
- Host is an Apple Silicon Mac → VM is Debian 13 **arm64** under Lima (vz). amd64 image is listed in `lima/k8s.yaml` for Intel hosts but untested. Linux hosts are planned (Backlog), Windows is out of scope (Ansible needs WSL2).
- "Stored outside the cluster" = outside the VM too: snapshots go to `./backups` on the Mac through a Lima mount (gitignored).
- "Every request to the Kubernetes API is recorded" = API server audit log at `Metadata` level or higher for all requests, no `None` rules.
- "Application workloads" = workloads in `app_namespaces` (currently `llm`). Platform namespaces (CNI, monitoring, ingress) are exempt from PSA `restricted` where they genuinely need host access.
- The Lima base image is the Debian "latest" trixie cloud build until M1 pins a dated build.
