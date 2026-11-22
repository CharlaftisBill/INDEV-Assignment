# TODO

Live project state and bug tracker. Agents read this first and update it last (protocol in `CLAUDE.md`).

## Status
Current milestone: **Done (M1–M10)** · macOS arm64 re-check after Linux support: 2026-11-22 (existing VM, `main` e917108: provision + idempotency changed=0, 314 PASS strict, smoke OK) · Linux amd64 host: 2026-11-22 (Ubuntu 24.04, fresh VM: idempotency changed=0, 314 PASS strict, smoke OK) · Last verified: 2026-11-21 PKI persistence (`make e2e` twice, 314 PASS each; after a rebuilt-VM etcd restore 1: 19, 2: 21, 3a: 15, 3b: 18, 4: 48, 5: 15, 6: 76, 7: 23, 8a: 35, 8b: 19, 8c: 8, 9: 17 PASS, strict) · Before: 2026-11-20 M10 final gate (`make e2e` from a destroyed VM 313 PASS; after the review fixes: `make idempotency` changed=0; 1: 19, 2: 20, 3a: 15, 3b: 18, 4: 48, 5: 15, 6: 76, 7: 23, 8a: 35, 8b: 19, 8c: 8, 9: 17 PASS · 0 FAIL · 0 SKIP, strict) · Last SRE review: working tree 2026-11-22 — clean (Linux host support r1, incl. VM restart)

## Milestones
- [x] M0 Scaffolding: repo layout, agentic layer (`.claude/`), Makefile, lint configs, Lima config, docs skeleton, commit tooling (`split-commits` skill, `.githooks/commit-msg`)
- [x] M1 VM up + `os_prep` + `containerd` (req 1)
- [x] M2 `kubeadm`: init, untaint, audit policy, PSA admission config, metrics binds, `out/admin.conf` (req 2, 8c)
  - Cross-role: `containerd` template sets `sandbox_image` to kubeadm's pause (`pause_image_tag`), else kubeadm preflight warns and two pause images are used.
- [x] M3 `cni_calico` (req 3a)
- [x] M4 `storage`: local-path-provisioner as default StorageClass (req 5)
- [x] M5 `pki` + cert-manager + `ingress_traefik` (req 4)
  - Cross-role: `lima/k8s.yaml` (M1) forwards Mac 443→8443 and 80→8000 so Traefik stays non-root (B-009).
- [x] M6 `monitoring`: kube-prometheus-stack, node + etcd alerts, Grafana ingress (req 6)
- [x] M7 `etcd_backup`: systemd timer → host `./backups`, staleness alert (req 7)
- [x] M8 `hardening`: operator read-only role + kubeconfig (req 8a)
- [x] M9 `llm_app`: llama.cpp + model cache + NetworkPolicies + PSA-restricted namespace + TLS ingress (req 9, 3b, 8b)
- [x] M10 Final (all IDs: 1 2 3a 3b 4 5 6 7 8a 8b 8c 9): `make e2e` from a destroyed VM, full security review, docs pass (Backlog items marked "before M10" must be done first)

## Backlog
- [x] **Docs rewrite** (2026-11-20, `chore/docs-rewrite`): README + `docs/` in simple language, one topic per file ([index](docs/README.md)). New: `install.md`, `usage.md`, `versions.md`, `docs/ai-workflow/` (split), runbooks `grafana`/`alert-demo`/`prometheus-memory` (split from `monitoring.md`). Paths fixed in `CLAUDE.md`, `docs-writer`, `review-loop`, `fix-next-bug`, `pin-version`.
  - Bugs moved out of this file to [docs/ai-workflow/bugs.md](docs/ai-workflow/bugs.md), grouped by milestone with an Open list; `scripts/check_todo.py` → `check_bugs.py`; `bug` skill, agents and skills updated.
