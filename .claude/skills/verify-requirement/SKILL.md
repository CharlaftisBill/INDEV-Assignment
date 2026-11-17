---
name: verify-requirement
description: Check one or all of the 9 assignment requirements against the live cluster with scripts/verify.sh, and on failure gather evidence (events, logs, describe) before anyone proposes a fix. Use when asked "is requirement N done?", "verify", "run the checks", or before closing a milestone.
---

# Verify a requirement

`scripts/verify.sh [N]` runs the checks for requirement ID N (`1 2 3a 3b 4 5 6 7 8a 8b 8c 9`; `3` and `8` expand to their parts), or all of them. Each milestone line in `TODO.md` names the IDs it delivers. Output is a PASS/FAIL/SKIP table; exit code is non-zero on any FAIL.
Same through make: `make verify REQ=N`. Add `--strict` (`make verify STRICT=1`) whenever the result decides something (closing a milestone or a bug, `make e2e`): then SKIP fails too, because a check that did not run proves nothing. The final acceptance test is `make smoke` (the curl from the assignment).

## What each requirement is checked by (keep in sync with `scripts/verify.sh` and `docs/requirements-matrix.md`)
| Req | Function | Key checks |
|---|---|---|
| 1 | `check_1` | containerd active, SystemdCgroup, swap off, sysctls, packages held (`apt-mark showhold`) |
| 2 | `check_2` | node Ready, no control-plane NoSchedule taint, kube-system pods Running |
| 3a | `check_3a` | Calico ready; pods get IPs from the pod CIDR |
| 3b | `check_3b` | default-deny in app ns; a test pod from another ns cannot reach the app; the ingress path can |
| 4 | `check_4` | ClusterIssuer Ready; leaf cert issued by internal CA (`openssl verify -CAfile certs/ca.crt`); `renewBefore` set; revision > 1 for the short-lived test cert |
| 5 | `check_5` | exactly one default StorageClass; a test PVC binds |
| 6 | `check_6` | Prometheus/Grafana/Alertmanager up; node + etcd rules loaded; etcd target UP; `Watchdog` firing in Alertmanager |
| 7 | `check_7` | backup timer active; newest file in `./backups` younger than 2× schedule; `etcdutl snapshot status` OK |
| 8a | `check_8a` | operator kubeconfig: can list pods, cannot read secrets/create pods |
| 8b | `check_8b` | root & privileged pods rejected in app ns |
| 8c | `check_8c` | audit log grows on a request; policy has no `None` rules |
| 9 | `check_9` | llm pod Ready; curl over TLS returns a completion; pod delete → new pod Ready without re-download (fetch Job not rerun, model file mtime unchanged) |

## On FAIL
1. Don't fix yet. Collect evidence for the failing check:
   `kubectl --kubeconfig out/admin.conf get events -A --sort-by=.lastTimestamp | tail -30`,
   `describe` the failing object, `logs` (with `--previous` on restarts), node-side `journalctl -u kubelet|containerd -n 100`.
2. State the observed symptom and the most likely area (role + file).
3. Record it with the `bug` skill (Open), unless it is already tracked.
4. Only then hand it to the `ansible-engineer` agent (or fix it yourself if you are that agent).

## Adding a check
Each check is a bash function `check_<id>` (e.g. `check_8c`) in `scripts/verify.sh` that calls `pass "<msg>"`, `fail "<msg>"`, or `skip "<msg>"`.
Checks must clean up any test objects they create (use the `verify-tmp` namespace or `trap`).
