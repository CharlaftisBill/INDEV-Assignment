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
  CURRENT_REQ=1
  if ! limactl list --quiet 2>/dev/null | grep -qx "$VM"; then fail "Lima VM '$VM' not found"; return 0; fi

  if [[ "$(node systemctl is-active containerd 2>&1)" == "active" ]]; then pass "containerd is active"; else fail "containerd is not active"; fi

  local cfg; cfg="$(node containerd config dump 2>&1)"
  if grep -Eq '^[[:space:]]*SystemdCgroup = true' <<<"$cfg"; then pass "containerd effective config: SystemdCgroup = true"; else fail "SystemdCgroup is not true in 'containerd config dump'"; fi
  if grep -Eq '^disabled_plugins = \[\]' <<<"$cfg"; then pass "containerd CRI plugin enabled"; else fail "containerd disables plugins (CRI?)"; fi

  local swap; swap="$(node swapon --show --noheadings 2>&1)"
  if [[ -z "$swap" ]]; then pass "swap is off"; else fail "swap is on: $swap"; fi
  if node grep -Eq '^[^#]\S*\s+\S+\s+swap\s' /etc/fstab; then fail "fstab still has an active swap entry"; else pass "no active swap entry in fstab"; fi

  local mods m; mods="$(node cat /proc/modules 2>&1)"
  for m in overlay br_netfilter; do
    if grep -q "^$m " <<<"$mods"; then pass "kernel module $m loaded"; else fail "kernel module $m not loaded"; fi
    if node grep -rqx "$m" /etc/modules-load.d/; then pass "kernel module $m persisted"; else fail "kernel module $m not in /etc/modules-load.d"; fi
  done

  local key
  for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
    if [[ "$(node sysctl -n "$key" 2>&1)" == "1" ]]; then pass "sysctl $key = 1"; else fail "sysctl $key != 1"; fi
    if node grep -rqE "^$key[[:space:]]*=[[:space:]]*1\$" /etc/sysctl.d/; then pass "sysctl $key persisted"; else fail "sysctl $key not persisted in /etc/sysctl.d"; fi
  done

  local holds pkg; holds="$(node apt-mark showhold 2>&1)"
  for pkg in containerd runc; do
    if grep -qx "$pkg" <<<"$holds"; then pass "$pkg is held (apt-mark showhold)"; else fail "$pkg is not held"; fi
  done
}

# Pinned value from versions.yml (single source of truth), e.g. pinned kubernetes_version -> 1.35.10-1.1
pinned() { sed -n "s/^$1: \"\\([^\"]*\\)\".*/\\1/p" "$ROOT/ansible/group_vars/all/versions.yml"; }
NODE_NAME="${NODE_NAME:-k8s-node}"