- [x] **Make-only bootstrap + host uninstall** (2026-11-20, `chore/make-bootstrap`, [ADR 0012](docs/decisions/0012-host-toolchain.md)). Replaces the "Host uninstall" item; only `make` is needed on the host.
  - [x] `make doctor` (read-only, OK / MISSING / WRONG VERSION + fix); quiet subset before `make verify` and `make e2e`
  - [x] `make deps`: pinned, sha256-checked Python 3.14, kubectl v1.35, jq, Lima 2.3.0, shellcheck in `.tools/` (pins: `host_*` in `versions.yml`); idempotent; sudo steps shown and asked
  - [x] `make uninstall` (asks per step, `DRY_RUN=1`, `.secrets/` only with `PURGE_SECRETS=1` + B-037 warning), `scripts/hosts-entry.sh --remove`, system changes only from `.tools/system-manifest`. `PURGE_DEPS` dropped: make no longer installs Homebrew packages
  - [x] `.claude/settings.json`: `make doctor` allowed; `make deps`, `make uninstall` ask. README "Host installation" + "Uninstall"
  - Cross-cutting: the Makefile names directly exec'd tools by path (GNU make 3.81 ignores the exported PATH there, so `make lint`/`collections` could hit Homebrew copies). `scripts/verify.sh`: shellcheck fixes, no behaviour change (shellcheck now always runs in `make lint`)
  - Checked on this Mac: `make lint` clean; `make deps` twice (2nd installs nothing; the sudo hosts step is re-offered while declined); fresh copy with PATH=/usr/bin:/bin → deps + lint OK; VM restarted by the repo-local `limactl`; `make verify REQ=1 STRICT=1` 17 PASS
  - [x] Follow-ups (M10, `feat/m10-final`): recipes run via `scripts/make-shell.sh` (`-eu -o pipefail` on make 3.81 too; `.SHELLFLAGS` alone was ignored); `check_9` accepts llama.cpp restarts only with last reason `Unknown` (node restart), crashes still fail
- [x] **Linux host support** (target: before M10). Host tooling is OS-aware since the bootstrap above; the VM config is portable since M10; tested on Ubuntu 24.04 amd64 2026-11-22.
  - [x] `lima/k8s.yaml`: drop the hard-coded `vmType: vz` and `mountType: virtiofs` so Lima picks its default (vz on macOS, qemu on Linux)
  - [x] `make deps` detects OS/arch; Lima release binary on both, QEMU distro packages on Linux (asked, recorded in the manifest)
  - [x] Port 443 on Linux: `make doctor` checks `net.ipv4.ip_unprivileged_port_start`; `make deps` offers the sysctl (asked), uninstall reverts it
  - [x] `scripts/hosts-entry.sh`: only flush the macOS DNS cache on macOS
  - [x] README + `CLAUDE.md`: host support listed in README; Linux install steps once `lima/k8s.yaml` is portable
  - [x] Test on a Linux host (2026-11-22, `chore/linux-host-support`, Ubuntu 24.04 amd64, KVM): B-056 per-arch apt pins, B-057 GNU `stat`, B-058 x86_64 `generic` image + 9p (virtiofs filled `/dev/shm`); fresh-clone CA now asked in `make provision`. `make provision` OK, `make idempotency` changed=0, 1: 19, 2: 21, 3a: 15, 3b: 18, 4: 48, 5: 15, 6: 76, 7: 23, 8a: 35, 8b: 19, 8c: 8, 9: 17 PASS strict (314), `make smoke` OK. Linux arm64 untested

- [x] **Keep the kubeadm PKI across VM rebuilds** (2026-11-21, `chore/persist-kubeadm-pki`, [ADR 0006](docs/decisions/0006-etcd-backups-outside-cluster.md#restore-on-a-rebuilt-vm)).
  `kubeadm` role saves cluster/front-proxy/etcd CAs + SA keys to `.secrets/kubeadm-pki/` after the first init, restores
  them before init on a new VM; `check_2` compares the public halves. Two `make e2e` runs: 314 PASS each, same CA
  fingerprint. Old-VM snapshot restored onto the second VM without pod mass-restart or token reissue; kubelet
  restart added to the runbook (B-053); 12 IDs strict PASS after it.

- [x] **Prometheus/Alertmanager UI access** (2026-11-21, `chore/monitoring-ui-port-forward`). `make monitoring-ui` port-forwards both to
  `127.0.0.1:9090/9093` until Ctrl-C ([usage](docs/usage.md#web-pages)); no Ingress since neither has a login. Tested: both `/-/ready`
  200 through the forwards, Ctrl-C exits 0, busy port fails clearly; shellcheck clean.

- [x] **Terminal chat** (2026-11-21, `chore/llm-chat-tui`). `make chat` (`scripts/chat.sh`, curl + jq): streams replies, keeps
  history, `/reset`, `/quit`. Tested on the live model: history recalled, reset forgets, a 404 is reported and the chat goes on.

## Bugs
All bugs, Open and Solved, are in [docs/ai-workflow/bugs.md](docs/ai-workflow/bugs.md) (format: `bug` skill).

## Assumptions
How we read unclear parts of the assignment, and accepted risks: [docs/assumptions.md](docs/assumptions.md).
