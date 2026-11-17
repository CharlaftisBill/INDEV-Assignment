#!/usr/bin/env bash
# Requirement checks for the INDEV single-node Kubernetes assignment.
#   scripts/verify.sh        # all requirements
#   scripts/verify.sh 4      # requirement 4 only
# Prints a PASS/FAIL/SKIP line per check and a summary; exits 1 if anything FAILed.
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

check_3() { # CNI + NetworkPolicies
  need_cluster || return 0
  skip "not implemented (M3/M9)"
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

check_8() { # operator RBAC + kubeconfig, PSA restricted, API audit
  need_cluster || return 0
  skip "not implemented (M2 audit, M8 RBAC/PSA)"
}

check_9() { # llama.cpp over TLS, model cached across restarts
  need_cluster || return 0
  skip "not implemented (M9)"
}

# ------------------------------------------------------------------ main
TITLES=(
  ""
  "OS preparation + containerd + pinned packages"
  "kubeadm single node"
  "CNI + NetworkPolicies"
  "Ingress + internal CA TLS"
  "Default StorageClass"
  "Monitoring + alerts"
  "etcd backups outside the cluster"
  "Hardening (RBAC, PSA, audit)"
  "llama.cpp sample application"
)

reqs=("$@")
[[ ${#reqs[@]} -eq 0 ]] && reqs=(1 2 3 4 5 6 7 8 9)

if ! limactl list --quiet 2>/dev/null | grep -qx "$VM"; then
  echo "${Y}warning:${N} Lima VM '$VM' not found; node-side checks will fail or skip."
fi

for n in "${reqs[@]}"; do
  if ! [[ "$n" =~ ^[1-9]$ ]]; then echo "unknown requirement: $n (expected 1-9)" >&2; exit 2; fi
  CURRENT_REQ="$n"
  printf '%s%s. %s%s\n' "$B" "$n" "${TITLES[$n]}" "$N"
  "check_$n"
done

echo
printf '%sSummary:%s %s%d PASS%s · %s%d FAIL%s · %s%d SKIP%s\n' "$B" "$N" "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$SKIP" "$N"
[[ $FAIL -eq 0 ]]
