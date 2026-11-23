# Bugs

Every bug found while building this, grouped by the milestone that fixes it. IDs are never reused.
Format and rules: the `bug` skill (`.claude/skills/bug/SKILL.md`); `make lint` checks it.

## Open

_None._

## M0 — Scaffolding

### B-002 · Pinned collections not installed into `ansible/collections/`
Sev: — · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 34d85b7
- **Report** (setup): `ansible-galaxy collection install -p ansible/collections` said "Nothing to do"; the directory stayed empty.
- **Root cause:** Homebrew's ansible bundles the same collections, so galaxy skipped the install.
- **Fix:** `make collections` uses `--force` behind a stamp file that tracks `ansible/requirements.yml`.
- **Verification:** collections present in `ansible/collections/` and resolved first inside `ansible/`.

### B-003 · First commit run swept 5 previously staged files into the wrong commit
Sev: — · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: adf6d89
- **Report** (first commit run): the "assignment brief" commit also contained 5 files staged earlier.
- **Root cause:** `git rm --cached` without `-f` failed on an unborn branch before `set -e` was active.
- **Fix:** local commits redone; `split-commits` uses `-f` on unborn branches and checks the staged list before each commit.
- **Verification:** 9 commits, each with exactly its planned files.

### B-004 · [sre] `make verify` / `make e2e` pass when every check is SKIP
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 0c72290
- **Report** (sre round 1): `scripts/verify.sh` with every check SKIP exited 0, so `make e2e` could pass without testing anything.
- **Root cause:** the exit code counted only FAIL.
- **Fix:** `--strict` / `STRICT=1` makes SKIP fail; `make e2e` runs its steps in order and ends with a strict verify.
- **Verification:** all-SKIP run: lenient rc=0, strict rc=1; `make -n e2e` shows the strict verify last.

### B-005 · [sec] Agent could read CA key, admin kubeconfig and snapshots without a prompt
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 6ba2a85
- **Report** (sre round 1): broad `kubectl get` allows let a Secret be printed unprompted; `out/` and `backups/` weren't read-denied.
- **Root cause:** allow rules covered Secrets; only `.secrets/` was denied.
- **Fix:** deny rules for the three secret directories and Secret reads (user-approved); superseded by B-011, B-015, B-016.
- **Verification:** permission simulation, 14 cases.

### B-006 · [sre] `review-loop` cannot stop while later-milestone bugs are Open
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: dfc00b7
- **Report** (sre round 1): `fix-next-bug` picked `[sec]`/High bugs of future milestones first, so the loop could never stop cleanly.
- **Root cause:** severity was ranked before the milestone filter; the stop condition counted later-milestone bugs.
- **Fix:** filter to current-or-earlier milestones first (later ones deferred); in-scope stop condition; bracketed `[stuck rN]` marker.
- **Verification:** selection simulated on the bug table: picks B-005, B-004, B-006; B-007 to B-010 deferred.

### B-011 · [sec] Secrets still readable unprompted via other `get` spellings (B-005 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 6ba2a85
- **Report** (sre round 2): B-005's rules missed plural, `secret/<name>`, `-n` before the kind, `--raw` and node-side `--all-namespaces`.
- **Root cause:** legacy `:*` prefix rules need a word break and a fixed flag order.
- **Fix:** mid-pattern glob rules; superseded by the allow-list model (B-015, B-016).
- **Verification:** simulation: 18 bypass forms blocked, 9 routine commands still allowed.

### B-012 · [sre] Milestone gate and `bug solve` still accept SKIP (B-004 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: dfc00b7
- **Report** (sre round 2): strict mode existed, but the k8s-verifier gate, `bug solve` and the reviewer still ran verify leniently.
- **Root cause:** B-004's fix wasn't carried to the places that decide.
- **Fix:** k8s-verifier, milestone step 2, `bug solve` and the sre-reviewer use `STRICT=1` whenever the result decides something.
- **Verification:** grep: the remaining lenient uses are informational only.

### B-013 · [sre] Strict verify is per requirement, but req 3 and 8 span milestones
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 0c72290
- **Report** (sre round 2): req 3 and 8 are delivered across M2, M3, M8 and M9, so a per-requirement strict gate blocked or passed the wrong milestone.
- **Root cause:** check granularity didn't match how milestones deliver requirements.
- **Fix:** check IDs `1 2 3a 3b 4 5 6 7 8a 8b 8c 9`, one stub each; every milestone line in TODO.md names its IDs.
- **Verification:** each ID owned by exactly one milestone (script cross-check); bash 3.2 argument tests pass.

### B-014 · [sre] Close gate, `bug` skill and workflow doc kept pre-B-006 rules
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: dfc00b7
- **Report** (sre round 2): the milestone close gate, `bug` skill and `docs/ai-workflow.md` still used the old bug-scope rules.
- **Root cause:** B-006's fix wasn't propagated to every place that states the rule.
- **Fix:** close, load and implement steps use "this milestone or earlier, stuck included"; bug skill and workflow doc aligned.
- **Verification:** grep for the old wording: none left.

### B-015 · [sec] Secrets readable unprompted via mixed-case kinds (B-011 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 6ba2a85
- **Report** (sre round 3): mixed-case or combined kinds (`Secret`, `SECRETS`, `configmap,Secret`) still matched the broad `get` allow.
- **Root cause:** blocking bad spellings can't cover every spelling while broad allows approve the rest.
- **Fix:** user-chosen allow-list + ask: `get` is auto-allowed only for listed kinds; anything else prompts.
- **Verification:** simulation: 12 Secret-read spellings prompt; routine inspection still allowed.

### B-016 · [sre] Secret deny rules hard-block harmless inspection commands
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 6ba2a85
- **Report** (sre round 3): substring deny rules blocked cert-expiry checks, `etcdctl endpoint health`, `get --raw /readyz` and commit bodies.
- **Root cause:** broad patterns were in deny, which can't be approved in the moment.
- **Fix:** broad patterns moved to ask; deny kept only for printing the secret files themselves.
- **Verification:** simulation: 8 harmless commands ask or run; 10 direct secret reads denied.

