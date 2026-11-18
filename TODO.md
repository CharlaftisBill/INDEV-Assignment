# TODO

Live project state and bug tracker. Agents read this first and update it last (protocol in `CLAUDE.md`).

## Status
Current milestone: **M1 — VM up + os_prep + containerd** · Last verified: — (no cluster yet) · Last SRE review: working tree (94e16a0+) 2026-11-18 — B-021 round 2: 1 new bug

## Milestones
- [x] M0 Scaffolding: repo layout, agentic layer (`.claude/`), Makefile, lint configs, Lima config, docs skeleton, commit tooling (`split-commits` skill, `.githooks/commit-msg`)
- [ ] M1 VM up + `os_prep` + `containerd` (req 1)
- [ ] M2 `kubeadm`: init, untaint, audit policy, PSA admission config, metrics binds, `out/admin.conf` (req 2, 8c)
- [ ] M3 `cni_calico` (req 3a)
- [ ] M4 `storage`: local-path-provisioner as default StorageClass (req 5)
- [ ] M5 `pki` + cert-manager + `ingress_traefik` (req 4)
- [ ] M6 `monitoring`: kube-prometheus-stack, node + etcd alerts, Grafana ingress (req 6)
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
| B-007 | [sre] Host kubeconfig at 127.0.0.1:6443 fails TLS (no loopback SAN) | Medium | Open | M2 | 2026-11-17 |  |  |
| B-008 | [sec] "Allow from Traefik" NetworkPolicy cannot match a hostNetwork Traefik | Medium | Open | M5 | 2026-11-17 |  |  |
| B-009 | [sre] hostNetwork Traefik cannot bind :443/:80 as non-root | Medium | Open | M5 | 2026-11-17 |  |  |
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
| B-022 | [sre] B-021 rewrite narrowed the DoD idempotency gate from whole playbook to per role | Medium | Open | M0 | 2026-11-18 |  |  |

## Assumptions / open questions
- Host is an Apple Silicon Mac → VM is Debian 13 **arm64** under Lima (vz). amd64 image is listed in `lima/k8s.yaml` for Intel hosts but untested. Linux hosts are planned (Backlog), Windows is out of scope (Ansible needs WSL2).
- "Stored outside the cluster" = outside the VM too: snapshots go to `./backups` on the Mac through a Lima mount (gitignored).
- "Every request to the Kubernetes API is recorded" = API server audit log at `Metadata` level or higher for all requests, no `None` rules.
- "Application workloads" = workloads in `app_namespaces` (currently `llm`). Platform namespaces (CNI, monitoring, ingress) are exempt from PSA `restricted` where they genuinely need host access.
- The Lima base image is the Debian "latest" trixie cloud build until M1 pins a dated build.

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
- **Direction:** add `apiServer.certSANs: [127.0.0.1, localhost]`; `check_2` proves `get --raw /readyz` works with TLS verification on.

### B-008: [sec] "Allow from Traefik" NetworkPolicy cannot match a hostNetwork Traefik
- **Report** (sre round 1): hostNetwork traffic comes from the node IP, which selectors never match and NetworkPolicy always allows; the rule is a no-op.
- **Direction:** decide in ADR 0003 (accept node-origin ingress or move Traefik off the host network); `check_3b` proves the deny from a normal pod.

### B-009: [sre] hostNetwork Traefik cannot bind :443/:80 as non-root
- **Report** (sre round 1): the Traefik chart runs as UID 65532 without capabilities on 8000/8443; binding 443/80 needs root or `NET_BIND_SERVICE`.
- **Direction:** keep Traefik non-root on 8000/8443; Lima forwards host 443→8443 and 80→8000; update ADR 0003.

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
- **Direction:** DoD: per-role runs, then one bare `make idempotency` (already pre-approved) as the milestone gate; same in milestone skill step 1/5 and sre-reviewer.md:41.
