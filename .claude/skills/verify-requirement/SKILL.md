---
name: verify-requirement
description: Check one or all of the 9 assignment requirements against the live cluster with scripts/verify.sh, and on failure gather evidence (events, logs, describe) before anyone proposes a fix. Use when asked "is requirement N done?", "verify", "run the checks", or before closing a milestone.
---

# Verify a requirement

`scripts/verify.sh [N]` runs the checks for requirement N (1-9), or all of them. Output is a PASS/FAIL/SKIP table; exit code is non-zero on any FAIL.
Same through make: `make verify REQ=N`. The final acceptance test is `make smoke` (the curl from the assignment).

## What each requirement is checked by (keep in sync with `scripts/verify.sh` and `docs/requirements-matrix.md`)
| Req | Function | Key checks |
|---|---|---|
| 1 | `check_1` | containerd active, SystemdCgroup, swap off, sysctls, packages held (`apt-mark showhold`) |
| 2 | `check_2` | node Ready, no control-plane NoSchedule taint, kube-system pods Running |
| 3 | `check_3` | Calico ready; default-deny in app ns; a test pod from another ns cannot reach the app; Traefik can |
| 4 | `check_4` | ClusterIssuer Ready; leaf cert issued by internal CA (`openssl verify -CAfile certs/ca.crt`); `renewBefore` set; revision > 1 for the short-lived test cert |
| 5 | `check_5` | exactly one default StorageClass; a test PVC binds |
| 6 | `check_6` | Prometheus/Grafana/Alertmanager up; node + etcd rules loaded; etcd target UP; `Watchdog` firing in Alertmanager |
| 7 | `check_7` | backup timer active; newest file in `./backups` younger than 2× schedule; `etcdutl snapshot status` OK |
| 8 | `check_8` | operator kubeconfig: can list pods, cannot read secrets/create pods; root & privileged pods rejected in app ns; audit log grows on a request |
| 9 | `check_9` | llm pod Ready; curl over TLS returns a completion; pod delete → new pod Ready without re-download (fetch Job not rerun, model file mtime unchanged) |

## On FAIL
1. Don't fix yet. Collect evidence for the failing check:
   `kubectl --kubeconfig out/admin.conf get events -A --sort-by=.lastTimestamp | tail -30`,
   `describe` the failing object, `logs` (with `--previous` on restarts), node-side `journalctl -u kubelet|containerd -n 100`.
2. State the observed symptom and the most likely area (role + file).
3. Record it with the `bug` skill (Open), unless it is already tracked.
4. Only then hand it to the `ansible-engineer` agent (or fix it yourself if you are that agent).

## Adding a check
Each check is a bash function `check_N` in `scripts/verify.sh` that calls `pass "<msg>"`, `fail "<msg>"`, or `skip "<msg>"`.
Checks must clean up any test objects they create (use the `verify-tmp` namespace or `trap`).