### B-017 · [sre] Final strict verify ran before the review-loop fixes (B-012 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: dfc00b7
- **Report** (sre round 3): the last strict verify ran before the review fixes, and the reviewer's strict set excluded the milestone under review.
- **Root cause:** the strict gate sat at milestone step 2 instead of at close.
- **Fix:** step 5 runs a final strict gate (this + ticked milestones) before ticking; the reviewer includes the milestone in scope.
- **Verification:** final-gate ID set simulated (M2 with M1 ticked gives `1 2 8c`).

### B-018 · [sec] Secrets dumpable unprompted via the operator kubeconfig allow (B-015 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 6ba2a85
- **Report** (sre round 4): the operator kubeconfig's broad `get` allow ran as admin when a second `--kubeconfig` was appended (kubectl uses the last).
- **Root cause:** broad allow on the operator kubeconfig; also, quoted `;` or `|` on `limactl shell` lines run in the VM's shell.
- **Fix:** operator `get` allow removed; ask rules for identity flags and remote shell metacharacters.
- **Verification:** simulation 17/17; earlier suites unchanged.

### B-019 · [sec] `make`, `git diff` and `ansible` allow rules run arbitrary commands unprompted
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 9277b57
- **Report** (sre round 4): `make verify REQ='1; cmd'` ran `cmd`; `git diff --no-index` and a second ansible `-m` could print files or run commands.
- **Root cause:** pre-approved command shapes accepted arguments that turn into shell code.
- **Fix:** Makefile validates user variables on raw text, internals `override`; `make ping`; ask on `--no-index`; ADR 0009.
- **Verification:** 10 live injection attempts rejected (rc=2); normal make use unaffected.

### B-020 · [sec] Pre-approved `make verify`/`provision` still run any command or `vm-destroy` (B-019 follow-up)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-18 · Fix: f92e955
- **Report** (sre round 5): commands still run via `REQ:=$(shell …)`, an emptied `check_chars`, unchecked variables, or extra goals (`make verify vm-destroy`).
- **Root cause:** `make <target>:*` allows took any arguments; make expands `:=`/`--eval`/`-f` before the Makefile, and helpers weren't `override`.
- **Fix:** exact-match make allows only (per check ID / role); Makefile command-line variable whitelist, helpers `override`, destructive goals alone; ADR 0009.
- **Verification:** 4 reported bypasses + `_=`, `.DEFAULT_GOAL=` rejected or prompt; normal make use unchanged; security-reviewer: resolved.

### B-021 · [sre] Agent/skill make commands (quoted `REQ`, multi-ID, `TAGS=a,b`) miss the exact allows, prompt
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 49d3ebc
- **Report** (sre B-020 round 1): ansible-engineer.md:31, milestone/SKILL.md:25,39, fix-next-bug/SKILL.md:65,68, sre-reviewer.md:41 say `make verify REQ="<ids>"`; provision/SKILL.md:13 `TAGS=a,b`: none match the allows.
- **Root cause:** B-020 changed the allows to exact forms but not the instructions that build the commands.
- **Fix:** CLAUDE.md convention (one unquoted ID/role per call, fixed order); agents and skills rewritten to it.
- **Verification:** every concrete make command in `.claude/` and CLAUDE.md matches an allow; template forms covered for all 12 IDs; lint OK.

### B-022 · [sre] B-021 rewrite narrowed the DoD idempotency gate from whole playbook to per role
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 951c425
- **Report** (sre B-021 round 2): CLAUDE.md:55 was bare `make idempotency` (all delivered roles), now `TAGS=<role>` only; cross-role drift or earlier-role regressions surface only at M10 `make e2e`.
- **Root cause:** the B-021 rewrite converted every idempotency call to per-role, including the whole-playbook gate that already matched an allow.
- **Fix:** bare `make idempotency` back in the DoD, ansible-engineer, sre-reviewer testing and the milestone final gate; per-role runs kept.
- **Verification:** grep: each idempotency gate has a bare run; `make -n idempotency` runs the whole playbook; matches an exact allow; lint OK.