check_2() { # kubeadm single node, schedulable control plane (node Ready, control-plane pods healthy; CNI details: check_3a)
  need_cluster || return 0

  # B-007: the host kubeconfig uses Lima's 127.0.0.1 forward and kubectl verifies the API server cert.
  local server insecure
  server="$(k config view -o jsonpath='{.clusters[0].cluster.server}' 2>&1)"
  insecure="$(k config view -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}' 2>&1)"
  if [[ "$server" == "https://127.0.0.1:6443" && -z "$insecure" ]]; then pass "out/admin.conf: server https://127.0.0.1:6443, TLS verification on"
  else fail "out/admin.conf: server '$server', insecure-skip-tls-verify '$insecure'"; fi
  if [[ "$(k get --raw /readyz 2>&1)" == "ok" ]]; then pass "API /readyz = ok from the host over verified TLS"; else fail "API /readyz from the host failed (TLS or API server)"; fi
  local sans; sans="$(node openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -ext subjectAltName 2>&1)"
  if grep -q 'IP Address:127.0.0.1' <<<"$sans" && grep -q 'DNS:localhost' <<<"$sans"; then pass "API server cert SANs include 127.0.0.1 and localhost"
  else fail "API server cert SANs lack 127.0.0.1/localhost: $sans"; fi

  # One node, registered as control plane, running the pinned version
  local nodes; nodes="$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)"
  if [[ "$nodes" == "$NODE_NAME" ]]; then pass "exactly one node: $NODE_NAME"; else fail "nodes: $(tr '\n' ' ' <<<"$nodes")"; fi
  if k get node "$NODE_NAME" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q '"node-role.kubernetes.io/control-plane"'; then pass "$NODE_NAME has the control-plane role"
  else fail "$NODE_NAME lacks the control-plane role label"; fi
  local want kubelet_v server_v
  want="v$(pinned kubernetes_version | sed 's/-.*//')"
  kubelet_v="$(k get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>&1)"
  server_v="$(k version -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\(v[^"]*\)".*/\1/p' | tail -1)"
  if [[ "$kubelet_v" == "$want" && "$server_v" == "$want" ]]; then pass "kubelet and API server at pinned $want"
  else fail "versions: kubelet $kubelet_v, API server $server_v, pinned $want"; fi
  local holds pkg; holds="$(node apt-mark showhold 2>&1)"
  for pkg in kubelet kubeadm kubectl cri-tools kubernetes-cni; do
    if grep -qx "$pkg" <<<"$holds"; then pass "$pkg is held"; else fail "$pkg is not held"; fi
  done
  if [[ "$(node systemctl is-active kubelet 2>&1)" == "active" ]]; then pass "kubelet is active"; else fail "kubelet is not active"; fi

  # Workloads allowed: no NoSchedule/NoExecute taint at all (control-plane taint removed, node Ready so no not-ready taint)
  local taints t bad=""; taints="$(k get node "$NODE_NAME" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}' 2>&1)"
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    case "$t" in *:NoSchedule|*:NoExecute) bad+="$t " ;; esac
  done <<<"$taints"
  if [[ -z "$bad" ]]; then pass "no NoSchedule/NoExecute taint blocks workloads"; else fail "blocking taints: $bad"; fi

  local ready reason
  ready="$(k get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1)"
  reason="$(k get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>&1)"
  if [[ "$ready" == "True" ]]; then pass "node Ready"; else fail "node Ready=$ready: $reason"; fi

  # Control plane: static pods + kube-proxy Running and Ready, every kube-system pod healthy
  local pods name phase pready
  pods="$(k get pods -n kube-system -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>&1)"
  for name in "etcd-$NODE_NAME" "kube-apiserver-$NODE_NAME" "kube-controller-manager-$NODE_NAME" "kube-scheduler-$NODE_NAME" "kube-proxy-"; do
    if grep -Eq "^${name}[^ ]* Running True\$" <<<"$pods"; then pass "${name%-} Running and Ready"; else fail "${name%-} not Running/Ready"; fi
  done
  bad=""
  while read -r name phase pready; do
    [[ -z "$name" || ( "$phase" == "Running" && "$pready" == "True" ) ]] && continue
    bad+="$name($phase) "
  done <<<"$pods"
  if [[ -z "$bad" ]]; then pass "all kube-system pods healthy"
  else fail "unhealthy kube-system pods: $bad"; fi
}

# ip_in_cidr <ip> <a.b.c.d/len>: IPv4 membership in pure bash
ip_in_cidr() {
  local ip="$1" net="${2%/*}" len="${2#*/}" a b c d n i m
  IFS=. read -r a b c d <<<"$ip"; i=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  IFS=. read -r a b c d <<<"$net"; n=$(( (a << 24) + (b << 16) + (c << 8) + d ))
  m=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
  (( (i & m) == (n & m) ))
}

