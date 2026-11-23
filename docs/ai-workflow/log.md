# Log

What happened in each milestone: what the agents caught and what the user decided.
Bug details are in [bugs](bugs.md).

## M0 — Scaffolding (2026-11-17)

- Planned with the user, who chose Lima, Calico, Traefik and Ansible on the Mac, and asked for Open/Solved bug tracking.
- Built the repo layout, Makefile, lint, Lima config, Ansible skeleton, stub checks, ADRs 0001–0008 and the agent setup.
- Added `split-commits` and the `commit-msg` hook (no AI attribution, the user's rule), then `fix-next-bug`,
  `sre-reviewer` and `review-loop`. Only Critical/High/Medium findings become bugs, so the loop ends.
- B-002 (collections silently not installed) found while checking the setup. B-001's fix (pinned `.venv` on
  Python 3.14) had a regression (yamllint linted `.venv/`), caught before closing.

**First review-loop** (whole repo, no VM yet): 5 rounds, then the limit.

| Round | Opened | Notes |
|---|---|---|
| 1 | B-004–B-010 | B-007–B-010 deferred to the milestones of their roles |
| 2 | B-011–B-014 | Fixes had stopped at the file where the bug was reported |
| 3 | B-015–B-017 | The user chose the permission model (allow-list + ask) |
| 4 | B-018, B-019 | The user approved [ADR 0009](../decisions/0009-agent-permissions-guardrail.md) |
| 5 | B-020 | Limit reached; asked the user |

It caught real defects, such as a `make` command injection and checks that passed on skipped tests. 7 of 17 findings
were permission rules: each fix led to new gaps, because text-matching rules never converge (hence ADR 0009).
Afterwards the user capped the loop at **2 rounds** and bug details at **5 lines**, and asked for a readable bug list (now [bugs.md](bugs.md)).

**Then (2026-11-18):** a cost pass ([cost settings](cost.md); the user chose Sonnet for `ansible-engineer`); a branch
per milestone and per bug ([git workflow](git-workflow.md)); B-020 fixed with exact `make` allows. The first
review before a PR found B-021 and B-022 in that fix; both fixed on their own branches. PR #2.

## M1 — OS prep and containerd (2026-11-18)

- `review-loop`, 2 rounds: B-024 (handler flush), B-025 (UDP forwards), B-026 (runc CVEs, accepted), B-027 (apt pins,
  deferred to M10), B-028 (the B-025 fix broke loopback forwards). B-023 came from the first provision.
- Strict verify 17/17 on a fresh VM and after a restart.

## M2 — kubeadm and audit (2026-11-18)

- `sre-reviewer` ran disruptive tests (kubelet and containerd restarts, VM reboot; all recovered) and found B-029:
  the init rescue could reset an existing cluster. Round 2 clean. B-007 solved.

## M3 — Calico (2026-11-18)

- `ansible-engineer` ran `make vm-reset` without asking (process note). `k8s-verifier`: 55/55.
- `security-reviewer` found B-030 (images by tag, now by digest); `sre-reviewer` found B-031 (docs) and tested that the
  digest check fails when it should.

## M4 — Storage (2026-11-18)

- B-032 (provisioner crash from `capabilities.add`), B-033 (rollout wait), B-034 (`check_5` re-run race); all fixed.
  A reviewer test settled `DAC_OVERRIDE` ([ADR 0004](../decisions/0004-local-path-storage.md)).

## M5 — PKI and Traefik (2026-11-19)

- B-035 to B-038. Caught: Traefik could read the CA key (chart ClusterRole), and a fresh clone made a CA that didn't
  match the committed `ca.crt`. B-008 and B-009 closed by decisions ([ADR 0003](../decisions/0003-traefik-ingress.md)).

## M6 — Monitoring (2026-11-19)

- B-039 (Grafana credentials), B-040 (node-exporter hardening), B-041 (memory budget), B-042 (Prometheus out of memory).
- B-042 took three tries, each re-checked with the user's approval beyond the 2-round cap. The last re-check found
  B-043 (`/api/v1/series` skips the query limits), deferred to M10 as an accepted risk.
- The reviewer's real alert test became the [alert demo](../runbooks/alert-demo.md).

## M7 — etcd backup (2026-11-19)

- 1 round, clean. B-010 (snapshots could land on the VM disk) solved. Restore test deferred to M10.

