# TODO

Live project state and bug tracker. Agents read this first and update it last (protocol in `CLAUDE.md`).

## Status
Current milestone: **M7 — etcd_backup** · Last verified: 2026-11-19 final gate M6 (`make idempotency` changed=0; 1: 17, 2: 20, 3a: 15, 4: 48, 5: 15, 6: 73, 8c: 8 PASS · 0 FAIL · 0 SKIP, strict) · Last SRE review: working tree 2026-11-19 — M6 r2 + B-042 re-checks: B-042 holds, B-043 deferred to M10 (user)

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
- [ ] M7 `etcd_backup`: systemd timer → host `./backups`, staleness alert (req 7)
- [ ] M8 `hardening`: operator read-only role + kubeconfig (req 8a)
- [ ] M9 `llm_app`: llama.cpp + model cache + NetworkPolicies + PSA-restricted namespace + TLS ingress (req 9, 3b, 8b)
- [ ] M10 Final (all IDs: 1 2 3a 3b 4 5 6 7 8a 8b 8c 9): `make e2e` from a destroyed VM, full security review, docs pass (Backlog items marked "before M10" must be done first)

## Backlog
- [ ] **Linux host support** (target: before M10). Today the host side is Mac-only; everything inside the VM is already portable.
  - [ ] `lima/k8s.yaml`: drop the hard-coded `vmType: vz` and `mountType: virtiofs` so Lima picks its default (vz on macOS, qemu on Linux)
  - [ ] `Makefile` `deps`: detect the OS; Homebrew on macOS, distro packages / Lima release binary on Linux
  - [ ] Port 443 on Linux: unprivileged users can't bind ports < 1024, so Lima can't forward 443. Add a Makefile preflight that checks `net.ipv4.ip_unprivileged_port_start` and prints the `sysctl` fix
  - [ ] `scripts/hosts-entry.sh`: only flush the macOS DNS cache on macOS
  - [ ] README + `CLAUDE.md`: list host support (tested: Apple Silicon macOS; expected to work, untested: Linux, Intel macOS; unsupported: Windows without WSL2) and Linux install steps
  - [ ] Test on a Linux host if one is available; otherwise keep "untested" in the docs

