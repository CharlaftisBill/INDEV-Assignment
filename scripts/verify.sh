#!/usr/bin/env bash
# Requirement checks for the INDEV single-node Kubernetes assignment.
#   scripts/verify.sh            # all requirements
#   scripts/verify.sh 4 8c       # requirement 4 and sub-requirement 8c (3 = 3a 3b, 8 = 8a 8b 8c)
#   scripts/verify.sh --strict   # SKIP counts as failure (make e2e, closing a milestone)
# Prints a PASS/FAIL/SKIP line per check and a summary; exits 1 if anything FAILed
# (or, with --strict / VERIFY_STRICT=1, if anything was SKIPped: a check that didn't run proves nothing).
# Each check_N is implemented in the milestone that delivers requirement N (see TODO.md).
# Checks must be read-only, or create test objects only in the "verify-tmp" namespace and clean them up.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM="${VM:-k8s}"
KUBECONFIG_ADMIN="${ROOT}/out/admin.conf"
KUBECONFIG_OPERATOR="${ROOT}/out/operator.conf"
CA_CERT="${ROOT}/certs/ca.crt"
LLM_HOST="${LLM_HOST:-llm.local}"

PASS=0; FAIL=0; SKIP=0
CURRENT_REQ=""

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi

pass() { PASS=$((PASS + 1)); printf '  %sPASS%s [%s] %s\n' "$G" "$N" "$CURRENT_REQ" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  %sFAIL%s [%s] %s\n' "$R" "$N" "$CURRENT_REQ" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sSKIP%s [%s] %s\n' "$Y" "$N" "$CURRENT_REQ" "$1"; }

# Helpers
node()  { limactl shell "$VM" -- sudo "$@"; }                      # run a command on the node
k()     { kubectl --kubeconfig "$KUBECONFIG_ADMIN" "$@"; }         # admin kubectl from the host
kop()   { kubectl --kubeconfig "$KUBECONFIG_OPERATOR" "$@"; }      # operator kubectl from the host
need_cluster() {
  if [[ ! -f "$KUBECONFIG_ADMIN" ]]; then skip "no ${KUBECONFIG_ADMIN#"$ROOT"/} yet (M2)"; return 1; fi
}

# ------------------------------------------------------------------ checks
check_1() { # OS preparation, containerd, pinned packages
  skip "not implemented (M1)"
}

check_2() { # kubeadm single node, schedulable control plane
  need_cluster || return 0
  skip "not implemented (M2)"
}

check_3a() { # CNI installed and healthy (M3)
  need_cluster || return 0
  skip "not implemented (M3)"
}

check_3b() { # app pods accept only the traffic they need: NetworkPolicies in app namespaces (M9)
  need_cluster || return 0
  skip "not implemented (M9)"
}

check_4() { # Ingress + internal CA TLS + auto renewal
  need_cluster || return 0
  skip "not implemented (M5)"
}

check_5() { # default StorageClass
  need_cluster || return 0
  skip "not implemented (M4)"
}

check_6() { # Prometheus, Grafana, node + etcd alerts in Alertmanager
  need_cluster || return 0
  skip "not implemented (M6)"
}

check_7() { # scheduled etcd snapshots stored outside the cluster
  skip "not implemented (M7)"
}

check_8a() { # read-only operator role + operator kubeconfig (M8)
  need_cluster || return 0
  skip "not implemented (M8)"
}

check_8b() { # app workloads cannot run as root / privileged: PSA restricted on app namespaces (M9)
  need_cluster || return 0
  skip "not implemented (M9)"
}

check_8c() { # every API request recorded: audit policy + log (M2)
  need_cluster || return 0
  skip "not implemented (M2)"
}

check_9() { # llama.cpp over TLS, model cached across restarts
  need_cluster || return 0
  skip "not implemented (M9)"
}

# ------------------------------------------------------------------ main
# Check IDs. Requirements 3 and 8 are delivered across milestones, so they are split into
# sub-IDs; each milestone line in TODO.md names exactly the IDs it delivers.
ALL_IDS="1 2 3a 3b 4 5 6 7 8a 8b 8c 9"

title() {
  case "$1" in
    1)  echo "OS preparation + containerd + pinned packages" ;;
    2)  echo "kubeadm single node" ;;
    3a) echo "CNI installed and healthy" ;;
    3b) echo "NetworkPolicies: app pods accept only needed traffic" ;;
    4)  echo "Ingress + internal CA TLS + renewal" ;;
    5)  echo "Default StorageClass" ;;
    6)  echo "Monitoring + node/etcd alerts" ;;
    7)  echo "etcd backups outside the cluster" ;;
    8a) echo "Read-only operator role + kubeconfig" ;;
    8b) echo "App workloads non-root / unprivileged" ;;
    8c) echo "Every API request audited" ;;
    9)  echo "llama.cpp sample application" ;;
  esac
}

# "3" and "8" expand to their sub-IDs; anything else must be a known ID.
expand() {
  case "$1" in
    3) echo "3a 3b" ;;
    8) echo "8a 8b 8c" ;;
    *) if [[ " $ALL_IDS " == *" $1 "* ]]; then echo "$1"; else return 1; fi ;;
  esac
}

STRICT="${VERIFY_STRICT:-0}"
ids=()
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; echo "IDs: $ALL_IDS (3 = 3a 3b, 8 = 8a 8b 8c)"; exit 0 ;;
    *)
      # Validate every argument before running any check
      if ! exp="$(expand "$arg")"; then
        echo "unknown requirement: $arg (expected one of: $ALL_IDS, or 3 / 8 for all their parts)" >&2; exit 2
      fi
      for id in $exp; do ids+=("$id"); done ;;
  esac
done
if [[ ${#ids[@]} -eq 0 ]]; then
  for id in $ALL_IDS; do ids+=("$id"); done
fi

if ! limactl list --quiet 2>/dev/null | grep -qx "$VM"; then
  echo "${Y}warning:${N} Lima VM '$VM' not found; node-side checks will fail or skip."
fi

for id in "${ids[@]}"; do
  CURRENT_REQ="$id"
  printf '%s%s. %s%s\n' "$B" "$id" "$(title "$id")" "$N"
  "check_$id"
done

echo
printf '%sSummary:%s %s%d PASS%s · %s%d FAIL%s · %s%d SKIP%s\n' "$B" "$N" "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [[ $FAIL -gt 0 ]]; then exit 1; fi
if [[ "$STRICT" == "1" && $SKIP -gt 0 ]]; then
  echo "${R}strict mode:${N} $SKIP check(s) skipped; a skipped check proves nothing." >&2
  exit 1
fi
exit 0