## M8 — Operator role (2026-11-19)

- 1 round with both reviewers, no bugs. Lows in [ADR 0011](../decisions/0011-operator-identity.md).

## M9 — llm_app (2026-11-20)

- B-044 (outbound access for the whole pod; now only the download Job) and B-045 (an annotation decided when to
  download; now the file hash). The user approved a targeted re-check instead of a third round; clean.

## Host bootstrap (2026-11-20)

- `make doctor`, `deps`, `uninstall`, built in a side session. B-046 (venv not hash-locked), B-047 (uninstall's sysctl
  prompt). Round 2 clean; all 12 IDs pass strict.
- A fake-`limactl` test showed GNU make 3.81 ignores the exported `PATH` for some lines ([ADR 0012](../decisions/0012-host-toolchain.md)).

## M10 — Final (2026-11-20)

- `review-loop` 2 rounds. r1: `sre-reviewer` B-049 (virtiofs-only assert) and B-050 (restore runbook untested on a
  rebuilt VM), `security-reviewer` clean. r2: sre clean, security B-052 (`describe Secret` case bypass).
- B-051 came from the orchestrator in the restore drill: an agent printed a service-account token with `describe secret`.
  The token was rotated and the guardrail tightened ([ADR 0009](../decisions/0009-agent-permissions-guardrail.md)).
- Disruptive tests (kubelet, containerd, pod delete, VM reboot, both restore drills) and `make e2e` from a destroyed VM
  passed: 313 PASS, 0 FAIL, 0 SKIP.

## Docs rewrite (2026-11-20)

- The user asked for smaller, simpler docs, one topic per file. README and `docs/` rewritten; `ai-workflow.md` and
  the monitoring runbook split. Bugs moved to [bugs.md](bugs.md), assumptions to `docs/assumptions.md`.
- `review-loop` r1: `sre-reviewer` opened B-048 (README quick start fails on a fresh clone: no CA key), fixed;
  `security-reviewer` clean. Lows not folded and round 2 skipped (user: docs-only branch).
- 2026-11-21, `chore/persist-kubeadm-pki` (kubeadm PKI kept across rebuilds): rebuilt-VM drill found B-053 (kubelet
  keeps pre-restore pods). `review-loop` r1: `sre-reviewer` opened B-054 (every watcher stale after a same-VM
  restore), reproduced and fixed with `--bump-revision --mark-compacted`; `security-reviewer` clean (3 Lows).
- 2026-11-21, `chore/monitoring-ui-port-forward` (`make monitoring-ui`, `make chat`, brief .pdf → .md): `review-loop` r1:
  `sre-reviewer` opened B-055 (`make chat` dead after the 2048-token context fills), fixed on `fix/b-055-*` (trim oldest
  exchange, show the server's error); `security-reviewer` clean (Lows: control chars, body in `ps`, both folded in). r2: both clean.
- 2026-11-22, `chore/linux-host-support` (first Linux host, Ubuntu 24.04 amd64): fixed B-056 (arm64-only apt binNMU pins),
  B-057 (GNU `stat`), B-058 (no 9p in `genericcloud`; virtiofs on QEMU filled `/dev/shm` and froze the VM → `generic` x86_64
  image + 9p); `make provision` asks restore/new CA on a fresh clone. `review-loop` r1 (disruptive, incl. VM restart):
  `sre-reviewer` and `security-reviewer` clean; Lows folded in (CA check before `e2e`'s `vm-reset`, `TAGS=all`, Ctrl-D).
- 2026-11-23, `fix/b-059-hosts-ipv6-entry` (`::1` hosts line, 5 s macOS lookup → 0.004 s): `review-loop` r1: `security-reviewer`
  opened B-060 (`hosts-entry.sh` rewrite could wipe `/etc/hosts` on a grep error; `sre-reviewer` added the GNU non-UTF-8 case),
  fixed on `fix/b-060-*` (byte-wise grep, abort if any other line would be lost); sec re-check and r2 `sre-reviewer` clean.
- 2026-11-23, `fix/b-097-airgap-cidrs` (air gap no longer allows off-node pod/Service CIDRs): `security-reviewer`'s re-check
  caught B-098 in the fix (node → pod-backed ClusterIPs rejected, cert-manager webhook failing closed); fixed with
  `ct status dnat`, re-check clean. A failed `fib oifname` attempt left the VM without the firewall: B-099 opened.