check_3a() { # CNI installed and healthy (M3): Calico via tigera-operator, node Ready, pods get pod-CIDR IPs
  need_cluster || return 0
  local cidr; cidr="$(sed -n 's/^pod_cidr:[[:space:]]*\([0-9./]*\).*/\1/p' "$ROOT/ansible/group_vars/all/main.yml")"
  [[ -n "$cidr" ]] || { fail "pod_cidr not found in group_vars/all/main.yml"; return 0; }

  local ready; ready="$(k get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>&1)"
  if [[ "$ready" == "True" ]]; then pass "node $NODE_NAME Ready"; else fail "node Ready=$ready"; fi

  local comp avail
  for comp in calico ippools apiserver tiers; do
    avail="$(k get tigerastatus "$comp" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>&1)"
    if [[ "$avail" == "True" ]]; then pass "tigerastatus $comp Available"; else fail "tigerastatus $comp Available='$avail'"; fi
  done

  local ds; ds="$(k get daemonsets calico-node -n calico-system -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}' 2>&1)"
  if [[ "$ds" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "calico-node DaemonSet fully ready (desired ready: $ds)"; else fail "calico-node desired/ready: $ds"; fi
  if [[ -n "$(node find /etc/cni/net.d -maxdepth 1 -name '*calico*' 2>/dev/null)" ]]; then pass "Calico CNI config present in /etc/cni/net.d"; else fail "no Calico CNI config in /etc/cni/net.d"; fi

  local pools; pools="$(k get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.spec.cidr}{"\n"}{end}' 2>&1)"
  if [[ "$pools" == "$cidr" ]]; then pass "the only Calico IPPool is $cidr"; else fail "IPPool CIDRs: $(tr '\n' ' ' <<<"$pools") (want $cidr)"; fi

  # CoreDNS is the always-present pod that needs the CNI: Ready, with an IP from the pod CIDR
  local dns name phase pready ip bad="" n=0
  dns="$(k get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.conditions[?(@.type=="Ready")].status} {.status.podIP}{"\n"}{end}' 2>&1)"
  while read -r name phase pready ip; do
    [[ -z "$name" ]] && continue
    n=$((n + 1))
    [[ "$phase" == "Running" && "$pready" == "True" ]] || bad+="$name(not Ready) "
    ip_in_cidr "$ip" "$cidr" 2>/dev/null || bad+="$name(IP '$ip' outside $cidr) "
  done <<<"$dns"
  if [[ $n -gt 0 && -z "$bad" ]]; then pass "$n CoreDNS pod(s) Ready with IPs inside $cidr"; else fail "CoreDNS: ${bad:-no pods}"; fi

  local ns_label; ns_label="$(k get namespaces calico-system -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>&1)"
  if [[ "$ns_label" == "privileged" ]]; then pass "calico-system PSA enforce=privileged (platform namespace)"; else fail "calico-system PSA enforce='$ns_label'"; fi
  local mode
  for mode in audit warn; do
    ns_label="$(k get namespaces calico-system -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$ns_label" == "privileged" ]]; then pass "calico-system PSA $mode=privileged"; else fail "calico-system PSA $mode='$ns_label'"; fi
  done

  # Every Calico pod and the operator declare CPU+memory requests (not BestEffort)
  local noreq="" ns pods
  for ns in calico-system tigera-operator; do
    pods="$(k get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}' 2>&1)"
    [[ -n "$pods" ]] || noreq+="$ns(no pods) "
    noreq+="$(awk 'NF && $2 == "BestEffort" {printf "%s ", $1}' <<<"$pods")"
  done
  if [[ -z "$noreq" ]]; then pass "Calico and tigera-operator pods have resource requests"; else fail "BestEffort/missing pods: $noreq"; fi

  # Privileged host-root images run by pinned digest only: spec image and running imageID both match versions.yml
  local vy="$ROOT/ansible/group_vars/all/versions.yml" digests unpinned="" cname img id d n=0
  digests="$(grep -E '^(calico_operator_digest:|  calico/[a-z0-9-]+:)' "$vy" | grep -o 'sha256:[0-9a-f]\{64\}')"
  if [[ -z "$digests" ]]; then fail "no Calico image digests in versions.yml"; else
    local pod
    for ns in calico-system tigera-operator; do
      for pod in $(k get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        while read -r cname img id; do
          [[ -z "$cname" ]] && continue
          n=$((n + 1))
          d="${img##*@}"
          if [[ "$img" != *@sha256:* ]] || ! grep -qx "$d" <<<"$digests" || [[ "${id##*@}" != "$d" ]]; then unpinned+="$pod/$cname "; fi
        done < <(k get pods "$pod" -n "$ns" -o jsonpath='{range .spec.containers[*]}S {.name} {.image}{"\n"}{end}{range .spec.initContainers[*]}S {.name} {.image}{"\n"}{end}{range .status.containerStatuses[*]}I {.name} {.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}I {.name} {.imageID}{"\n"}{end}' 2>&1 \
          | awk '$1 == "S" {img[$2] = $3; order[++m] = $2} $1 == "I" {id[$2] = $3} END {for (i = 1; i <= m; i++) print order[i], img[order[i]], id[order[i]]}')
      done
    done
    if [[ $n -gt 0 && -z "$unpinned" ]]; then pass "all $n Calico/operator containers run by pinned digest (spec image and imageID)"
    else fail "not digest-pinned (n=$n): ${unpinned:-no containers}"; fi
  fi
  local is; is="$(k get imagesets "calico-$(sed -n 's/^calico_chart_version:[[:space:]]*"\([^"]*\)".*/\1/p' "$vy")" -o name 2>&1)"
  if [[ "$is" == imageset* ]]; then pass "ImageSet $is exists"; else fail "ImageSet missing: $is"; fi
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

# Audit policy checker, run on the node (python3-yaml is installed there). Prints "ok" or the problem.
read -r -d '' AUDIT_POLICY_PY <<'PY'
import sys, yaml
p = yaml.safe_load(open(sys.argv[1]))
rules = p.get("rules") or []
levels = {"Metadata", "Request", "RequestResponse"}
if any(r.get("level") not in levels for r in rules):
    sys.exit(print("a rule has level None or an unknown level"))
if "ResponseComplete" in (p.get("omitStages") or []):
    sys.exit(print("policy omits ResponseComplete"))
filters = {"users", "userGroups", "verbs", "resources", "namespaces", "nonResourceURLs"}
if not any(not (filters & set(r)) for r in rules):
    sys.exit(print("no catch-all rule: unmatched requests are not logged"))
def may_match_secrets(r):
    if "nonResourceURLs" in r: return False
    if "resources" not in r: return True
    return any(g.get("group", "") == "" and (not g.get("resources") or "secrets" in g["resources"]) for g in r["resources"])
for r in rules:
    if not may_match_secrets(r): continue
    if r["level"] != "Metadata": sys.exit(print("a %s rule can log Secret bodies" % r["level"]))
    if not ({"users", "userGroups", "verbs", "namespaces"} & set(r)): break
print("ok")
PY

check_8c() { # every API request recorded: audit policy + log (M2)
  need_cluster || return 0
  local policy=/etc/kubernetes/audit/policy.yaml log=/var/log/kubernetes/audit/audit.log
  local manifest=/etc/kubernetes/manifests/kube-apiserver.yaml

  # First-match rule order: every request must hit a non-None rule; no rule may log Secret bodies.
  local res
  res="$(node python3 - "$policy" <<<"$AUDIT_POLICY_PY" 2>&1)"
  if [[ "$res" == "ok" ]]; then pass "audit policy: no None rules, catch-all rule, Secrets at Metadata"; else fail "audit policy: $res"; fi

  local flags f; flags="$(node grep -E -- '--audit-' "$manifest" 2>&1)"
  for f in "audit-policy-file=$policy" "audit-log-path=$log" "audit-log-maxage=[1-9]" "audit-log-maxbackup=[1-9]" "audit-log-maxsize=[1-9]"; do
    if grep -Eq -- "--$f" <<<"$flags"; then pass "apiserver manifest sets --${f%%=*}"; else fail "apiserver manifest lacks --$f"; fi
  done
  local cmd; cmd="$(k get pod -n kube-system "kube-apiserver-$NODE_NAME" -o jsonpath='{.spec.containers[0].command}' 2>&1)"
  if [[ "$cmd" == *"--audit-policy-file=$policy"* && "$cmd" == *"--audit-log-path=$log"* ]]; then pass "running API server uses the audit policy and log"
  else fail "running API server lacks the audit flags"; fi

  # A request with a unique name must show up in the log (a 404 is still an API request).
  local marker="verify-audit-$$-$RANDOM" i n=0
  k get configmap "$marker" -n default >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n="$(node grep -c -- "$marker" "$log" 2>/dev/null)"; [[ "${n:-0}" -gt 0 ]] && break; sleep 1
  done
  if [[ "${n:-0}" -gt 0 ]]; then pass "a host request was recorded in $log"; else fail "request $marker not found in $log"; fi
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