## Bugs
Index of all bugs (format and rules: `bug` skill). Short rows only; the report, root cause, fix and verification
for each bug are in [Bug details](#bug-details) below.

| ID | Title | Sev | State | Milestone | Found | Solved | Fix |
|----|-------|-----|-------|-----------|-------|--------|-----|
| B-001 | ansible-lint warns: ansible-core 2.21.6 does not support Python 3.15 | — | Solved | M10 | 2026-11-17 | 2026-11-17 | 1949b07 |
| B-002 | Pinned collections not installed into `ansible/collections/` | — | Solved | M0 | 2026-11-17 | 2026-11-17 | 34d85b7 |
| B-003 | First commit run swept 5 previously staged files into the wrong commit | — | Solved | M0 | 2026-11-17 | 2026-11-17 | adf6d89 |
| B-004 | [sre] `make verify` / `make e2e` pass when every check is SKIP | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 0c72290 |
| B-005 | [sec] Agent could read CA key, admin kubeconfig and snapshots without a prompt | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 6ba2a85 |
| B-006 | [sre] `review-loop` cannot stop while later-milestone bugs are Open | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | dfc00b7 |
| B-007 | [sre] Host kubeconfig at 127.0.0.1:6443 fails TLS (no loopback SAN) | Medium | Solved | M2 | 2026-11-17 | 2026-11-18 | ba24ebb |
| B-008 | [sec] "Allow from Traefik" NetworkPolicy cannot match a hostNetwork Traefik | Medium | Solved | M5 | 2026-11-17 | 2026-11-19 | 144f11c |
| B-009 | [sre] hostNetwork Traefik cannot bind :443/:80 as non-root | Medium | Solved | M5 | 2026-11-17 | 2026-11-19 | e31f4da |
| B-010 | [sre] etcd snapshots can silently land on the VM disk | Medium | Open | M7 | 2026-11-17 |  |  |
| B-011 | [sec] Secrets still readable unprompted via other `get` spellings (B-005 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 6ba2a85 |
| B-012 | [sre] Milestone gate and `bug solve` still accept SKIP (B-004 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | dfc00b7 |
| B-013 | [sre] Strict verify is per requirement, but req 3 and 8 span milestones | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 0c72290 |
| B-014 | [sre] Close gate, `bug` skill and workflow doc kept pre-B-006 rules | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | dfc00b7 |
| B-015 | [sec] Secrets readable unprompted via mixed-case kinds (B-011 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 6ba2a85 |
| B-016 | [sre] Secret deny rules hard-block harmless inspection commands | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 6ba2a85 |
| B-017 | [sre] Final strict verify ran before the review-loop fixes (B-012 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | dfc00b7 |
| B-018 | [sec] Secrets dumpable unprompted via the operator kubeconfig allow (B-015 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 6ba2a85 |
| B-019 | [sec] `make`, `git diff` and `ansible` allow rules run arbitrary commands unprompted | Medium | Solved | M0 | 2026-11-17 | 2026-11-17 | 9277b57 |
| B-020 | [sec] Pre-approved `make verify`/`provision` still run any command or `vm-destroy` (B-019 follow-up) | Medium | Solved | M0 | 2026-11-17 | 2026-11-18 | f92e955 |
| B-021 | [sre] Agent/skill make commands (quoted `REQ`, multi-ID, `TAGS=a,b`) miss the exact allows, prompt | Medium | Solved | M0 | 2026-11-18 | 2026-11-18 | 49d3ebc |
| B-022 | [sre] B-021 rewrite narrowed the DoD idempotency gate from whole playbook to per role | Medium | Solved | M0 | 2026-11-18 | 2026-11-18 | 951c425 |
| B-023 | `make ping`/Ansible can't reach the VM: ssh `-F ~/.lima/...` is not tilde-expanded | High | Solved | M0 | 2026-11-18 | 2026-11-18 | 4c6ed45 |
| B-024 | [sre] containerd restart deferred to play end: M2 kubeadm init would run on Debian's default config | Medium | Solved | M1 | 2026-11-18 | 2026-11-18 | c28a8f0 |
| B-025 | [sec] Lima catch-all `ignore` misses 0.0.0.0/:: and UDP listeners: guest ports reach Mac loopback | Medium | Solved | M1 | 2026-11-18 | 2026-11-18 | 6364132 |
| B-026 | [sec] Pinned runc 1.1.15 lacks fixes for the Nov-2025 container-escape CVEs | Medium | Solved | M1 | 2026-11-18 | 2026-11-18 | 2ba39bb |
| B-027 | [sre] Exact Debian apt pins vanish after the next DSA/point release: clean rebuild fails | Medium | Open | M10 | 2026-11-18 |  |  |
| B-028 | [sec] regression of B-025: catch-all ignore no longer matches 127.0.0.1; loopback ports forwarded | Medium | Solved | M1 | 2026-11-18 | 2026-11-18 | 6ea9ce9 |
| B-029 | [sre] kubeadm init rescue runs `kubeadm reset --force` on an existing cluster: wipes etcd | Medium | Solved | M2 | 2026-11-18 | 2026-11-18 | 9236ac4 |
| B-030 | [sec] Calico images (privileged, hostNetwork) pulled by mutable tag only, no digest pins | Medium | Solved | M3 | 2026-11-18 | 2026-11-18 | 7e58592 |
| B-031 | [sre] Matrix/ADR 0002 omit B-030 digest pinning and the new 3a checks (says 10, runs 15) | Medium | Solved | M3 | 2026-11-18 | 2026-11-18 | 9ededee |
| B-032 | local-path-provisioner crash-loops: helper pod template adds capabilities, fatal at startup | — | Solved | M4 | 2026-11-18 | 2026-11-18 | 716f2e1 |
| B-033 | [sre] storage role passes on a stuck provisioner rollout: waits only for Deployment Available | Medium | Solved | M4 | 2026-11-18 | 2026-11-18 | 9fe3d95 |
| B-034 | [sre] check_5 fails when re-run within ~10 s: verify-tmp still Terminating from the last run | Medium | Solved | M4 | 2026-11-18 | 2026-11-18 | a3b8ac8 |
| B-035 | [sec] Internal root CA has no name constraints: its key can mint trusted certs for any domain | Medium | Solved | M5 | 2026-11-19 | 2026-11-19 | 768ad66 |
| B-036 | [sec] Traefik (Mac-facing, hostNetwork) can read every Secret, including the CA key | Medium | Solved | M5 | 2026-11-19 | 2026-11-19 | e31f4da |
| B-037 | [sre] Fresh clone (ca.crt committed, no key) pairs a new CA key with the old cert, reports success | High | Solved | M5 | 2026-11-19 | 2026-11-19 | 768ad66 |
| B-038 | [sre] A deleted watched namespace (e.g. verify-tmp) blanks every Ingress on Traefik restart | Medium | Solved | M5 | 2026-11-19 | 2026-11-19 | e31f4da |
| B-039 | [sec] Grafana (Mac-facing via Traefik) can read every Secret cluster-wide, including the CA key | Medium | Solved | M6 | 2026-11-19 | 2026-11-19 | 83e1d34 |
| B-040 | [sec] node-exporter (hostPID, host / mounted) runs without no_new_privs, drop ALL or seccomp | Medium | Solved | M6 | 2026-11-19 | 2026-11-19 | 83e1d34 |
| B-041 | [sre] Grafana undersized: 299Mi RSS at idle vs 384Mi limit, 128Mi request (OOMKill/eviction risk) | Medium | Solved | M6 | 2026-11-19 | 2026-11-19 | 83e1d34 |
| B-042 | [sre] Concurrent heavy PromQL queries OOMKill Prometheus (no query sample or concurrency caps) | Medium | Solved | M6 | 2026-11-19 | 2026-11-19 | 83e1d34 |
| B-043 | [sre] Parallel `/api/v1/series` over all series OOMKills Prometheus (bypasses the query caps) | Medium | Open | M10 | 2026-11-19 | | |

## Assumptions / open questions
- Host is an Apple Silicon Mac → VM is Debian 13 **arm64** under Lima (vz). amd64 image is listed in `lima/k8s.yaml` for Intel hosts but untested. Linux hosts are planned (Backlog), Windows is out of scope (Ansible needs WSL2).
- "Stored outside the cluster" = outside the VM too: snapshots go to `./backups` on the Mac through a Lima mount (gitignored).
- "Every request to the Kubernetes API is recorded" = API server audit log at `Metadata` level or higher for all requests, no `None` rules.
- "Application workloads" = workloads in `app_namespaces` (currently `llm`). Platform namespaces (CNI, monitoring, ingress) are exempt from PSA `restricted` where they genuinely need host access.
- The Lima base image is the dated Debian trixie cloud build `20261103-2651` (sha512-pinned in `lima/k8s.yaml`).
- M1 pins every apt package the roles install explicitly (`os_base_packages`, containerd, runc) and holds them; transitive dependencies are not pinned. `apt-transport-https` is skipped (transitional dummy, https is built into apt 3.x). Debian only keeps the current point-release version, so a pin can break `apt install` after a point release: bump it via `pin-version`.
- Debian trixie ships containerd 1.7.24 (config schema `version = 2`, CRI plugin `io.containerd.grpc.v1.cri`), not 2.x. Since M2 the sandbox (pause) image is kubeadm's (`pause_image_tag`, asserted by the kubeadm role).
- Kubernetes **v1.35** (1.35.10): the last minor supporting containerd 1.x (k8s v1.35 release blog); trixie ships containerd 1.7.24. kubelet logs `RuntimeConfig not implemented` and falls back to its own `cgroupDriver: systemd` (expected until containerd 2.x). containerd's RELEASES.md recommends 1.7.28+ for k8s 1.35; Debian's 1.7.24 is used as is. Moving past 1.35 needs containerd 2.x (not in trixie).
- Python client for `kubernetes.core` on the node: Debian `python3-kubernetes` 30.1.0-2 (pinned, held), not a pip venv: a venv needs `python3.13-venv`, whose `+deb13uN` pin changes with every Python DSA (worse for B-027), and pip would pull unpinned transitive deps. The dynamic client works against 1.35.
- kubeadm init runs once (`creates: admin.conf`); later edits to the kubeadm config need `make vm-reset`. Audit policy and admission config changes restart the API server (handler).
- PSA cluster defaults: enforce `baseline`, audit/warn `restricted`, only `kube-system` exempt. Platform namespaces needing host access (tigera-operator, local-path, traefik, node-exporter) are labelled by their own roles.
- Calico platform namespaces `tigera-operator` (labelled by `cni_calico`) and `calico-system` (labelled by the operator) are PSA `privileged`: the CNI needs host networking, hostPath and NET_ADMIN. Not app namespaces, so exempt from `restricted` (CLAUDE.md).
- Calico v3.33.0 (chart + CRDs chart, operator v1.44.0): newest release ≥ 2 weeks old (v3.33.1 is from 2026-11-16). VXLANCrossSubnet, BGP off, Goldmane/Whisker off; the Calico API server stays on because the `tiers` TigeraStatus is Degraded without it. Debian's containerd CNI dir is `/usr/lib/cni`: read from containerd, passed as `cni.binDir` (ADR 0002).
- Metrics bind to the node IP (etcd 2381 also on 127.0.0.1 for its probe; controller-manager 10257, scheduler 10259, kube-proxy 10249); reachable from pods, not forwarded to the Mac. etcd metrics are plain HTTP.
- Audit: one `Metadata` catch-all rule, `RequestReceived` stage omitted (every request still logs ResponseComplete/ResponseStarted).
- pkgs.k8s.io signing key `DE15…6436` expires 2026-12-29; the role re-downloads it each run and checks the fingerprint, so an OBS expiry extension is picked up.
- local-path-provisioner v0.0.37 (`local-path-storage`, PSA `privileged`: helper pods mount hostPath as root) with data in `/opt/local-path-provisioner` on the VM disk (not the Mac mount; PVs die with the VM). The provisioner rejects `capabilities.add` in the helper template unless `--allow-unsafe-helper-pod-template` is set, so the helper drops every default capability except `DAC_OVERRIDE` (teardown deletes files owned by other UIDs) and the flag stays off.
- cert-manager chart v1.21.3 (2026-10-23; supports k8s 1.33-1.36) and Traefik chart 42.3.0 / v3.7.17 (2026-11-03; 42.3.2 is <2 weeks old), all images by multi-arch index digest. cert-manager `startupapicheck` is disabled (role waits on the Deployments and retries the ClusterIssuer); `acmesolver` is pinned but unused (no ACME).
- Internal CA: EC P-256 root, CN `INDEV internal CA`, 10 years, created once by the `pki` role (`.secrets/ca.key` 0600, `certs/ca.crt`), never regenerated if the cert exists. Shared defaults `pki_cluster_issuer` (`internal-ca`), `pki_cert_duration` 2160h, `pki_cert_renew_before` 720h live in `group_vars/all/main.yml`. cert-manager is PSA `restricted`; `traefik` is PSA `privileged` (hostNetwork).
- Traefik RBAC is ours, not the chart's (B-036): Secrets readable only in `ingress_traefik_watched_namespaces` (llm, monitoring, `ingress-check`), which `ingress_traefik` creates (B-038: only role-owned namespaces nothing deletes; scratch `verify-tmp` is not watched, its stale Role is removed); M6/M9 roles add labels/policies on top, and a new Ingress namespace must be added to that list. `ingress-check` is check_4's namespace (PSA restricted, default-deny + node-IP /32 allow on 8080).
- Traefik runs non-root on node ports 8443/8000 (Lima forwards Mac 443/80, B-009), Service disabled, IngressRoute CRDs skipped (Ingress provider only); internal ports: metrics 9101 (9100 is node-exporter's in M6), health/ping 9102 (avoids the common 8080). `check_4` renews a 1h Certificate (renewBefore 59m45s, cert-manager's minimum duration) to prove automatic renewal in seconds.
- Req 3 "accept only the traffic they need" is read as traffic from other pods/networks; node-local traffic is always allowed (Kubernetes NetworkPolicy docs, Calico host→workload). Accepted (user, 2026-11-19; [ADR 0003](docs/decisions/0003-traefik-ingress.md)).
- kube-prometheus-stack chart 92.18.0 (operator v0.94.2; 2026-11-04, newest >= 2 weeks old, 93.x is a newer major), release `kps` in `monitoring` (PSA restricted: the chart's contexts pass, read-only rootfs included), every image by digest. node-exporter runs in `node-exporter` (PSA privileged) through the subchart's `namespaceOverride`; scrape ports are the ones the kubeadm role binds to the node IP (etcd 2381, controller-manager 10257, scheduler 10259, kube-proxy 10249) plus node-exporter 9100 and Traefik 9101 (PodMonitor).
- Operator webhook certificate: the chart's own cert-manager chain (self-signed), not `internal-ca`, whose name constraints (`DNS:local`) would reject `*.svc` names; `failurePolicy: Ignore` because the chart's own PrometheusRules are applied before the operator serves the webhook (strict mode failed the first install).
- Footprint: Prometheus 5Gi local-path PVC, retention 3d / 3GB, memory limit 1280Mi with GOGC=50, queries capped (2 concurrent, 1.2M samples, 1m: 2 x 2 overlap x 1.2M x 100 B fits the ~500Mi heap headroom; wider ones fail with an error instead of OOM-killing it); `check_6` asserts the sum of container memory requests/limits stays under caps (1536Mi/3072Mi, role defaults) so M9's llama.cpp keeps >= 2.5 GiB. Alertmanager has no PVC (silences are lost on restart) and no receivers: alerts only need to fire in Alertmanager (PDF).
- Grafana: admin password generated on the host by Ansible into `.secrets/grafana-admin-password` (0600, reused on rebuilds, never printed), loaded into Secret `grafana-admin` (chart `admin.existingSecret`); no anonymous access, no persistence (datasource and 27 default dashboards are provisioned), TLS Certificate `grafana-tls` from `internal-ca` with `pki_cert_duration`/`pki_cert_renew_before`, Ingress through Traefik only.
- "Node and etcd alerts fire in Alertmanager" is read as: the chart's default node/etcd rules are loaded and healthy; the always-firing `Watchdog` reaches Alertmanager (live pipeline proof); and the alerts fire on failing input, proven by `promtool test rules` (`monitoring/files/alert-tests.yaml`, run by `check_6` in a throwaway pod against the rule files Prometheus loaded). A real node or etcd failure cannot be provoked within seconds without disrupting the cluster (`for:` is 1-20 min).
- B-038 follow-up: `TraefikDown` (Traefik target absent/down) and `TraefikIngressNotSynced` (kube-state-metrics sees Ingresses with TLS but Traefik loaded no certificate, `traefik_tls_certs_not_after`); covers TLS Ingresses only, unit-tested with promtool.
- `monitoring` NetworkPolicies: default-deny, DNS, then one policy per component; hostNetwork peers (API server on :6443 after DNAT, kubelet, etcd, node-exporter, Traefik, apiserver proxy) are `ipBlock` node-IP /32 (ADR 0003). `check_6` proves enforcement with a probe pod outside the namespace. `check_6` needs `jq` on the host.
- **Accepted risk (user, 2026-11-19, B-043, deferred to M10):** heavy parallel `/api/v1/series` calls over all series can OOMKill Prometheus (query caps don't cover that path). Reason: only an admin with a port-forward or the API proxy can send them, Prometheus restarts in seconds with its TSDB intact; PromQL load is bounded (B-042). Fix at M10.
- **Accepted risk (user, 2026-11-18, B-026):** runc stays Debian trixie's `1.1.15` (EOL upstream, no fix for the Nov-2025 container-escape CVEs 2025-31133/52565/52881; trixie has no newer build). Reason: single-user local VM running only our own workloads, which are PSA `restricted`. Revisit if trixie-security ships a fixed runc, or before any shared/production use.

## Bug details

Max 5 lines per bug (heading + up to 4 one-line bullets, ~200 chars each). Full evidence lives in the reviewer reports and commit messages.

### B-001: ansible-lint warns: ansible-core 2.21.6 does not support Python 3.15
- **Report** (setup): `ansible-lint --version` warned ansible-core 2.21.6 supports Python ≤ 3.14; Homebrew built it on 3.15.
- **Root cause:** Homebrew builds both ansible-lint and ansible on Python 3.15 (ansible silently).
- **Fix:** pinned `.venv` on Python 3.14 (`requirements.txt`, `make tools`), first on PATH for make targets and the lint hook.
- **Verification:** tools report Python 3.14.5 with no warning; `make lint` clean; second `make tools` does nothing.

### B-002: Pinned collections not installed into `ansible/collections/`
- **Report** (setup): `ansible-galaxy collection install -p ansible/collections` said "Nothing to do"; the directory stayed empty.
- **Root cause:** Homebrew's ansible bundles the same collections, so galaxy skipped the install.
- **Fix:** `make collections` uses `--force` behind a stamp file that tracks `ansible/requirements.yml`.
- **Verification:** collections present in `ansible/collections/` and resolved first inside `ansible/`.

### B-003: First commit run swept 5 previously staged files into the wrong commit
- **Report** (first commit run): the "assignment brief" commit also contained 5 files staged earlier.
- **Root cause:** `git rm --cached` without `-f` failed on an unborn branch before `set -e` was active.
- **Fix:** local commits redone; `split-commits` uses `-f` on unborn branches and checks the staged list before each commit.
- **Verification:** 9 commits, each with exactly its planned files.

### B-004: [sre] `make verify` / `make e2e` pass when every check is SKIP
- **Report** (sre round 1): `scripts/verify.sh` with every check SKIP exited 0, so `make e2e` could pass without testing anything.
- **Root cause:** the exit code counted only FAIL.
- **Fix:** `--strict` / `STRICT=1` makes SKIP fail; `make e2e` runs its steps in order and ends with a strict verify.
- **Verification:** all-SKIP run: lenient rc=0, strict rc=1; `make -n e2e` shows the strict verify last.

### B-005: [sec] Agent could read CA key, admin kubeconfig and snapshots without a prompt
- **Report** (sre round 1): broad `kubectl get` allows let a Secret be printed unprompted; `out/` and `backups/` weren't read-denied.
- **Root cause:** allow rules covered Secrets; only `.secrets/` was denied.
- **Fix:** deny rules for the three secret directories and Secret reads (user-approved); superseded by B-011, B-015, B-016.
- **Verification:** permission simulation, 14 cases.

### B-006: [sre] `review-loop` cannot stop while later-milestone bugs are Open
- **Report** (sre round 1): `fix-next-bug` picked `[sec]`/High bugs of future milestones first, so the loop could never stop cleanly.
- **Root cause:** severity was ranked before the milestone filter; the stop condition counted later-milestone bugs.
- **Fix:** filter to current-or-earlier milestones first (later ones deferred); in-scope stop condition; bracketed `[stuck rN]` marker.
- **Verification:** selection simulated on the bug table: picks B-005, B-004, B-006; B-007 to B-010 deferred.

### B-007: [sre] Host kubeconfig at 127.0.0.1:6443 fails TLS (no loopback SAN)
- **Report** (sre round 1): the apiserver cert has no `127.0.0.1`/`localhost` SAN, but host kubeconfigs use the Lima forward `127.0.0.1:6443`.
- **Root cause:** kubeadm puts only the node IP, service IP and cluster names in the API server cert; the Lima forward is 127.0.0.1.
- **Fix:** `kubeadm_cert_sans: [127.0.0.1, localhost]` in the kubeadm role's `apiServer.certSANs`; `out/admin.conf` server rewritten to `https://127.0.0.1:6443`.
- **Verification:** `make verify REQ=2 STRICT=1`: `/readyz` = ok from the Mac with TLS verification on, SANs include 127.0.0.1 and localhost; 20 PASS.

### B-008: [sec] "Allow from Traefik" NetworkPolicy cannot match a hostNetwork Traefik
- **Report** (sre round 1): hostNetwork traffic comes from the node IP, which selectors never match and NetworkPolicy always allows; the rule is a no-op.
- **Root cause:** hostNetwork traffic leaves from the node IP; pod/namespace selectors can't match it.
- **Fix:** user decision in ADR 0003: app NetworkPolicies allow ingress from the node IP (`ipBlock` /32) on the app port only; any hostNetwork process reaching it is accepted (single node).
- **Verification:** ADR 0003 Accepted; enforcement is proven by `check_3b` in M9 (normal pod denied).

### B-009: [sre] hostNetwork Traefik cannot bind :443/:80 as non-root
- **Report** (sre round 1): the Traefik chart runs as UID 65532 without capabilities on 8000/8443; binding 443/80 needs root or `NET_BIND_SERVICE`.
- **Root cause:** ports < 1024 need root or `NET_BIND_SERVICE`; the chart runs UID 65532 with no capabilities.
- **Fix:** Traefik listens on 8443/8000; `lima/k8s.yaml` forwards Mac 443→8443, 80→8000 (running VM edited + restarted, user-approved); ADR 0003.
- **Verification:** `make verify REQ=4 STRICT=1` 34 PASS (UID 65532, no caps, :8443/:8000 listening, Mac 443 TLS 200, :80 → 301); sre r1 confirmed.

### B-010: [sre] etcd snapshots can silently land on the VM disk
- **Report** (sre round 1): `/mnt/host-backups` is the host mount only if `make vm-up` created the VM; otherwise snapshots stay on the VM disk unnoticed.
- **Direction:** assert the mount in the role, `RequiresMountsFor=` on the unit, a mountpoint check in the script, host/node comparison in `check_7`.

### B-011: [sec] Secrets still readable unprompted via other `get` spellings (B-005 follow-up)
- **Report** (sre round 2): B-005's rules missed plural, `secret/<name>`, `-n` before the kind, `--raw` and node-side `--all-namespaces`.
- **Root cause:** legacy `:*` prefix rules need a word break and a fixed flag order.
- **Fix:** mid-pattern glob rules; superseded by the allow-list model (B-015, B-016).
- **Verification:** simulation: 18 bypass forms blocked, 9 routine commands still allowed.

### B-012: [sre] Milestone gate and `bug solve` still accept SKIP (B-004 follow-up)
- **Report** (sre round 2): strict mode existed, but the k8s-verifier gate, `bug solve` and the reviewer still ran verify leniently.
- **Root cause:** B-004's fix wasn't carried to the places that decide.
- **Fix:** k8s-verifier, milestone step 2, `bug solve` and the sre-reviewer use `STRICT=1` whenever the result decides something.
- **Verification:** grep: the remaining lenient uses are informational only.

### B-013: [sre] Strict verify is per requirement, but req 3 and 8 span milestones
- **Report** (sre round 2): req 3 and 8 are delivered across M2, M3, M8 and M9, so a per-requirement strict gate blocked or passed the wrong milestone.
- **Root cause:** check granularity didn't match how milestones deliver requirements.
- **Fix:** check IDs `1 2 3a 3b 4 5 6 7 8a 8b 8c 9`, one stub each; every milestone line in TODO.md names its IDs.
- **Verification:** each ID owned by exactly one milestone (script cross-check); bash 3.2 argument tests pass.

### B-014: [sre] Close gate, `bug` skill and workflow doc kept pre-B-006 rules
- **Report** (sre round 2): the milestone close gate, `bug` skill and `docs/ai-workflow.md` still used the old bug-scope rules.
- **Root cause:** B-006's fix wasn't propagated to every place that states the rule.
- **Fix:** close, load and implement steps use "this milestone or earlier, stuck included"; bug skill and workflow doc aligned.
- **Verification:** grep for the old wording: none left.

### B-015: [sec] Secrets readable unprompted via mixed-case kinds (B-011 follow-up)
- **Report** (sre round 3): mixed-case or combined kinds (`Secret`, `SECRETS`, `configmap,Secret`) still matched the broad `get` allow.
- **Root cause:** blocking bad spellings can't cover every spelling while broad allows approve the rest.
- **Fix:** user-chosen allow-list + ask: `get` is auto-allowed only for listed kinds; anything else prompts.
- **Verification:** simulation: 12 Secret-read spellings prompt; routine inspection still allowed.

### B-016: [sre] Secret deny rules hard-block harmless inspection commands
- **Report** (sre round 3): substring deny rules blocked cert-expiry checks, `etcdctl endpoint health`, `get --raw /readyz` and commit bodies.
- **Root cause:** broad patterns were in deny, which can't be approved in the moment.
- **Fix:** broad patterns moved to ask; deny kept only for printing the secret files themselves.
- **Verification:** simulation: 8 harmless commands ask or run; 10 direct secret reads denied.

### B-017: [sre] Final strict verify ran before the review-loop fixes (B-012 follow-up)
- **Report** (sre round 3): the last strict verify ran before the review fixes, and the reviewer's strict set excluded the milestone under review.
- **Root cause:** the strict gate sat at milestone step 2 instead of at close.
- **Fix:** step 5 runs a final strict gate (this + ticked milestones) before ticking; the reviewer includes the milestone in scope.
- **Verification:** final-gate ID set simulated (M2 with M1 ticked gives `1 2 8c`).

### B-018: [sec] Secrets dumpable unprompted via the operator kubeconfig allow (B-015 follow-up)
- **Report** (sre round 4): the operator kubeconfig's broad `get` allow ran as admin when a second `--kubeconfig` was appended (kubectl uses the last).
- **Root cause:** broad allow on the operator kubeconfig; also, quoted `;` or `|` on `limactl shell` lines run in the VM's shell.
- **Fix:** operator `get` allow removed; ask rules for identity flags and remote shell metacharacters.
- **Verification:** simulation 17/17; earlier suites unchanged.

### B-019: [sec] `make`, `git diff` and `ansible` allow rules run arbitrary commands unprompted
- **Report** (sre round 4): `make verify REQ='1; cmd'` ran `cmd`; `git diff --no-index` and a second ansible `-m` could print files or run commands.
- **Root cause:** pre-approved command shapes accepted arguments that turn into shell code.
- **Fix:** Makefile validates user variables on raw text, internals `override`; `make ping`; ask on `--no-index`; ADR 0009.
- **Verification:** 10 live injection attempts rejected (rc=2); normal make use unaffected.

### B-020: [sec] Pre-approved `make verify`/`provision` still run any command or `vm-destroy` (B-019 follow-up)
- **Report** (sre round 5): commands still run via `REQ:=$(shell …)`, an emptied `check_chars`, unchecked variables, or extra goals (`make verify vm-destroy`).
- **Root cause:** `make <target>:*` allows took any arguments; make expands `:=`/`--eval`/`-f` before the Makefile, and helpers weren't `override`.
- **Fix:** exact-match make allows only (per check ID / role); Makefile command-line variable whitelist, helpers `override`, destructive goals alone; ADR 0009.
- **Verification:** 4 reported bypasses + `_=`, `.DEFAULT_GOAL=` rejected or prompt; normal make use unchanged; security-reviewer: resolved.

### B-021: [sre] Agent/skill make commands (quoted `REQ`, multi-ID, `TAGS=a,b`) miss the exact allows, prompt
- **Report** (sre B-020 round 1): ansible-engineer.md:31, milestone/SKILL.md:25,39, fix-next-bug/SKILL.md:65,68, sre-reviewer.md:41 say `make verify REQ="<ids>"`; provision/SKILL.md:13 `TAGS=a,b`: none match the allows.
- **Root cause:** B-020 changed the allows to exact forms but not the instructions that build the commands.
- **Fix:** CLAUDE.md convention (one unquoted ID/role per call, fixed order); agents and skills rewritten to it.
- **Verification:** every concrete make command in `.claude/` and CLAUDE.md matches an allow; template forms covered for all 12 IDs; lint OK.

### B-022: [sre] B-021 rewrite narrowed the DoD idempotency gate from whole playbook to per role
- **Report** (sre B-021 round 2): CLAUDE.md:55 was bare `make idempotency` (all delivered roles), now `TAGS=<role>` only; cross-role drift or earlier-role regressions surface only at M10 `make e2e`.
- **Root cause:** the B-021 rewrite converted every idempotency call to per-role, including the whole-playbook gate that already matched an allow.
- **Fix:** bare `make idempotency` back in the DoD, ansible-engineer, sre-reviewer testing and the milestone final gate; per-role runs kept.
- **Verification:** grep: each idempotency gate has a bare run; `make -n idempotency` runs the whole playbook; matches an exact allow; lint OK.

### B-023: `make ping`/Ansible can't reach the VM: ssh `-F ~/.lima/...` is not tilde-expanded
- **Report** (M1, first run against a VM): `make ping` → "Can't open user config file ~/.lima/k8s/ssh.config"; every playbook run fails.
- **Root cause:** `ssh_args` reach ssh without a shell and OpenSSH doesn't expand `~` in `-F`; never ran against a VM before M1.
- **Fix:** `-F` moved to inventory `ansible_ssh_common_args` with `$HOME`; fixed on a branch cut from the M1 branch (user's choice), lands with M1.
- **Verification:** `make ping` → pong; `make provision` preflight ok, failed=0; lint and `make check` OK.

### B-024: [sre] containerd restart deferred to play end: M2 kubeadm init would run on Debian's default config
- **Report** (sre M1 r1): apt postinst starts containerd on the packaged config (journal 15:17:29); the template's handler restarts it only at play end (15:17:30), after later roles in the same play.
- **Root cause:** handlers run at play end by default; nothing flushed them after the containerd role.
- **Fix:** `meta: flush_handlers` at the end of the role; `force_handlers = True` in ansible.cfg.
- **Verification:** fresh VM (`make vm-reset` + `make provision`): restart handler runs right after the role; idempotency changed=0; verify 1 17 PASS.

### B-025: [sec] Lima catch-all `ignore` misses 0.0.0.0/:: and UDP listeners: guest ports reach Mac loopback
- **Report** (sre M1 r1): `ha.stderr.log` "Forwarding TCP from 0.0.0.0:5355 / [::]:5355" + UDP ephemeral ports; `lsof -c limactl` shows 127.0.0.1:5355 LISTEN. Later kubelet, node-exporter, metrics follow.
- **Root cause:** the catch-all ignore defaulted to `proto: tcp`; Lima's appended fallback rule (`proto: any`) forwarded the rest.
- **Fix:** catch-all ignore with `guestIP: 0.0.0.0` (any bind) and `proto: any`.
- **Verification:** fresh VM log: 5353/5355/ephemeral UDP and TCP "Not forwarding"; guest listener 0.0.0.0:6443 forwarded (HTTP 200), 8080 not.

### B-026: [sec] Pinned runc 1.1.15 lacks fixes for the Nov-2025 container-escape CVEs
- **Report** (sre M1 r1): runc `1.1.15+ds1-2+b4` (trixie, no security/backports update); changelog has no CVE-2025-31133/52565/52881 fix (upstream fixed in 1.2.8/1.3.3; 1.1.x EOL).
- **Root cause:** Debian trixie ships no runc newer than 1.1.15 (no security or backports update).
- **Fix:** user accepted the risk: Assumption in TODO.md with reason and revisit trigger; comment on the pin.
- **Verification:** `apt-cache madison runc`: only 1.1.15 available; assumption present; lint OK.

### B-027: [sre] Exact Debian apt pins vanish after the next DSA/point release: clean rebuild fails
- **Report** (sre M1 r1): `apt-cache madison curl`: pinned `+deb13u7` exists only in trixie-security; the next curl/containerd DSA removes it and `os_prep` fails on `make e2e` or a grader's clean VM.
- **Direction:** add a `snapshot.debian.org` source at a pinned timestamp (trixie + trixie-security, `check-valid-until=no`) so `pkg=ver` stays installable; keep only runtime packages exact-pinned.

### B-028: [sec] regression of B-025: catch-all ignore no longer matches 127.0.0.1; loopback ports forwarded
- **Report** (sre M1 r2): Lima 2.3.0 sets `guestIPMustBeZero: true` on explicit `guestIP: 0.0.0.0`; ha.stderr.log "Forwarding TCP from 127.0.0.1:46137" (containerd), Mac `lsof` LISTEN 127.0.0.1:46137.
- **Root cause:** an explicit `guestIP: 0.0.0.0` defaults to `guestIPMustBeZero: true`, so loopback binds fell through to Lima's fallback rule.
- **Fix:** `guestIPMustBeZero: false` on the catch-all; applied with `limactl stop` + `limactl edit --set` + `make vm-up` (user's choice).
- **Verification:** log: every guest port "Not forwarding" (incl. 127.0.0.1:34975, :9100), 0.0.0.0:6443 forwarded (200); Mac lsof: Lima internals only; security-reviewer: resolved.

### B-029: [sre] kubeadm init rescue runs `kubeadm reset --force` on an existing cluster: wipes etcd
- **Report** (sre M2 r1): init is guarded only by `creates: admin.conf`; if it is missing on a live node, preflight fails (:6443, manifests, etcd dir) and the rescue resets, deleting /var/lib/etcd and PKI.
- **Root cause:** the only init guard was `creates: admin.conf`; a missing admin.conf on a live node sent init into the reset rescue.
- **Fix:** stat admin.conf, the apiserver manifest and etcd member dir; fail before init if a control plane exists without admin.conf. Fixed in the M2 tree, no own branch (user's choice).
- **Verification:** check-mode run of `init.yml` with admin.conf pointed at a missing file stops at the guard (init/reset never reached); idempotency changed=0; strict 1/2/8c 45 PASS.

### B-030: [sec] Calico images (privileged, hostNetwork) pulled by mutable tag only, no digest pins
- **Report** (sec M3 r1): only the chart version is pinned; live pods run `quay.io/tigera/operator:v1.44.0`, `quay.io/calico/{node,calico,third-party-cni-plugins}:v3.33.0` by tag; a re-pushed tag runs as host root.
- **Root cause:** the chart and operator default to `image:tag`; no `ImageSet` or digest existed, so the privileged images were mutable.
- **Fix:** `tigeraOperator.version` is `tag@digest` in `values.yaml.j2`; `imageset.yaml.j2` (`calico-v3.33.0`: calico, node, third-party-cni-plugins) applied before the chart; digests in `versions.yml`.
- **Verification:** `make verify REQ=3a STRICT=1` (new digest + ImageSet checks) 15 PASS; pod specs run `@sha256:`; idempotency changed=0; REQ 1, 2, 8c PASS.

### B-031: [sre] Matrix/ADR 0002 omit B-030 digest pinning and the new 3a checks (says 10, runs 15)
- **Report** (sre M3 r2): `docs/requirements-matrix.md` 3a lists "10 checks" and no ImageSet/digest, requests or audit/warn label checks; ADR 0002 says only "chart (pinned)"; `check_3a` runs 15.
- **Root cause:** B-030 added the ImageSet/digest, requests and audit/warn checks without updating the matrix row or ADR 0002.
- **Fix:** matrix row 3a lists the 15 checks and pinning, status Done (M3); ADR 0002 documents digest pinning, bump procedure and accepted Lows; architecture Calico row notes digests.
- **Verification:** `check_3a` pass/fail calls counted in `scripts/verify.sh` = 15; docs read against `cni_calico` and `versions.yml`.

### B-032: local-path-provisioner crash-loops: helper pod template adds capabilities, fatal at startup
- **Report** (verify REQ 5): provisioner pod restarted 6× in 8 min; previous log: `helper pod template must not add capabilities unless allow-unsafe-helper-pod-template`.
- **Root cause:** the restarts (last 20:44:54) came from the role's first draft, whose helper template used `capabilities.add`; v0.0.37 rejects it without the unsafe flag.
- **Fix:** the helper template only drops capabilities (keeps DAC_OVERRIDE by not dropping it); live ConfigMap has no `add`.
- **Verification:** restartCount stayed 6, Ready, running since 20:47:36 through 20:54:35; `make verify REQ=5 STRICT=1` 15 PASS.

### B-033: [sre] storage role passes on a stuck provisioner rollout: waits only for Deployment Available
- **Report** (sre round 1): `storage/tasks/main.yml` waits on `wait_condition: Available`; with 1 replica (maxUnavailable 0) the old pod keeps Available=True while a new template crash-loops, so provision is green.
- **Root cause:** with `wait_condition` set, kubernetes.core's `get_waiter()` uses a custom condition instead of `deployment_ready` (observedGeneration, replicas).
- **Fix:** `wait_condition` dropped from the storage role's rollout wait; comment says why.
- **Verification:** scratch Deployment in verify-tmp with a bad new image: old wait green, new wait fails; provision/idempotency changed=0; verify 5 15 PASS.

### B-034: [sre] check_5 fails when re-run within ~10 s: verify-tmp still Terminating from the last run
- **Report** (sre round 1): `make verify REQ=5 STRICT=1` 3x back to back: 1st 15 PASS, 2nd and 3rd FAIL `verify-tmp ... currently being deleted`; `cleanup_5` deletes the namespace with `--wait=false`.
- **Root cause:** `cleanup_5` deletes verify-tmp with `--wait=false`; the next run applied into the still-Terminating namespace.
- **Fix:** `wait_verify_ns_gone` in `scripts/verify.sh` waits for a Terminating verify-tmp to go before check_5 creates it; reusable by later checks.
- **Verification:** `make verify REQ=5 STRICT=1` twice back to back: 15 PASS both; 1/2/3a/8c strict 17/20/15/8 PASS; lint OK.

### B-035: [sec] Internal root CA has no name constraints: its key can mint trusted certs for any domain
- **Report** (sec round 1): `openssl x509 -in certs/ca.crt -text`: no Name Constraints; 10-year key also in a cluster Secret and etcd snapshots; whoever trusts the CA (e.g. for grafana.local) is MITM-able anywhere.
- **Root cause:** the CA CSR in `pki/tasks/ca.yml` set no name constraints.
- **Fix:** critical permitted `DNS:local`, excluded `IP:0.0.0.0/0`, `IP:::/0` (`pki_ca_*_names`); CA regenerated (never committed); check_4 asserts it + `openssl s_client` chain verify.
- **Verification:** `openssl x509 -text` shows the constraints; macOS curl and openssl verify the leaf; `make verify REQ=4 STRICT=1` 39 PASS.

### B-036: [sec] Traefik (Mac-facing, hostNetwork) can read every Secret, including the CA key
- **Report** (sec round 1): ClusterRole `traefik-traefik` grants secrets get/list/watch cluster-wide; `auth can-i get secrets -n cert-manager --as=system:serviceaccount:traefik:traefik` = yes (`internal-ca-key-pair`).
- **Root cause:** the chart's ClusterRole grants Secrets cluster-wide; its `rbac.namespaced` mode drops IngressClass access, so Ingresses with a class are ignored.
- **Fix:** chart RBAC off; own ClusterRole (ingressclasses, nodes) + per-namespace Roles for `ingress_traefik_watched_namespaces` (llm, monitoring, verify-tmp; created bare by the role), provider limited to them.
- **Verification:** `auth can-i get secrets` as the Traefik SA: no in cert-manager/kube-system/traefik; check_4 asserts it; verify 4 39 PASS twice; idempotency changed=0.

### B-037: [sre] Fresh clone (ca.crt committed, no key) pairs a new CA key with the old cert, reports success
- **Report** (sre round 1): `pki` ca.yml on a copy with only `certs/ca.crt`: key created, cert kept (changed=2, no error); cert/key pubkey sha256 `033d45…` vs `ee99a9…`.
- **Root cause:** ca.yml created a missing key and kept an existing cert without checking they pair.
- **Fix:** fail before key creation if the cert exists without the key; assert key/cert public-key sha256 match every run (no_log); check_4 compares pubkey hashes.
- **Verification:** scratch copies: cert-only fails with the restore/delete message, no key made; clean dir creates the pair then changed=0; swapped cert fails the assert.

### B-038: [sre] A deleted watched namespace (e.g. verify-tmp) blanks every Ingress on Traefik restart
- **Report** (sre round 2): delete ns verify-tmp + Traefik pod restart: a `monitoring` route 503 → 404 for 60 s+ (Role gone, list forbidden, no sync), pod still Ready; back ~50 s after re-provision.
- **Root cause:** Traefik watched scratch ns verify-tmp; deleting it removed its Role, so after a restart the provider's lists were forbidden and it never synced.
- **Fix:** watch only role-owned llm, monitoring, `ingress-check` (check_4's own ns, never deleted); stale verify-tmp Role removed; role + check_4 assert a Role/RoleBinding per watched ns, no `forbidden` in logs.
- **Verification:** verify-tmp deleted + Traefik restarted → `make verify REQ=4 STRICT=1` 48 PASS (twice); idempotency changed=0. Runbook line + M6 Ingress-probe alert: docs pass / M6.

### B-039: [sec] Grafana (Mac-facing via Traefik) can read every Secret cluster-wide, including the CA key
- **Report** (sec M6 r1): ClusterRole `kps-grafana-clusterrole` grants secrets get/list/watch (sidecars `NAMESPACE=ALL`); `can-i list secrets -n cert-manager` as `kps-grafana` = yes; token in grafana too.
- **Root cause:** the chart's Grafana RBAC grants configmaps and secrets (ClusterRole when sidecars search ALL namespaces); sidecars defaulted to `resource: both`.
- **Fix:** chart RBAC off; own Role/RoleBinding (`grafana-rbac.yaml.j2`) for ConfigMaps in `monitoring`; sidecars `resource: configmap`, `searchNamespace: monitoring`.
- **Verification:** `can-i get/list secrets` as `kps-grafana` = no (cert-manager, kube-system, monitoring, cluster-wide); check_6 asserts it; 27 dashboards, datasource healthy; `make verify REQ=6 STRICT=1` 68 PASS.

### B-040: [sec] node-exporter (hostPID, host / mounted) runs without no_new_privs, drop ALL or seccomp
- **Report** (sec M6 r1): container securityContext only `readOnlyRootFilesystem`; live `/proc/PID/status` NoNewPrivs 0, Seccomp 0, default CapBnd; host setuid sudo/su/mount under /host/root.
- **Root cause:** the node-exporter subchart's default `containerSecurityContext` only sets `readOnlyRootFilesystem`; the pod context has no seccomp.
- **Fix:** values set `allowPrivilegeEscalation: false`, drop ALL and seccomp RuntimeDefault (pod + container), read-only rootfs kept; host namespaces/mounts unchanged (PSA privileged).
- **Verification:** live container context shows the fields; node-exporter target UP, 24 filesystem series; check_6 asserts them; `make verify REQ=6 STRICT=1` 69 PASS; idempotency changed=0.

### B-041: [sre] Grafana undersized: 299Mi RSS at idle vs 384Mi limit, 128Mi request (OOMKill/eviction risk)
- **Report** (sre M6 r1): `container_memory_rss` after start: grafana 299Mi (request 128Mi, limit 384Mi), each sidecar 76Mi (request 48Mi); query load adds heap.
- **Root cause:** requests/limits were guessed, not measured; after B-039 the sidecars still use ~78Mi each and Grafana 282Mi idle (366Mi after a verify run).
- **Fix:** grafana 320Mi/640Mi, sidecars 96Mi/160Mi, prometheus 512Mi, reloaders 24Mi, alertmanager 48Mi; check_6 asserts sums under caps in role defaults (requests 1536Mi, limits 3072Mi) instead of live MemAvailable.
- **Verification:** requests 1256Mi, limits 2624Mi, all 10 containers sized; `make verify REQ=6 STRICT=1` 70 PASS; idempotency changed=0.

### B-042: [sre] Concurrent heavy PromQL queries OOMKill Prometheus (no query sample or concurrency caps)
- **Report** (sre M6 r3, reopened twice): 8 parallel wide `{__name__=~".+"}` ranges OOMKill Prometheus (137); caps 4 x 5M, then 4 x 1.5M at a 1Gi limit, still died (4 parallel peaked at 1002/1024Mi).
- **Root cause:** caps not sized to memory: wide raw results cost ~85 B/sample per in-flight query, JSON encoding overlaps queued queries, and GOGC=100 floats the heap to ~2x its ~600Mi live set.
- **Fix:** limit 1280Mi, GOGC=50, `query` concurrency 2 / maxSamples 1.2M / 1m; defaults hold 100 B/sample, overlap 2, headroom 500Mi; check_6 asserts the product, GOGC and no OOMKilled; Grafana request 384Mi.
- **Verification:** warm pod, 8 wide at 1.18M: anon 891Mi, current 1078Mi (84%); 8 count-by 876Mi; 16 wide: anon 1072Mi, no OOM; restarts 0; 252 rules ok; verify 6 73 PASS. (1.5M reached 94%.)

### B-043: [sre] Parallel `/api/v1/series` over all series OOMKills Prometheus (bypasses the query caps)
- **Report** (sre M6 B-042 r3): 16 parallel `series?match[]={__name__=~".+"}` (3d, 147k series, 47MB each) OOMKilled Prometheus twice; 8 peaked 1255/1280Mi. `--query.*` caps skip this path.
- **Deferred to M10** (user, 2026-11-19): accepted risk until then, see Assumptions.
- **Direction:** bound the series/labels path (Grafana datasource `seriesLimit`, document admin-only `limit=`) and size the limit/headroom for it; add the shape to the B-042 load test.