### B-023 · `make ping`/Ansible can't reach the VM: ssh `-F ~/.lima/...` is not tilde-expanded
Sev: High · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 4c6ed45
- **Report** (M1, first run against a VM): `make ping` → "Can't open user config file ~/.lima/k8s/ssh.config"; every playbook run fails.
- **Root cause:** `ssh_args` reach ssh without a shell and OpenSSH doesn't expand `~` in `-F`; never ran against a VM before M1.
- **Fix:** `-F` moved to inventory `ansible_ssh_common_args` with `$HOME`; fixed on a branch cut from the M1 branch (user's choice), lands with M1.
- **Verification:** `make ping` → pong; `make provision` preflight ok, failed=0; lint and `make check` OK.

## M1 — OS prep and containerd

### B-024 · [sre] containerd restart deferred to play end: M2 kubeadm init would run on Debian's default config
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: c28a8f0
- **Report** (sre M1 r1): apt postinst starts containerd on the packaged config (journal 15:17:29); the template's handler restarts it only at play end (15:17:30), after later roles in the same play.
- **Root cause:** handlers run at play end by default; nothing flushed them after the containerd role.
- **Fix:** `meta: flush_handlers` at the end of the role; `force_handlers = True` in ansible.cfg.
- **Verification:** fresh VM (`make vm-reset` + `make provision`): restart handler runs right after the role; idempotency changed=0; verify 1 17 PASS.

### B-025 · [sec] Lima catch-all `ignore` misses 0.0.0.0/:: and UDP listeners: guest ports reach Mac loopback
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 6364132
- **Report** (sre M1 r1): `ha.stderr.log` "Forwarding TCP from 0.0.0.0:5355 / [::]:5355" + UDP ephemeral ports; `lsof -c limactl` shows 127.0.0.1:5355 LISTEN. Later kubelet, node-exporter, metrics follow.
- **Root cause:** the catch-all ignore defaulted to `proto: tcp`; Lima's appended fallback rule (`proto: any`) forwarded the rest.
- **Fix:** catch-all ignore with `guestIP: 0.0.0.0` (any bind) and `proto: any`.
- **Verification:** fresh VM log: 5353/5355/ephemeral UDP and TCP "Not forwarding"; guest listener 0.0.0.0:6443 forwarded (HTTP 200), 8080 not.

### B-026 · [sec] Pinned runc 1.1.15 lacks fixes for the Nov-2025 container-escape CVEs
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 2ba39bb
- **Report** (sre M1 r1): runc `1.1.15+ds1-2+b4` (trixie, no security/backports update); changelog has no CVE-2025-31133/52565/52881 fix (upstream fixed in 1.2.8/1.3.3; 1.1.x EOL).
- **Root cause:** Debian trixie ships no runc newer than 1.1.15 (no security or backports update).
- **Fix:** user accepted the risk: Assumption in TODO.md with reason and revisit trigger; comment on the pin.
- **Verification:** `apt-cache madison runc`: only 1.1.15 available; assumption present; lint OK.

### B-028 · [sec] regression of B-025: catch-all ignore no longer matches 127.0.0.1; loopback ports forwarded
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 6ea9ce9
- **Report** (sre M1 r2): Lima 2.3.0 sets `guestIPMustBeZero: true` on explicit `guestIP: 0.0.0.0`; ha.stderr.log "Forwarding TCP from 127.0.0.1:46137" (containerd), Mac `lsof` LISTEN 127.0.0.1:46137.
- **Root cause:** an explicit `guestIP: 0.0.0.0` defaults to `guestIPMustBeZero: true`, so loopback binds fell through to Lima's fallback rule.
- **Fix:** `guestIPMustBeZero: false` on the catch-all; applied with `limactl stop` + `limactl edit --set` + `make vm-up` (user's choice).
- **Verification:** log: every guest port "Not forwarding" (incl. 127.0.0.1:34975, :9100), 0.0.0.0:6443 forwarded (200); Mac lsof: Lima internals only; security-reviewer: resolved.

## M2 — kubeadm and audit

### B-007 · [sre] Host kubeconfig at 127.0.0.1:6443 fails TLS (no loopback SAN)
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-18 · Fix: ba24ebb
- **Report** (sre round 1): the apiserver cert has no `127.0.0.1`/`localhost` SAN, but host kubeconfigs use the Lima forward `127.0.0.1:6443`.
- **Root cause:** kubeadm puts only the node IP, service IP and cluster names in the API server cert; the Lima forward is 127.0.0.1.
- **Fix:** `kubeadm_cert_sans: [127.0.0.1, localhost]` in the kubeadm role's `apiServer.certSANs`; `out/admin.conf` server rewritten to `https://127.0.0.1:6443`.
- **Verification:** `make verify REQ=2 STRICT=1`: `/readyz` = ok from the Mac with TLS verification on, SANs include 127.0.0.1 and localhost; 20 PASS.

### B-029 · [sre] kubeadm init rescue runs `kubeadm reset --force` on an existing cluster: wipes etcd
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 9236ac4
- **Report** (sre M2 r1): init is guarded only by `creates: admin.conf`; if it is missing on a live node, preflight fails (:6443, manifests, etcd dir) and the rescue resets, deleting /var/lib/etcd and PKI.
- **Root cause:** the only init guard was `creates: admin.conf`; a missing admin.conf on a live node sent init into the reset rescue.
- **Fix:** stat admin.conf, the apiserver manifest and etcd member dir; fail before init if a control plane exists without admin.conf. Fixed in the M2 tree, no own branch (user's choice).
- **Verification:** check-mode run of `init.yml` with admin.conf pointed at a missing file stops at the guard (init/reset never reached); idempotency changed=0; strict 1/2/8c 45 PASS.

## M3 — Calico

### B-030 · [sec] Calico images (privileged, hostNetwork) pulled by mutable tag only, no digest pins
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 7e58592
- **Report** (sec M3 r1): only the chart version is pinned; live pods run `quay.io/tigera/operator:v1.44.0`, `quay.io/calico/{node,calico,third-party-cni-plugins}:v3.33.0` by tag; a re-pushed tag runs as host root.
- **Root cause:** the chart and operator default to `image:tag`; no `ImageSet` or digest existed, so the privileged images were mutable.
- **Fix:** `tigeraOperator.version` is `tag@digest` in `values.yaml.j2`; `imageset.yaml.j2` (`calico-v3.33.0`: calico, node, third-party-cni-plugins) applied before the chart; digests in `versions.yml`.
- **Verification:** `make verify REQ=3a STRICT=1` (new digest + ImageSet checks) 15 PASS; pod specs run `@sha256:`; idempotency changed=0; REQ 1, 2, 8c PASS.

### B-031 · [sre] Matrix/ADR 0002 omit B-030 digest pinning and the new 3a checks (says 10, runs 15)
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 9ededee
- **Report** (sre M3 r2): `docs/requirements-matrix.md` 3a lists "10 checks" and no ImageSet/digest, requests or audit/warn label checks; ADR 0002 says only "chart (pinned)"; `check_3a` runs 15.
- **Root cause:** B-030 added the ImageSet/digest, requests and audit/warn checks without updating the matrix row or ADR 0002.
- **Fix:** matrix row 3a lists the 15 checks and pinning, status Done (M3); ADR 0002 documents digest pinning, bump procedure and accepted Lows; architecture Calico row notes digests.
- **Verification:** `check_3a` pass/fail calls counted in `scripts/verify.sh` = 15; docs read against `cni_calico` and `versions.yml`.

## M4 — Storage

### B-032 · local-path-provisioner crash-loops: helper pod template adds capabilities, fatal at startup
Sev: — · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 716f2e1
- **Report** (verify REQ 5): provisioner pod restarted 6× in 8 min; previous log: `helper pod template must not add capabilities unless allow-unsafe-helper-pod-template`.
- **Root cause:** the restarts (last 20:44:54) came from the role's first draft, whose helper template used `capabilities.add`; v0.0.37 rejects it without the unsafe flag.
- **Fix:** the helper template only drops capabilities (keeps DAC_OVERRIDE by not dropping it); live ConfigMap has no `add`.
- **Verification:** restartCount stayed 6, Ready, running since 20:47:36 through 20:54:35; `make verify REQ=5 STRICT=1` 15 PASS.

### B-033 · [sre] storage role passes on a stuck provisioner rollout: waits only for Deployment Available
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: 9fe3d95
- **Report** (sre round 1): `storage/tasks/main.yml` waits on `wait_condition: Available`; with 1 replica (maxUnavailable 0) the old pod keeps Available=True while a new template crash-loops, so provision is green.
- **Root cause:** with `wait_condition` set, kubernetes.core's `get_waiter()` uses a custom condition instead of `deployment_ready` (observedGeneration, replicas).
- **Fix:** `wait_condition` dropped from the storage role's rollout wait; comment says why.
- **Verification:** scratch Deployment in verify-tmp with a bad new image: old wait green, new wait fails; provision/idempotency changed=0; verify 5 15 PASS.

### B-034 · [sre] check_5 fails when re-run within ~10 s: verify-tmp still Terminating from the last run
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-18 · Fix: a3b8ac8
- **Report** (sre round 1): `make verify REQ=5 STRICT=1` 3x back to back: 1st 15 PASS, 2nd and 3rd FAIL `verify-tmp ... currently being deleted`; `cleanup_5` deletes the namespace with `--wait=false`.
- **Root cause:** `cleanup_5` deletes verify-tmp with `--wait=false`; the next run applied into the still-Terminating namespace.
- **Fix:** `wait_verify_ns_gone` in `scripts/verify.sh` waits for a Terminating verify-tmp to go before check_5 creates it; reusable by later checks.
- **Verification:** `make verify REQ=5 STRICT=1` twice back to back: 15 PASS both; 1/2/3a/8c strict 17/20/15/8 PASS; lint OK.

## M5 — PKI and Traefik

### B-008 · [sec] "Allow from Traefik" NetworkPolicy cannot match a hostNetwork Traefik
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-19 · Fix: 144f11c
- **Report** (sre round 1): hostNetwork traffic comes from the node IP, which selectors never match and NetworkPolicy always allows; the rule is a no-op.
- **Root cause:** hostNetwork traffic leaves from the node IP; pod/namespace selectors can't match it.
- **Fix:** user decision in ADR 0003: app NetworkPolicies allow ingress from the node IP (`ipBlock` /32) on the app port only; any hostNetwork process reaching it is accepted (single node).
- **Verification:** ADR 0003 Accepted; enforcement is proven by `check_3b` in M9 (normal pod denied).

### B-009 · [sre] hostNetwork Traefik cannot bind :443/:80 as non-root
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-19 · Fix: e31f4da
- **Report** (sre round 1): the Traefik chart runs as UID 65532 without capabilities on 8000/8443; binding 443/80 needs root or `NET_BIND_SERVICE`.
- **Root cause:** ports < 1024 need root or `NET_BIND_SERVICE`; the chart runs UID 65532 with no capabilities.
- **Fix:** Traefik listens on 8443/8000; `lima/k8s.yaml` forwards Mac 443→8443, 80→8000 (running VM edited + restarted, user-approved); ADR 0003.
- **Verification:** `make verify REQ=4 STRICT=1` 34 PASS (UID 65532, no caps, :8443/:8000 listening, Mac 443 TLS 200, :80 → 301); sre r1 confirmed.

### B-035 · [sec] Internal root CA has no name constraints: its key can mint trusted certs for any domain
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 768ad66
- **Report** (sec round 1): `openssl x509 -in certs/ca.crt -text`: no Name Constraints; 10-year key also in a cluster Secret and etcd snapshots; whoever trusts the CA (e.g. for grafana.local) is MITM-able anywhere.
- **Root cause:** the CA CSR in `pki/tasks/ca.yml` set no name constraints.
- **Fix:** critical permitted `DNS:local`, excluded `IP:0.0.0.0/0`, `IP:::/0` (`pki_ca_*_names`); CA regenerated (never committed); check_4 asserts it + `openssl s_client` chain verify.
- **Verification:** `openssl x509 -text` shows the constraints; macOS curl and openssl verify the leaf; `make verify REQ=4 STRICT=1` 39 PASS.

### B-036 · [sec] Traefik (Mac-facing, hostNetwork) can read every Secret, including the CA key
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: e31f4da
- **Report** (sec round 1): ClusterRole `traefik-traefik` grants secrets get/list/watch cluster-wide; `auth can-i get secrets -n cert-manager --as=system:serviceaccount:traefik:traefik` = yes (`internal-ca-key-pair`).
- **Root cause:** the chart's ClusterRole grants Secrets cluster-wide; its `rbac.namespaced` mode drops IngressClass access, so Ingresses with a class are ignored.
- **Fix:** chart RBAC off; own ClusterRole (ingressclasses, nodes) + per-namespace Roles for `ingress_traefik_watched_namespaces` (llm, monitoring, verify-tmp; created bare by the role), provider limited to them.
- **Verification:** `auth can-i get secrets` as the Traefik SA: no in cert-manager/kube-system/traefik; check_4 asserts it; verify 4 39 PASS twice; idempotency changed=0.

### B-037 · [sre] Fresh clone (ca.crt committed, no key) pairs a new CA key with the old cert, reports success
Sev: High · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 768ad66
- **Report** (sre round 1): `pki` ca.yml on a copy with only `certs/ca.crt`: key created, cert kept (changed=2, no error); cert/key pubkey sha256 `033d45…` vs `ee99a9…`.
- **Root cause:** ca.yml created a missing key and kept an existing cert without checking they pair.
- **Fix:** fail before key creation if the cert exists without the key; assert key/cert public-key sha256 match every run (no_log); check_4 compares pubkey hashes.
- **Verification:** scratch copies: cert-only fails with the restore/delete message, no key made; clean dir creates the pair then changed=0; swapped cert fails the assert.

### B-038 · [sre] A deleted watched namespace (e.g. verify-tmp) blanks every Ingress on Traefik restart
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: e31f4da
- **Report** (sre round 2): delete ns verify-tmp + Traefik pod restart: a `monitoring` route 503 → 404 for 60 s+ (Role gone, list forbidden, no sync), pod still Ready; back ~50 s after re-provision.
- **Root cause:** Traefik watched scratch ns verify-tmp; deleting it removed its Role, so after a restart the provider's lists were forbidden and it never synced.
- **Fix:** watch only role-owned llm, monitoring, `ingress-check` (check_4's own ns, never deleted); stale verify-tmp Role removed; role + check_4 assert a Role/RoleBinding per watched ns, no `forbidden` in logs.
- **Verification:** verify-tmp deleted + Traefik restarted → `make verify REQ=4 STRICT=1` 48 PASS (twice); idempotency changed=0. Runbook line + M6 Ingress-probe alert: docs pass / M6.

## M6 — Monitoring

### B-039 · [sec] Grafana (Mac-facing via Traefik) can read every Secret cluster-wide, including the CA key
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 83e1d34
- **Report** (sec M6 r1): ClusterRole `kps-grafana-clusterrole` grants secrets get/list/watch (sidecars `NAMESPACE=ALL`); `can-i list secrets -n cert-manager` as `kps-grafana` = yes; token in grafana too.
- **Root cause:** the chart's Grafana RBAC grants configmaps and secrets (ClusterRole when sidecars search ALL namespaces); sidecars defaulted to `resource: both`.
- **Fix:** chart RBAC off; own Role/RoleBinding (`grafana-rbac.yaml.j2`) for ConfigMaps in `monitoring`; sidecars `resource: configmap`, `searchNamespace: monitoring`.
- **Verification:** `can-i get/list secrets` as `kps-grafana` = no (cert-manager, kube-system, monitoring, cluster-wide); check_6 asserts it; 27 dashboards, datasource healthy; `make verify REQ=6 STRICT=1` 68 PASS.

### B-040 · [sec] node-exporter (hostPID, host / mounted) runs without no_new_privs, drop ALL or seccomp
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 83e1d34
- **Report** (sec M6 r1): container securityContext only `readOnlyRootFilesystem`; live `/proc/PID/status` NoNewPrivs 0, Seccomp 0, default CapBnd; host setuid sudo/su/mount under /host/root.
- **Root cause:** the node-exporter subchart's default `containerSecurityContext` only sets `readOnlyRootFilesystem`; the pod context has no seccomp.
- **Fix:** values set `allowPrivilegeEscalation: false`, drop ALL and seccomp RuntimeDefault (pod + container), read-only rootfs kept; host namespaces/mounts unchanged (PSA privileged).
- **Verification:** live container context shows the fields; node-exporter target UP, 24 filesystem series; check_6 asserts them; `make verify REQ=6 STRICT=1` 69 PASS; idempotency changed=0.

### B-041 · [sre] Grafana undersized: 299Mi RSS at idle vs 384Mi limit, 128Mi request (OOMKill/eviction risk)
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 83e1d34
- **Report** (sre M6 r1): `container_memory_rss` after start: grafana 299Mi (request 128Mi, limit 384Mi), each sidecar 76Mi (request 48Mi); query load adds heap.
- **Root cause:** requests/limits were guessed, not measured; after B-039 the sidecars still use ~78Mi each and Grafana 282Mi idle (366Mi after a verify run).
- **Fix:** grafana 320Mi/640Mi, sidecars 96Mi/160Mi, prometheus 512Mi, reloaders 24Mi, alertmanager 48Mi; check_6 asserts sums under caps in role defaults (requests 1536Mi, limits 3072Mi) instead of live MemAvailable.
- **Verification:** requests 1256Mi, limits 2624Mi, all 10 containers sized; `make verify REQ=6 STRICT=1` 70 PASS; idempotency changed=0.

### B-042 · [sre] Concurrent heavy PromQL queries OOMKill Prometheus (no query sample or concurrency caps)
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 83e1d34
- **Report** (sre M6 r3, reopened twice): 8 parallel wide `{__name__=~".+"}` ranges OOMKill Prometheus (137); caps 4 x 5M, then 4 x 1.5M at a 1Gi limit, still died (4 parallel peaked at 1002/1024Mi).
- **Root cause:** caps not sized to memory: wide raw results cost ~85 B/sample per in-flight query, JSON encoding overlaps queued queries, and GOGC=100 floats the heap to ~2x its ~600Mi live set.
- **Fix:** limit 1280Mi, GOGC=50, `query` concurrency 2 / maxSamples 1.2M / 1m; defaults hold 100 B/sample, overlap 2, headroom 500Mi; check_6 asserts the product, GOGC and no OOMKilled; Grafana request 384Mi.
- **Verification:** warm pod, 8 wide at 1.18M: anon 891Mi, current 1078Mi (84%); 8 count-by 876Mi; 16 wide: anon 1072Mi, no OOM; restarts 0; 252 rules ok; verify 6 73 PASS. (1.5M reached 94%.)

## M7 — etcd backup

### B-010 · [sre] etcd snapshots can silently land on the VM disk
Sev: Medium · State: Solved · Found: 2026-11-17 · Solved: 2026-11-19 · Fix: ec6b28b
- **Report** (sre round 1): `/mnt/host-backups` is the host mount only if `make vm-up` created the VM; otherwise snapshots stay on the VM disk unnoticed.
- **Root cause:** nothing tied `/mnt/host-backups` to the host mount; a plain directory on the VM disk accepted the snapshots.
- **Fix:** `etcd_backup` asserts a `virtiofs` mountpoint (findmnt), unit has `RequiresMountsFor=`, script exits 1 unless the dir is that mount; `check_7` compares host and node files.
- **Verification:** `make verify REQ=7 STRICT=1` 23 PASS (same file on host and node, script refuses `/var/tmp`, `RequiresMountsFor` set); idempotency changed=0.

## M9 — llm_app

### B-044 · [sec] Running llama-server keeps HTTPS egress to any public IP (model-download allow is pod-wide)
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 7a4808b
- **Report** (sec M9 r1): `allow-model-download` selects the server pod: the unauthenticated, Mac-facing server (image ships curl) reaches any public IP:443 for life (check_3b curls huggingface.co). Req 3b.
- **Root cause:** the model was fetched by the server's own init container, so the egress allow had to select the server pod; policies cannot target init containers. Contradicted ADR 0008.
- **Fix:** Ansible-run one-shot `model-fetch` Job (own label; only its pods get DNS + 443, excludes 100.64/10), skipped while the file is valid (B-045); init container only verifies (fails closed); `--no-slots`.
- **Verification:** before: llama-server curl to huggingface.co = 200; after: times out; `make verify REQ=3b/8b/9 STRICT=1` 18/19/18 PASS; idempotency changed=0 (role and bare).

### B-045 · [sre] Model-fetch gate trusts the PVC annotation, not the file: a lost model is never re-fetched
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-19 · Fix: 7a4808b
- **Report** (sre M9 r2): PV is hostPath `DirectoryOrCreate`; etcd restore on a rebuilt VM (runbook) or a damaged file leaves the annotation matching: Init:Error, Job skipped, rollout wait fails after 900s.
- **Root cause:** the Job gate was a PVC annotation, which survives an etcd restore or a lost/damaged file; the Job was skipped and the pod sat in `Init:Error`. Job failures were also only caught by the 900 s wait.
- **Fix:** gate on the file (PV `hostPath.path` + sha256 `stat` on the node, annotation dropped); Job polled for Complete/Failed, fails with its message; llama.cpp pods restarted after a fetch.
- **Verification:** model file renamed on the node (annotation matched, Init:Error): old gate skips; new role refetched, pod Ready; verify 3b/8b/9 PASS; idempotency changed=0 (role, bare).

## M10 — Final

### B-001 · ansible-lint warns: ansible-core 2.21.6 does not support Python 3.15
Sev: — · State: Solved · Found: 2026-11-17 · Solved: 2026-11-17 · Fix: 1949b07
- **Report** (setup): `ansible-lint --version` warned ansible-core 2.21.6 supports Python ≤ 3.14; Homebrew built it on 3.15.
- **Root cause:** Homebrew builds both ansible-lint and ansible on Python 3.15 (ansible silently).
- **Fix:** pinned `.venv` on Python 3.14 (`requirements.txt`, `make tools`), first on PATH for make targets and the lint hook.
- **Verification:** tools report Python 3.14.5 with no warning; `make lint` clean; second `make tools` does nothing.

### B-027 · [sre] Exact Debian apt pins vanish after the next DSA/point release: clean rebuild fails
Sev: Medium · State: Solved · Found: 2026-11-18 · Solved: 2026-11-20 · Fix: 063a20b
- **Report** (sre M1 r1): `apt-cache madison curl`: pinned `+deb13u7` exists only in trixie-security; the next DSA removes it and `os_prep` fails on a clean VM.
- **Root cause:** exact `pkg=ver` pins were only resolvable from the live mirrors, which keep just the newest version.
- **Fix:** `os_prep` adds snapshot.debian.org sources at `debian_snapshot_timestamp` (versions.yml); live mirrors stay first, so apt falls back to the snapshot.
- **Verification:** `apt-cache madison` lists a snapshot line for all 11 pins; idempotency changed=0; `make verify REQ=1 STRICT=1` PASS.

### B-043 · [sre] Parallel `/api/v1/series` over all series OOMKills Prometheus (bypasses the query caps)
Sev: Medium · State: Solved · Found: 2026-11-19 · Solved: 2026-11-20 · Fix: dcb66f1
- **Report** (sre M6 B-042 r3): 16 parallel `series?match[]={__name__=~".+"}` (3d, 147k series, 47MB each) OOMKilled Prometheus twice; 8 peaked 1255/1280Mi. `--query.*` caps skip this path.
- **Root cause:** `--query.*` skip the series/label APIs; Prometheus 3.15.1 has no flag or default for them (checked live), only a per-request `limit=`. ~700 B heap per series per call.
- **Fix:** Grafana datasource `seriesLimit` 5000; unbounded admin calls are an accepted residual (4 parallel fit, 8 do not; assumptions.md); check_6 load-tests 16 limited + 4 unbounded calls.
- **Verification:** 16 unbounded at 56k series: peak 876Mi; verify load 333 to 496Mi, 0 restarts; `make verify REQ=6 STRICT=1` 76 PASS twice; idempotency changed=0.

### B-046 · [sec] `.venv` installs the latest pip and unpinned, unhashed transitive deps (only 3 top-level pins)
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: 08e4e82
- **Report** (sec make-bootstrap r1): `Makefile:111` `--upgrade pip` (latest); `requirements.txt` pins 3 packages, no hashes; transitive deps float, run on the host beside `.secrets/`.
- **Root cause:** `requirements.txt` held only the 3 top-level pins and the venv recipe ran `pip install --upgrade pip`, so pip and 26 transitive packages resolved to whatever was newest.
- **Fix:** top-level pins moved to `requirements.in`; `requirements.txt` is a pip-compile hash lock (29 pkgs, versions = the verified venv); `pip install --require-hashes --only-binary=:all:`, bundled pip, no upgrade.
- **Verification:** venv rebuilt (pip 26.2.2, `pip check` OK); wheels hashed for macOS arm64 + Linux arm64/amd64 (PyPI); `make idempotency` changed=0; all 12 IDs strict PASS; sec re-check: resolved.

### B-047 · [sre] `make uninstall` never reverts the Linux sysctl: its confirm reads the manifest, not the tty
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: 7a5d91b
- **Report** (sre make-bootstrap r1): `while read … done < <(awk … manifest)` takes stdin, so `confirm` skips on a real tty (pty repro); `.tools/` removal then deletes the manifest: sysctl stays at 80, unrecorded.
- **Root cause:** the sysctl prompts ran inside `while read ... done < <(awk ... manifest)`, so `confirm` saw the manifest as stdin (no tty) and skipped; the `.tools/` step then deleted the manifest.
- **Fix:** entries collected into an array first, prompts run outside the redirect; `step` sets `STEP_DONE`; a kept package/sysctl entry makes the `.tools/` step keep `system-manifest`.
- **Verification:** pty driver, fake sudo, scratch copy: old script skips + deletes manifest; new: y reverts, n keeps manifest; no tty and DRY_RUN fine; lint clean; verify 1 strict PASS.

### B-048 · [sre] README quick start (`make provision`, `make e2e`) fails on any fresh clone in `pki`: no CA key
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: 3a73620
- **Report** (sre docs-rewrite r1): `certs/ca.crt` is committed, `.secrets/ca.key` never is; `pki/tasks/ca.yml` (B-037 guard) fails; README/install.md give no step for it, only troubleshooting.md does.
- **Root cause:** the quick start assumed the author's CA key exists; install.md even claimed a keyless provision makes a new CA, while the B-037 guard stops it.
- **Fix:** README step 2 and install.md say what to do on a fresh clone (restore the key, or `rm certs/ca.crt` and trust the new CA), linking troubleshooting.
- **Verification:** fresh clone: cert present, key missing (guard path); README/install.md now cover it; links resolve; `make lint` clean.

### B-049 · [sre] Linux host: Lima QEMU default mount is 9p, `etcd_backup` requires `virtiofs`: provision fails
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: 1f16b11
- **Report** (sre M10 r1): `lima/k8s.yaml` drops `mountType`; Lima 2.3 resolves it to `9p` on QEMU (`templates/default.yaml:113`), but `etcd_backup_mount_fstype: virtiofs` is asserted by the role, the script and check_7.
- **Root cause:** the role hard-coded one host-mount fstype while Lima picks it per VM type.
- **Fix:** `etcd_backup_mount_fstypes: [virtiofs, 9p]` feeds the assert, the unit env (`MOUNT_FSTYPES`, comma list) and the script; empty or any other type (ext4) is still refused (B-010); check_7 parses the list.
- **Verification:** script run with a fake `findmnt`: 9p and virtiofs pass the guard, ext4 and empty refused; lint clean, provision + idempotency (role, whole playbook) changed=0, verify 7 strict 23 PASS.

### B-050 · [sre] etcd restore runbook: member comes back on `http://localhost:2380`; rebuilt-VM path untested
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: d37e058
- **Report** (sre M10 r1 drill): plain `etcdutl snapshot restore` leaves peer URL `http://localhost:2380`; rebuilt-VM restore untested, runbook said "planned for M10".
- **Root cause:** restore ran without member flags; a rebuilt VM has a new kubeadm CA + SA key and empty PV dirs (kubelet recreates them root 0755).
- **Fix:** runbook passes `--name/--initial-cluster/--initial-advertise-peer-urls`; rebuilt VM: chmod PV dirs, restart all pods, reissue legacy SA tokens, `make provision`.
- **Verification:** old-VM snapshot restored after `make e2e`: peer `https://192.168.5.15:2380`, markers right, `make verify STRICT=1` all 12 IDs PASS.

### B-051 · [sec] `kubectl describe secret` prints SA token values; CLAUDE.md calls it the safe check
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: f48b3ed
- **Report** (orchestrator, M10 restore drill): `describe` of `kps-prometheus-token` printed the JWT into the transcript; token reissued twice (lookup on), printed one invalid.
- **Root cause:** `.claude/settings.json` allowed `describe:*` for every kind, and `CLAUDE.md`/ADR 0009 named `describe secret` as the safe existence check.
- **Fix:** deny `*kubectl* describe *secret*` (+ `describe -f`); `CLAUDE.md`, ADR 0009: check names with `-o name`; runbook warns.
- **Verification:** `describe secret grafana-admin` is now refused by the harness; `verify.sh` keeps its own describe output internal.

### B-052 · [sec] `describe Secret` (capitalized kind) bypasses the B-051 deny and is auto-allowed
Sev: Medium · State: Solved · Found: 2026-11-20 · Solved: 2026-11-20 · Fix: f48b3ed
- **Report** (security M10 r2): kubectl kinds are case-insensitive (`describe Namespace llm` works); deny `*kubectl* describe *secret*` misses `Secret`/`SECRET`, allow `describe:*` approves them unprompted.
- **Root cause:** glob rules are case-sensitive and a blanket `describe:*` allow approved any spelling the deny missed.
- **Fix:** `describe` allowed only for the 47 listed kinds (like `get`); deny `*ecret*`, `*ECRET*`, `-f`, `-f=`, `--filename`; stale docs fixed.
- **Verification:** `describe Secret grafana-admin` and `describe secret …` both refused by the harness; `make lint` clean.

### B-053 · etcd restore runbook: kubelet keeps running the pre-restore pods
Sev: — · State: Solved · Found: 2026-11-21 · Solved: 2026-11-21 · Fix: e7b2129
- **Report** (rebuilt-VM drill with kept PKI): 26 min after the restore the node still ran VM 2's pods; their bound SA tokens failed ("Token does not match server's copy").
- **Root cause:** kubelet's pod watch stays at the newer pre-restore revision and never re-lists; B-050's "restart all pods" hid it.
- **Fix:** runbook restarts kubelet once the API is back (same and rebuilt VM).
- **Verification:** after `systemctl restart kubelet` the snapshot's pods ran within 3 s; `make provision` + all 12 IDs strict PASS.

### B-054 · [sre] Same-VM etcd restore: running controllers keep pre-restore watches; only kubelet re-lists
Sev: Medium · State: Solved · Found: 2026-11-21 · Solved: 2026-11-21 · Fix: 64dddf4
- **Report** (sre r1): B-053's cause (etcd revision goes back) hits every informer; same-VM restore keeps pods running, so kube-proxy, CoreDNS, Calico, cert-manager miss changes and deletions.
- **Root cause:** plain `etcdutl snapshot restore` resets the revision below what watchers hold; drill: kube-proxy kept a deleted Service's rules > 5 min.
- **Fix:** runbook restores with `--bump-revision 1000000000 --mark-compacted` (all watchers re-list); `check_4` scans only 15 min of Traefik log (restore leaves a one-off "forbidden").
- **Verification:** same-VM drill with the flags: kube-proxy dropped both stale rules in ~10 s; `make provision` changed=0; 12 IDs strict PASS.

### B-055 · [sre] `make chat` fails every turn once history exceeds the 2048-token slot; hint blames the VM
Sev: Medium · State: Solved · Found: 2026-11-21 · Solved: 2026-11-21 · Fix: 70b141e
- **Report** (sre r1): 4 essay prompts, then every message gets `curl: (56) ... error: 400` (`exceed_context_size_error`, n_ctx 2048 = 4096/`--parallel 2`); last reply cut silently; hint blames the VM.
- **Root cause:** `chat.sh` resent the whole history every turn and `--fail` dropped the server's error body, so one overflow broke every later turn.
- **Fix:** `--fail-with-body`; on `exceed_context_size_error` drop the oldest exchange and retry; print `error.message` (or curl's); note `finish_reason: length`.
- **Verification:** 3 long turns then short ones: trimmed and answered; a 2600-word message gets a clear note; 404/refused show the cause; REQ=9 strict PASS.

### B-056 · Linux amd64: `os_prep` fails, `conntrack`/`ebtables` pins exist only for arm64
Sev: — · State: Solved · Found: 2026-11-22 · Solved: 2026-11-22 · Fix: ca51e47
- **Report** (setup, Linux host): snapshot pool has `conntrack_1.4.8-2+b1` and `ebtables_2.0.11-6+b2` for arm64 only; amd64 has `1.4.8-2` / `2.0.11-6`.
- **Root cause:** Debian binNMU suffixes (`+bN`) are per architecture; the pins were looked up on the arm64 VM only.
- **Fix:** `os_base_packages` values may be `{arm64, amd64}` maps (`versions.yml`), picked by `os_prep_arch`; `pin-version` skill checks both arches.
- **Verification:** clean amd64 VM: `os_prep` installs all pins; `make verify REQ=1 STRICT=1` 19 PASS; `make idempotency` changed=0.

### B-057 · Linux: `verify.sh` file-mode checks read garbage, BSD `stat -f` tried first
Sev: — · State: Solved · Found: 2026-11-22 · Solved: 2026-11-22 · Fix: a562920
- **Report** (setup, Linux host): GNU `stat -f '%Lp' f` prints filesystem status and fails, so `fmode` = that block + `600`; checks 4, 6, 7, 8a misreport.
- **Root cause:** `stat -f … || stat -c …` assumed BSD `-f` fails on GNU; it succeeds partly and writes stdout.
- **Fix:** `file_mode` helper and `hstat` in `scripts/verify.sh` try `stat -c` first, BSD `stat -f` second.
- **Verification:** helper prints `600` for a 0600 file on Linux; REQ 4, 6, 7, 8a strict PASS on the Linux host.

### B-058 · Linux: `./backups` never mounts (no 9p in cloud kernel); virtiofs then locks up the VM
Sev: — · State: Solved · Found: 2026-11-22 · Solved: 2026-11-22 · Fix: 7950074
- **Report** (setup, Linux host): `genericcloud` kernel has no 9p, `/mnt/host-backups` stays empty; with virtiofs, QEMU RAM sits in 7.7G `/dev/shm`, fills it, guest soft-locks.
- **Root cause:** cloud kernel lacks 9p; Lima's QEMU virtiofs needs a shared-memory RAM backend in `/dev/shm` (half of host RAM).
- **Fix:** `lima/k8s.yaml` x86_64 image is Debian `generic` (same build, sha512 pinned), mount type left at Lima's default (9p on QEMU).
- **Verification:** `findmnt` shows 9p rw; root write + chmod 600 OK; `/dev/shm` stays 0%; REQ=7 strict 23 PASS; full provision OK.

### B-059 · macOS: every `https://llm.local` request waits 5 s in name lookup (no `::1` hosts line)
Sev: — · State: Solved · Found: 2026-11-23 · Solved: 2026-11-23 · Fix: 8104992
- **Report** (setup): `curl -w '%{time_namelookup}' https://llm.local/health` = 5.005 s, with `-4` 0.004 s; `/etc/hosts` has only the `127.0.0.1` line.
- **Root cause:** no AAAA answer in `/etc/hosts`, so macOS sends the `.local` AAAA query to mDNS, which times out after 5 s.
- **Fix:** `hosts-entry.sh` adds/removes a `::1` line too (upgrades the old single line), `--check`; `host-tools.sh` requires both (Lima listens `*:443`).
- **Verification:** after `--apply`: `time_namelookup` 0.004 s without `-4` (via `::1`); `make smoke` 0.18 s; `make doctor` OK; `make lint` clean.
