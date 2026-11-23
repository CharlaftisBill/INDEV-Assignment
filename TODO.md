# TODO

Live project state and bug tracker. Agents read this first and update it last (protocol in `CLAUDE.md`).

## Status
Current milestone: **Done (M1–M10)** · No open bugs (B-095, B-099 accepted as risks by the user, 2026-11-23) · B-097 + B-098 fixed 2026-11-23 (`fix/b-097-airgap-cidrs`: off-node pod/Service CIDRs rejected, pod-backed ClusterIPs reachable; whole-playbook idempotency changed=0, 320 PASS strict) · B-094 fixed 2026-11-23 (NTP through the air gap: REQ=1 22 PASS strict, idempotency changed=0); Low bugs dropped from the tracker (user, 2026-11-23: Lows are not logged) · `make e2e` on main 1b59268 (after B-094, B-071..B-073, B-097/B-098): 2026-11-23, destroyed VM, 320 PASS strict, idempotency changed=0, smoke OK · Before: `make e2e` on main 495bed4 (air gap everywhere): 315 PASS strict · Own VM over SSH: 2026-11-22 (stand-in Debian 13 VM: idempotency changed=0, 314 PASS strict, smoke OK; Lima re-check 314 PASS); air-gapped 2026-11-23 (313 PASS strict, smoke OK) · macOS arm64 re-check after Linux support: 2026-11-22 (existing VM, `main` e917108: provision + idempotency changed=0, 314 PASS strict, smoke OK) · Linux amd64 host: 2026-11-22 (Ubuntu 24.04, fresh VM: idempotency changed=0, 314 PASS strict, smoke OK) · Last verified: 2026-11-21 PKI persistence (`make e2e` twice, 314 PASS each; after a rebuilt-VM etcd restore 1: 19, 2: 21, 3a: 15, 3b: 18, 4: 48, 5: 15, 6: 76, 7: 23, 8a: 35, 8b: 19, 8c: 8, 9: 17 PASS, strict) · Before: 2026-11-20 M10 final gate (`make e2e` from a destroyed VM 313 PASS; after the review fixes: `make idempotency` changed=0; 1: 19, 2: 20, 3a: 15, 3b: 18, 4: 48, 5: 15, 6: 76, 7: 23, 8a: 35, 8b: 19, 8c: 8, 9: 17 PASS · 0 FAIL · 0 SKIP, strict) · Last SRE review: working tree 2026-11-23 — 5 new bugs (B-092..B-095, B-097; air-gap final)

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
- [x] **Air gap as the only scenario** (user, 2026-11-23, `chore/airgap-only`, 49653ef..2d81ce0): the VM never uses its own internet, whether Lima creates it or the reviewer gives it. B-071..B-073 deferred by the user to keep it on schedule. Checked: e2e from a destroyed Lima VM (provision OK, idempotency changed=0, 315 PASS strict incl. firewall + no direct internet, smoke OK).
  - [x] Lima uses the same egress path as the own VM: `ssh -R` via `~/.lima/k8s/ssh.config` to `scripts/egress-proxy.py` + allowlist; `vm_proxy_url` always set (drop `egress=direct`?)
  - [x] Enforce it: the playbook firewalls the VM's outbound traffic (nftables, as the 2026-11-23 test), so the air gap is real on Lima too
  - [x] Model always from the host (`llm_app_model_from_host` default true); `llm` keeps no egress policy; remove `allow-dns`/`allow-model-download` code paths
  - [x] `verify.sh` check_3b: one (air-gap) branch only; add a check that the VM cannot reach the internet directly
  - [x] Docs: README, install, architecture, ADR 0001/0008, assumptions, requirements matrix; then `make e2e` from a destroyed VM
- [x] **External VM over SSH** (2026-11-22, `chore/external-vm-support`, c843493..7663012, [install guide](docs/install.md#your-own-debian-13-vm-over-ssh-instead-of-lima)): `external-vm.conf` switches make, Ansible (`inventory/external.yml`) and `verify.sh` from Lima to a reviewer's Debian 13 VM over SSH (`scripts/external.sh`: checks, tunnel, `backups-pull`; `etcd_backup_require_mount: false`). `user=root` supported (no sudo). Lima path unchanged.
  - Tunnel: B-061 (macOS refuses non-root `127.0.0.1:443`) → ssh to 18443/18000 + loopback-only `scripts/loopback-forward.py` on 443/80.
  - Cross-role: `llm_app` drops a redundant per-task `become: true` (root login without sudo).
  - Air-gapped VM (2026-11-23, user: the reviewer's VM is "almost air-gapped"): `egress=host` (default) sends the VM's downloads through the host (`ssh -R` + `scripts/egress-proxy.py`, allowlist `scripts/egress-allowlist.txt`, B-062); `egress=proxy|direct`. Ansible: `vm_proxy_url` → apt conf, containerd drop-in, play `environment`; `llm_app_model_from_host` (host downloads + copies the model, no egress policies in `llm`); `check_3b` air-gap aware. Cross-role: `os_prep`, `containerd`, `llm_app`, `site.yml` (needed by the air gap).
  - Tested 2026-11-23 on a stand-in VM with an nftables firewall (no internet, no DNS; ~9.5k packets rejected): provision OK, idempotency changed=0, verify 313 PASS strict, smoke OK; 21 allowlisted hosts used. Lima after: provision changed only `admin.conf`, idempotency changed=0, 314 PASS strict, smoke OK.
  - review-loop 2026-11-23: r1 B-063..B-066, r2 B-067..B-070 + B-066 reopened (max 2 rounds hit); all fixed after r2 (snapshot pull reworked: `./backups/external/`, new names only, strict names, process-group loop). Checked: air-gapped stand-in provision OK, idempotency changed=0, 315 PASS strict, smoke OK, REQ=7 with the loop's own pull 25 PASS; Lima after: idempotency changed=0, 314 PASS strict, smoke OK. Final re-review pending (user).
  - Bug IDs: B-059/B-060 are on `fix/b-060-hosts-rewrite-safety` (hosts `::1` line); this branch's lint passes once that merges and `main` is merged in.
  - Tested 2026-11-22 on a stand-in VM (plain Debian 13 Lima VM, no forwards/mounts, reached only over SSH): `make vm-up`, `make provision` OK, `make idempotency` changed=0 (also as `root`), `make verify STRICT=1` 314 PASS, `make smoke` OK, vm-reset/e2e refuse, uninstall leaves the VM. Lima re-check after: idempotency changed=0, 314 PASS strict, smoke OK. **Not tested:** a non-Lima hypervisor, Linux host with own VM.
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

- [x] **IPv6 hosts line** (2026-11-23, `fix/b-059-hosts-ipv6-entry`, B-059). `scripts/hosts-entry.sh` adds/removes `::1` next to
  `127.0.0.1`; `make doctor` requires both. macOS lookup 5.005 s → 0.004 s, `make smoke` OK, `make lint` clean.

## Bugs
All bugs, Open and Solved, are in [docs/ai-workflow/bugs.md](docs/ai-workflow/bugs.md) (format: `bug` skill).

## Assumptions
How we read unclear parts of the assignment, and accepted risks: [docs/assumptions.md](docs/assumptions.md).
