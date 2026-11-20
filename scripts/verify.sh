#!/usr/bin/env bash
# SC2329: check_<id> and helpers are called indirectly by ID. SC2181: `out=$(cmd); if [[ $? -ne 0 ]]` keeps the output for the message.
# shellcheck disable=SC2329,SC2181
# Requirement checks for the INDEV single-node Kubernetes assignment.
#   scripts/verify.sh            # all requirements
#   scripts/verify.sh 4 8c       # requirement 4 and sub-requirement 8c (3 = 3a 3b, 8 = 8a 8b 8c)
#   scripts/verify.sh --strict   # SKIP counts as failure (make e2e, closing a milestone)
# Prints a PASS/FAIL/SKIP line per check and a summary; exits 1 if anything FAILed
# (or, with --strict / VERIFY_STRICT=1, if anything was SKIPped: a check that didn't run proves nothing).
# Each check_N is implemented in the milestone that delivers requirement N (see TODO.md).
# Checks must be read-only, or create test objects only in "verify-tmp" (check_5) or their role-owned namespace (check_4: ingress-check) and clean them up.
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
    if node grep -rqE "^${key}[[:space:]]*=[[:space:]]*1\$" /etc/sysctl.d/; then pass "sysctl $key persisted"; else fail "sysctl $key not persisted in /etc/sysctl.d"; fi
  done

  local holds pkg; holds="$(node apt-mark showhold 2>&1)"
  for pkg in containerd runc; do
    if grep -qx "$pkg" <<<"$holds"; then pass "$pkg is held (apt-mark showhold)"; else fail "$pkg is not held"; fi
  done
}

# Pinned value from versions.yml (single source of truth), e.g. pinned kubernetes_version -> 1.35.10-1.1
pinned() { sed -n "s/^$1: \"\\([^\"]*\\)\".*/\\1/p" "$ROOT/ansible/group_vars/all/versions.yml"; }
NODE_NAME="${NODE_NAME:-k8s-node}"
# Role default: pinned_role <role> <key>
pinned_role() { sed -n "s/^$2:[[:space:]]*\\([a-z0-9-]*\\).*/\\1/p" "$ROOT/ansible/roles/$1/defaults/main.yml"; }

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


# llm_app values from the role defaults / group_vars (single source of truth): sets the LLM_* globals used by checks 3b, 8b and 9.
llm_vars() {
  local d="$ROOT/ansible/roles/llm_app/defaults/main.yml" main="$ROOT/ansible/group_vars/all/main.yml" vy="$ROOT/ansible/group_vars/all/versions.yml"
  dv() { sed -n "s/^llm_app_$1:[[:space:]]*\\([^ #]*\\).*/\\1/p" "$d"; }
  LLM_NS="$(sed -n 's/^ns_llm:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  LLM_NAME="$(dv name)"; LLM_PORT="$(dv port)"; LLM_UID="$(dv uid)"; LLM_MODEL_DIR="$(dv model_dir)"
  LLM_MODEL_PVC="$(dv model_pvc)"; LLM_TLS_SECRET="$(dv tls_secret)"; LLM_MODEL_ALIAS="$(dv model_alias)"
  LLM_FETCH="$(dv fetch_name)"
  LLM_ISSUER="$(sed -n 's/^pki_cluster_issuer:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  LLM_DURATION="$(sed -n 's/^pki_cert_duration:[[:space:]]*\([0-9a-z]*\).*/\1/p' "$main")"
  LLM_RENEW="$(sed -n 's/^pki_cert_renew_before:[[:space:]]*\([0-9a-z]*\).*/\1/p' "$main")"
  LLM_IMAGE="$(pinned llama_cpp_image):$(pinned llama_cpp_tag)@$(pinned llama_cpp_digest)"
  LLM_DIGEST="$(pinned llama_cpp_digest)"
  LLM_MODEL_FILE="$(pinned llm_model_file)"
  LLM_MODEL_SHA="$(pinned llm_model_sha256)"
  LLM_MODEL_SIZE="$(sed -n 's/^llm_model_size_bytes:[[:space:]]*\([0-9]*\).*/\1/p' "$vy")"
  LLM_PSA_VERSION="$(pinned pod_security_version)"
  [[ -n "$LLM_NS" && -n "$LLM_NAME" && -n "$LLM_PORT" && -n "$LLM_UID" && -n "$LLM_MODEL_DIR" && -n "$LLM_MODEL_PVC" && -n "$LLM_TLS_SECRET" \
    && -n "$LLM_MODEL_ALIAS" && -n "$LLM_ISSUER" && -n "$LLM_DURATION" && -n "$LLM_RENEW" && -n "$LLM_DIGEST" && -n "$LLM_MODEL_FILE" \
    && -n "$LLM_MODEL_SHA" && -n "$LLM_MODEL_SIZE" && -n "$LLM_PSA_VERSION" && -n "$LLM_FETCH" ]]
}
# llm_pod: name of the current (non-terminating) llama.cpp pod
llm_pod() { k get pods -n "$LLM_NS" -l "app.kubernetes.io/name=$LLM_NAME" -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.name][0] // empty'; }
# llm_https <curl args...>: HTTPS to the ingress through Lima :443, trusting only certs/ca.crt (no /etc/hosts entry needed)
llm_https() { curl -sS --max-time 60 --resolve "$LLM_HOST:443:127.0.0.1" --cacert "$CA_CERT" "$@"; }

CHECK3B_CREATED=0
cleanup_3b() {
  k delete pod -n "$LLM_NS" -l verify=check-3b --ignore-not-found --wait=false >/dev/null 2>&1
  k delete pod -n "$VERIFY_NS" -l verify=check-3b --ignore-not-found --wait=false >/dev/null 2>&1
  if [[ "$CHECK3B_CREATED" == 1 ]]; then k delete namespace "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1; fi
  CHECK3B_CREATED=0
}

check_3b() { # app pods accept only the traffic they need: NetworkPolicies in app namespaces (M9)
  need_cluster || return 0
  if ! llm_vars; then fail "llm_app defaults / versions not found"; return 0; fi
  local ns="$LLM_NS" out i

  # --- the policy set: default-deny both ways, DNS, ingress from the node IP only, HTTPS-only egress for the downloader
  local names; names="$(k get networkpolicies -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1 | sort | tr '\n' ' ')"
  if [[ "$names" == "allow-dns allow-model-download allow-traefik-ingress default-deny " ]]; then pass "$ns has exactly default-deny, allow-dns, allow-traefik-ingress, allow-model-download"; else fail "$ns NetworkPolicies: $names"; fi
  out="$(k get networkpolicies default-deny -n "$ns" -o jsonpath='{.spec.podSelector} {.spec.policyTypes} {.spec.ingress} {.spec.egress}' 2>&1)"
  if [[ "$out" == '{} ["Ingress","Egress"]  ' ]]; then pass "default-deny selects every pod and denies Ingress + Egress (no rules)"; else fail "default-deny: $out"; fi
  local node_ip; node_ip="$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>&1)"
  out="$(k get networkpolicies allow-traefik-ingress -n "$ns" -o jsonpath='{.spec.policyTypes} {.spec.ingress[*].from[*].ipBlock.cidr} {.spec.ingress[*].from[*].podSelector} {.spec.ingress[*].ports[*].port} {.spec.ingress[*].ports[*].protocol}' 2>&1)"
  if [[ "$out" == "[\"Ingress\"] $node_ip/32  $LLM_PORT TCP" ]]; then pass "allow-traefik-ingress: only node IP $node_ip/32 (hostNetwork Traefik, ADR 0003) on TCP $LLM_PORT"; else fail "allow-traefik-ingress: $out"; fi
  out="$(k get networkpolicies allow-model-download -n "$ns" -o jsonpath='{.spec.podSelector.matchLabels} {.spec.policyTypes} {.spec.egress[*].to[*].ipBlock.cidr} {.spec.egress[*].ports[*].port} {.spec.egress[*].ports[*].protocol} {.spec.egress[*].to[*].ipBlock.except}' 2>&1)"
  if [[ "$out" == "{\"app.kubernetes.io/component\":\"$LLM_FETCH\"} [\"Egress\"] 0.0.0.0/0 443 TCP "*10.0.0.0/8*100.64.0.0/10*172.16.0.0/12*192.168.0.0/16*169.254.0.0/16* ]]; then pass "allow-model-download: only $LLM_FETCH Job pods, TCP 443 to public addresses (private, CGNAT, link-local excluded); the server pod is not selected"; else fail "allow-model-download: $out"; fi
  out="$(k get networkpolicies allow-dns -n "$ns" -o jsonpath='{.spec.podSelector.matchLabels} {.spec.egress[*].to[*].namespaceSelector.matchLabels} {.spec.egress[*].to[*].podSelector.matchLabels} {.spec.egress[*].ports[*].port}' 2>&1)"
  if [[ "$out" == "{\"app.kubernetes.io/component\":\"$LLM_FETCH\"} "'{"kubernetes.io/metadata.name":"kube-system"} {"k8s-app":"kube-dns"} 53 53' ]]; then pass "allow-dns: only $LLM_FETCH Job pods, CoreDNS in kube-system on port 53 only (server pod gets no egress)"; else fail "allow-dns: $out"; fi

  # --- enforcement, from probe pods (pinned busybox, PSA restricted): one in another namespace, one in llm without the app label
  local llm_ip dns_ip busy ext=1.1.1.1
  llm_ip="$(k get pod "$(llm_pod)" -n "$ns" -o jsonpath='{.status.podIP}' 2>&1)"
  if [[ ! "$llm_ip" =~ ^[0-9.]+$ ]]; then fail "llama.cpp pod IP not found: $llm_ip"; return 0; fi
  dns_ip="$(k get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}' 2>&1)"
  busy="docker.io/library/busybox:$(pinned local_path_helper_version)@$(pinned local_path_helper_digest)"
  wait_verify_ns_gone
  CHECK3B_CREATED=0
  if ! k get namespaces "$VERIFY_NS" >/dev/null 2>&1; then CHECK3B_CREATED=1; fi
  trap cleanup_3b EXIT
  out="$(k apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Namespace
metadata: {name: $VERIFY_NS}
---
apiVersion: v1
kind: Pod
metadata: {name: verify-3b-out, namespace: $VERIFY_NS, labels: {verify: check-3b}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: $busy
      command:
        - sh
        - -c
        - "nc -w 3 $dns_ip 9153 </dev/null && echo CTRL_DNS_OPEN; nc -w 3 $ext 80 </dev/null && echo CTRL_EXT_OPEN; nc -w 3 $llm_ip $LLM_PORT </dev/null && echo POD_OPEN || echo POD_BLOCKED; nc -w 3 $LLM_NAME.$ns.svc $LLM_PORT </dev/null && echo SVC_OPEN || echo SVC_BLOCKED"
      resources: {requests: {cpu: 10m, memory: 8Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Pod
metadata: {name: verify-3b-in, namespace: $ns, labels: {verify: check-3b}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: $busy
      command:
        - sh
        - -c
        - "nc -w 3 $llm_ip $LLM_PORT </dev/null && echo SAMENS_OPEN || echo SAMENS_BLOCKED; nc -w 3 $dns_ip 9153 </dev/null && echo DNSMETRICS_OPEN || echo DNSMETRICS_BLOCKED; nc -w 3 $ext 80 </dev/null && echo EXT_OPEN || echo EXT_BLOCKED; nslookup -timeout=3 kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_OK || echo DNS_FAIL"
      resources: {requests: {cpu: 10m, memory: 8Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Pod
metadata: {name: verify-3b-fetch, namespace: $ns, labels: {verify: check-3b, app.kubernetes.io/component: $LLM_FETCH}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: $busy
      command:
        - sh
        - -c
        - "nc -w 3 $ext 443 </dev/null && echo FETCH_HTTPS_OPEN || echo FETCH_HTTPS_BLOCKED; nslookup -timeout=3 huggingface.co >/dev/null 2>&1 && echo FETCH_DNS_OK || echo FETCH_DNS_FAIL; nc -w 3 $ext 80 </dev/null && echo FETCH_80_OPEN || echo FETCH_80_BLOCKED; nc -w 3 $node_ip 6443 </dev/null && echo FETCH_NODE_OPEN || echo FETCH_NODE_BLOCKED; nc -w 3 $dns_ip 9153 </dev/null && echo FETCH_POD_OPEN || echo FETCH_POD_BLOCKED; nc -w 3 $llm_ip $LLM_PORT </dev/null && echo FETCH_LLM_OPEN || echo FETCH_LLM_BLOCKED"
      resources: {requests: {cpu: 10m, memory: 8Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
MANIFEST
)"
  if [[ $? -ne 0 ]]; then fail "could not create the NetworkPolicy probe pods: ${out:0:300}"; cleanup_3b; trap - EXIT; return 0; fi
  local phase_out phase_in phase_fetch
  for i in $(seq 1 60); do
    phase_out="$(k get pod verify-3b-out -n "$VERIFY_NS" -o jsonpath='{.status.phase}' 2>&1)"
    phase_in="$(k get pod verify-3b-in -n "$ns" -o jsonpath='{.status.phase}' 2>&1)"
    phase_fetch="$(k get pod verify-3b-fetch -n "$ns" -o jsonpath='{.status.phase}' 2>&1)"
    [[ "$phase_out" =~ ^(Succeeded|Failed)$ && "$phase_in" =~ ^(Succeeded|Failed)$ && "$phase_fetch" =~ ^(Succeeded|Failed)$ ]] && break; sleep 2
  done
  local lo li lf
  lf="$(k logs verify-3b-fetch -n "$ns" 2>&1 | tr '\n' ' ')"
  lo="$(k logs verify-3b-out -n "$VERIFY_NS" 2>&1 | tr '\n' ' ')"
  li="$(k logs verify-3b-in -n "$ns" 2>&1 | tr '\n' ' ')"
  if [[ "$lo" == *CTRL_DNS_OPEN* && "$lo" == *CTRL_EXT_OPEN* ]]; then pass "probe control: a pod outside $ns reaches CoreDNS:9153 and $ext:80 (the probes can connect)"; else fail "probe control ($phase_out): ${lo:0:200}"; fi
  if [[ "$lo" == *POD_BLOCKED* && "$lo" != *POD_OPEN* ]]; then pass "ingress denied: a pod in $VERIFY_NS cannot reach llama.cpp $llm_ip:$LLM_PORT"; else fail "pod-IP probe from another namespace ($phase_out): ${lo:0:200}"; fi
  if [[ "$lo" == *SVC_BLOCKED* && "$lo" != *SVC_OPEN* ]]; then pass "ingress denied: a pod in $VERIFY_NS cannot reach the Service $LLM_NAME.$ns:$LLM_PORT"; else fail "Service probe from another namespace ($phase_out): ${lo:0:200}"; fi
  if [[ "$li" == *SAMENS_BLOCKED* && "$li" != *SAMENS_OPEN* ]]; then pass "default-deny: an unlabelled pod in $ns cannot reach llama.cpp either"; else fail "same-namespace probe ($phase_in): ${li:0:200}"; fi
  if [[ "$li" == *DNSMETRICS_BLOCKED* && "$li" == *EXT_BLOCKED* && "$li" == *DNS_FAIL* && "$li" != *_OPEN* && "$li" != *DNS_OK* ]]; then pass "egress denied: an unlabelled pod in $ns has no egress at all (not CoreDNS:53/9153, not $ext:80)"; else fail "egress probe from $ns ($phase_in): ${li:0:200}"; fi
  if [[ "$lf" == *FETCH_HTTPS_OPEN* && "$lf" == *FETCH_DNS_OK* ]]; then pass "positive control: a pod with the $LLM_FETCH Job label reaches $ext:443 and resolves names (probe method works)"; else fail "Job-labelled probe ($phase_fetch): ${lf:0:250}"; fi
  if [[ "$lf" == *FETCH_80_BLOCKED* && "$lf" == *FETCH_NODE_BLOCKED* && "$lf" == *FETCH_POD_BLOCKED* && "$lf" == *FETCH_LLM_BLOCKED* ]]; then pass "the Job's egress is HTTPS only: $ext:80, node IP:6443, a pod IP and llama.cpp are blocked from the Job label too"; else fail "Job-labelled probe beyond 443 ($phase_fetch): ${lf:0:250}"; fi
  cleanup_3b; trap - EXIT

  # --- from the llama.cpp pod itself (image ships curl): no egress at all, not even HTTPS or DNS (B-044)
  local pod rc; pod="$(llm_pod)"
  for dest in "http://$ext:80" "https://$ext:443" "https://huggingface.co/" "https://$node_ip:6443" "http://$dns_ip:9153"; do
    k exec -n "$ns" "$pod" -c llama-server -- curl -sS -m 5 -o /dev/null "$dest" >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 28 ]]; then pass "llama.cpp pod egress to $dest times out (blocked)"; else fail "llama.cpp pod egress to $dest: curl rc=$rc (want 28, timeout)"; fi
  done

  # --- the allowed path: Mac -> Lima :443 -> Traefik (node IP) -> llama.cpp
  out="$(llm_https -o /dev/null -w '%{http_code}' "https://$LLM_HOST/health" 2>&1)"
  if [[ "$out" == 200 ]]; then pass "allowed path: https://$LLM_HOST/health via Traefik returns 200"; else fail "https://$LLM_HOST/health via Traefik: $out"; fi
}

# images_unpinned <namespace> <digests, one per line>: prints "<containers checked> <bad pod/container ...>".
# A container is bad unless its spec image is @sha256:<digest> from the list and the running imageID has the same digest.
images_unpinned() {
  local ns="$1" digests="$2" pod cname img id d n=0 bad=""
  for pod in $(k get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    while read -r cname img id; do
      [[ -z "$cname" ]] && continue
      n=$((n + 1))
      d="${img##*@}"
      if [[ "$img" != *@sha256:* ]] || ! grep -qx "$d" <<<"$digests" || [[ "${id##*@}" != "$d" ]]; then bad+="$pod/$cname "; fi
    done < <(k get pods "$pod" -n "$ns" -o jsonpath='{range .spec.containers[*]}S {.name} {.image}{"\n"}{end}{range .spec.initContainers[*]}S {.name} {.image}{"\n"}{end}{range .status.containerStatuses[*]}I {.name} {.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}I {.name} {.imageID}{"\n"}{end}' 2>&1 \
      | awk '$1 == "S" {img[$2] = $3; order[++m] = $2} $1 == "I" {id[$2] = $3} END {for (i = 1; i <= m; i++) print order[i], img[order[i]], id[order[i]]}')
  done
  echo "$n $bad"
}

# Leaf serial served on the Mac's :443 (through Lima) for an SNI name
served_serial() { openssl s_client -servername "$1" -connect 127.0.0.1:443 </dev/null 2>/dev/null | openssl x509 -noout -serial 2>/dev/null; }

# check_4's namespace belongs to ingress_traefik and is watched by Traefik (B-038): delete only our objects, never the namespace.
CHECK4_NS=""
cleanup_4() {
  [[ -n "$CHECK4_NS" ]] || return 0
  k delete ingress,service,pod,certificate -n "$CHECK4_NS" -l verify=check-4 --ignore-not-found --wait=false >/dev/null 2>&1
  k delete secret verify-tls -n "$CHECK4_NS" --ignore-not-found --wait=false >/dev/null 2>&1
}

check_4() { # Ingress (Traefik) + TLS from the internal CA (cert-manager) + automatic renewal (M5)
  need_cluster || return 0
  local vy="$ROOT/ansible/group_vars/all/versions.yml" main="$ROOT/ansible/group_vars/all/main.yml"
  local pki_role="$ROOT/ansible/roles/pki/defaults/main.yml" tr_role="$ROOT/ansible/roles/ingress_traefik/defaults/main.yml"
  local cm_ns tr_ns issuer ca_secret https_port http_port check_ns bport node_ns_llm node_ns_mon
  cm_ns="$(sed -n 's/^ns_cert_manager:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  tr_ns="$(sed -n 's/^ns_ingress:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  issuer="$(sed -n 's/^pki_cluster_issuer:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  ca_secret="$(sed -n 's/^pki_ca_secret:[[:space:]]*\([a-z-]*\).*/\1/p' "$pki_role")"
  https_port="$(sed -n 's/^  websecure:[[:space:]]*\([0-9]*\).*/\1/p' "$tr_role")"
  http_port="$(sed -n 's/^  web:[[:space:]]*\([0-9]*\).*/\1/p' "$tr_role")"
  check_ns="$(sed -n 's/^ingress_traefik_check_namespace:[[:space:]]*\([a-z-]*\).*/\1/p' "$tr_role")"
  bport="$(sed -n 's/^ingress_traefik_check_backend_port:[[:space:]]*\([0-9]*\).*/\1/p' "$tr_role")"
  node_ns_llm="$(sed -n 's/^ns_llm:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  node_ns_mon="$(sed -n 's/^ns_monitoring:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  if [[ -z "$cm_ns" || -z "$tr_ns" || -z "$issuer" || -z "$ca_secret" || -z "$https_port" || -z "$http_port" || -z "$check_ns" || -z "$bport" || -z "$node_ns_llm" || -z "$node_ns_mon" ]]; then
    fail "pki/ingress_traefik defaults or namespaces not found in group_vars/roles"; return 0
  fi

  # --- Root CA on the host: a long-lived CA certificate; the key exists and is private (its contents are never read)
  local ca_text; ca_text="$(openssl x509 -in "$CA_CERT" -noout -text 2>&1)"
  if grep -A1 'Basic Constraints: critical' <<<"$ca_text" | grep -q 'CA:TRUE, pathlen:0'; then pass "certs/ca.crt is a CA (critical CA:TRUE, pathlen:0)"
  else fail "certs/ca.crt missing or not a pathlen:0 CA"; fi
  if grep -A1 'Key Usage: critical' <<<"$ca_text" | grep -q 'Certificate Sign'; then pass "certs/ca.crt key usage includes keyCertSign (critical)"
  else fail "certs/ca.crt key usage lacks keyCertSign"; fi
  # B-035: critical name constraints keep a leaked CA key from minting certificates for public domains or IPs
  if grep -A5 'Name Constraints: critical' <<<"$ca_text" | tr -d '\n' | grep -Eq 'Permitted:[[:space:]]*DNS:local[[:space:]]*Excluded:[[:space:]]*IP:0\.0\.0\.0/0\.0\.0\.0[[:space:]]*IP:(0:){7}0/(0:){7}0'; then
    pass "certs/ca.crt has critical name constraints (permitted DNS:local; excluded all IPv4/IPv6)"
  else fail "certs/ca.crt lacks critical name constraints permitting only DNS:local and excluding all IPs"; fi
  if openssl x509 -in "$CA_CERT" -noout -checkend 31536000 >/dev/null 2>&1; then pass "certs/ca.crt valid for more than 1 year"; else fail "certs/ca.crt expires within 1 year or is unreadable"; fi
  local key="$ROOT/.secrets/ca.key" fmode
  fmode="$(stat -f '%Lp' "$key" 2>/dev/null || stat -c '%a' "$key" 2>/dev/null)"
  if [[ -f "$key" && "$fmode" == "600" ]]; then pass ".secrets/ca.key exists with mode 600"; else fail ".secrets/ca.key missing or mode '$fmode' (want 600)"; fi
  # B-037: the key must belong to the committed certificate; only public-key hashes are compared and shown
  local key_pub cert_pub
  key_pub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  cert_pub="$(openssl x509 -in "$CA_CERT" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null | awk '{print $NF}')"
  if [[ -n "$key_pub" && "$key_pub" == "$cert_pub" ]]; then pass ".secrets/ca.key matches certs/ca.crt (public key sha256 ${key_pub:0:12}...)"
  else fail ".secrets/ca.key does not match certs/ca.crt (public key sha256 '${key_pub:0:12}' vs '${cert_pub:0:12}')"; fi

  # --- cert-manager: rollout, restricted namespace, digest-pinned images, requests, CA Secret, ClusterIssuer
  local dep ready
  for dep in cert-manager cert-manager-webhook cert-manager-cainjector; do
    ready="$(k get deployments "$dep" -n "$cm_ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>&1)"
    if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "Deployment $dep ready ($ready)"; else fail "Deployment $dep replicas/ready: $ready"; fi
  done
  local mode label
  for mode in enforce audit warn; do
    label="$(k get namespaces "$cm_ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "restricted" ]]; then pass "$cm_ns PSA $mode=restricted"; else fail "$cm_ns PSA $mode='$label'"; fi
  done
  local chart want_chart
  want_chart="cert-manager-$(pinned cert_manager_chart_version)"
  chart="$(k get deployments cert-manager -n "$cm_ns" -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>&1)"
  if [[ "$chart" == "$want_chart" ]]; then pass "cert-manager chart is the pinned $want_chart"; else fail "cert-manager chart '$chart' (want $want_chart)"; fi
  local digests res n bad
  digests="$(awk '/^cert_manager_image_digests:/ {f = 1; next} f && /^[^ ]/ {f = 0} f' "$vy" | grep -o 'sha256:[0-9a-f]\{64\}')"
  if [[ -z "$digests" ]]; then fail "no cert-manager image digests in versions.yml"; else
    res="$(images_unpinned "$cm_ns" "$digests")"; n="${res%% *}"; bad="${res#* }"
    if [[ "$n" -gt 0 && -z "${bad// /}" ]]; then pass "all $n cert-manager containers run by pinned digest (spec image and imageID)"
    else fail "cert-manager not digest-pinned (n=$n): ${bad:-no containers}"; fi
  fi
  bad="$(k get pods -n "$cm_ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}' 2>&1 | awk 'NF && $2 == "BestEffort" {printf "%s ", $1}')"
  if [[ -z "$bad" ]]; then pass "cert-manager pods have resource requests"; else fail "BestEffort cert-manager pods: $bad"; fi
  local secret_desc; secret_desc="$(k describe secret "$ca_secret" -n "$cm_ns" 2>&1)"
  if grep -Eq '^Type:[[:space:]]+kubernetes.io/tls' <<<"$secret_desc" && grep -q '^tls.key:' <<<"$secret_desc" && grep -q '^tls.crt:' <<<"$secret_desc"; then
    pass "CA Secret $ca_secret (kubernetes.io/tls, tls.crt + tls.key) exists in $cm_ns"
  else fail "CA Secret $ca_secret missing or wrong type in $cm_ns"; fi
  local ci; ci="$(k get clusterissuers "$issuer" -o jsonpath='{.spec.ca.secretName} {.status.conditions[?(@.type=="Ready")].status}' 2>&1)"
  if [[ "$ci" == "$ca_secret True" ]]; then pass "ClusterIssuer $issuer (type ca, $ca_secret) is Ready"; else fail "ClusterIssuer $issuer: $ci"; fi

  # --- Traefik: ready, host network, non-root, no added capabilities, digest-pinned, no NodePort/LoadBalancer, default IngressClass
  ready="$(k get deployments traefik -n "$tr_ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>&1)"
  if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "Deployment traefik ready ($ready)"; else fail "Deployment traefik replicas/ready: $ready"; fi
  local want_tr_chart; want_tr_chart="traefik-$(pinned traefik_chart_version)"
  chart="$(k get deployments traefik -n "$tr_ns" -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>&1)"
  if [[ "$chart" == "$want_tr_chart" ]]; then pass "Traefik chart is the pinned $want_tr_chart"; else fail "Traefik chart '$chart' (want $want_tr_chart)"; fi
  local pod_ready; pod_ready="$(k get pods -n "$tr_ns" -l app.kubernetes.io/name=traefik -o jsonpath='{range .items[*]}{.status.phase} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>&1)"
  if [[ "$pod_ready" == "Running True" ]]; then pass "exactly one Traefik pod, Running and Ready"; else fail "Traefik pods: $(tr '\n' ',' <<<"$pod_ready")"; fi
  local sc
  sc="$(k get pods -n "$tr_ns" -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].spec.hostNetwork}|{.items[0].spec.securityContext.runAsNonRoot}|{.items[0].spec.securityContext.runAsUser}|{.items[0].spec.securityContext.seccompProfile.type}|{.items[0].spec.containers[0].securityContext.allowPrivilegeEscalation}|{.items[0].spec.containers[0].securityContext.readOnlyRootFilesystem}|{.items[0].spec.containers[0].securityContext.privileged}|{.items[0].spec.containers[0].securityContext.capabilities.add}|{.items[0].spec.containers[0].securityContext.capabilities.drop}' 2>&1)"
  if [[ "$sc" == 'true|true|65532|RuntimeDefault|false|true|||["ALL"]' ]]; then
    pass "Traefik: hostNetwork, runAsNonRoot UID 65532, no privilege escalation, read-only rootfs, seccomp RuntimeDefault, drop ALL, no added capabilities"
  else fail "Traefik security context: $sc"; fi
  bad="$(k get pods -n "$tr_ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}' 2>&1 | awk 'NF && $2 == "BestEffort" {printf "%s ", $1}')"
  if [[ -z "$bad" ]]; then pass "Traefik pod has resource requests"; else fail "BestEffort Traefik pods: $bad"; fi
  res="$(images_unpinned "$tr_ns" "$(pinned traefik_image_digest)")"; n="${res%% *}"; bad="${res#* }"
  if [[ "$n" -gt 0 && -z "${bad// /}" ]]; then pass "Traefik runs by the pinned digest (spec image and imageID)"; else fail "Traefik not digest-pinned (n=$n): ${bad:-no containers}"; fi
  for mode in enforce audit warn; do
    label="$(k get namespaces "$tr_ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "privileged" ]]; then pass "$tr_ns PSA $mode=privileged (platform namespace: hostNetwork)"; else fail "$tr_ns PSA $mode='$label'"; fi
  done
  local classes; classes="$(k get ingressclasses -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>&1 | awk '$2 == "true" {print $1}')"
  if [[ "$classes" == "traefik" ]]; then pass "traefik is the only default IngressClass"; else fail "default IngressClasses: '$(tr '\n' ' ' <<<"$classes")'"; fi
  local exposed; exposed="$(k get services -n "$tr_ns" -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.type}{"\n"}{end}' 2>&1 | grep -E ':(NodePort|LoadBalancer)$' | tr '\n' ' ')"
  if [[ -z "$exposed" ]]; then pass "no NodePort/LoadBalancer Service in $tr_ns"; else fail "exposed Services in $tr_ns: $exposed"; fi
  # B-036: Traefik's Secret access is namespaced; the CA key (cert-manager) and kube-system must be out of reach
  local sa="system:serviceaccount:$tr_ns:traefik" can_ns
  for can_ns in "$cm_ns" kube-system; do
    if [[ "$(k auth can-i get secrets -n "$can_ns" --as="$sa" 2>&1)" == "no" ]]; then pass "Traefik ServiceAccount cannot get Secrets in $can_ns"
    else fail "Traefik ServiceAccount can read Secrets in $can_ns (ClusterRole instead of namespaced Roles?)"; fi
  done
  # B-038: the Ingress provider only syncs if it can list in every watched namespace; a missing Role blanks all routes
  local watched want_watched ns
  watched="$(k get deployments traefik -n "$tr_ns" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>&1 | grep -o 'providers.kubernetesingress.namespaces=[^"]*' | cut -d= -f2 | tr ',' '\n' | sort | tr '\n' ' ')"
  want_watched="$(printf '%s\n' "$node_ns_llm" "$node_ns_mon" "$check_ns" | sort | tr '\n' ' ')"
  if [[ "$watched" == "$want_watched" ]]; then pass "Traefik watches only the role-owned namespaces: $watched"; else fail "Traefik watches '$watched' (want '$want_watched'; no scratch namespaces)"; fi
  local role_n rb_n
  for ns in $watched; do
    role_n="$(k get roles -n "$ns" --field-selector metadata.name=traefik-ingress -o name 2>&1 | grep -c '^role')"
    rb_n="$(k get rolebindings -n "$ns" --field-selector metadata.name=traefik-ingress -o name 2>&1 | grep -c '^rolebinding')"
    if [[ "$role_n" == 1 && "$rb_n" == 1 ]]; then pass "Traefik Role and RoleBinding exist in watched namespace $ns"
    else fail "watched namespace $ns lacks the Traefik Role/RoleBinding (role=$role_n binding=$rb_n); re-run make provision TAGS=ingress_traefik"; fi
  done
  local forbidden; forbidden="$(k logs -n "$tr_ns" deployment/traefik --tail=1000 2>&1 | grep -ci 'forbidden')"
  if [[ "$forbidden" == 0 ]]; then pass "no 'forbidden' errors in the Traefik log (Ingress provider can list its namespaces)"; else fail "$forbidden 'forbidden' lines in the Traefik log (RBAC gap, provider not synced?)"; fi
  local p listen; listen="$(node ss -H -ltn 2>&1)"
  for p in "$https_port" "$http_port"; do
    if grep -Eq "[:*]${p}[[:space:]]" <<<"$listen"; then pass "node listens on :$p (Lima forwards it)"; else fail "nothing listens on :$p on the node"; fi
  done

  # --- End to end through the Mac's :443/:80: non-root backend, Ingress without ingressClassName, cert from the internal CA
  local img; img="docker.io/library/busybox:$(pinned local_path_helper_version)@$(pinned local_path_helper_digest)"
  local host=verify.local body="verify-ingress-ok"
  # The namespace is created by ingress_traefik (PSA restricted, default-deny, node-IP allow on $bport)
  for mode in enforce audit warn; do
    label="$(k get namespaces "$check_ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "restricted" ]]; then pass "$check_ns PSA $mode=restricted"; else fail "$check_ns PSA $mode='$label' (namespace owned by ingress_traefik)"; return 0; fi
  done
  local np; np="$(k get networkpolicies -n "$check_ns" -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.policyTypes}:{.spec.ingress[*].from[*].ipBlock.cidr}:{.spec.ingress[*].ports[*].port}{"\n"}{end}' 2>&1 | sort | tr '\n' ' ')"
  if [[ "$np" =~ default-deny:\[\"Ingress\",\"Egress\"\]:: ]] && [[ "$np" =~ allow-node-ip:\[\"Ingress\"\]:[0-9.]+/32:$bport ]]; then pass "$check_ns has default-deny ingress+egress and an ingress allow from the node IP /32 on :$bport"
  else fail "$check_ns NetworkPolicies unexpected: $np"; fi
  CHECK4_NS="$check_ns"
  trap cleanup_4 EXIT
  local out
  out="$(k apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: verify-web
  namespace: $check_ns
  labels: {app: verify-web, verify: check-4}
spec:
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: web
      image: $img
      command: [sh, -c, "echo $body > /www/index.html && exec httpd -f -p $bport -h /www"]
      ports:
        - {name: http, containerPort: $bport}
      readinessProbe:
        tcpSocket: {port: http}
        periodSeconds: 2
      resources:
        requests: {cpu: 10m, memory: 8Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - {name: www, mountPath: /www}
  volumes:
    - name: www
      emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: verify-web
  namespace: $check_ns
  labels: {verify: check-4}
spec:
  selector: {app: verify-web}
  ports:
    - {name: http, port: 80, targetPort: http}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: verify-tls
  namespace: $check_ns
  labels: {verify: check-4}
spec:
  secretName: verify-tls
  dnsNames: [$host]
  issuerRef: {name: $issuer, kind: ClusterIssuer}
  # 1h is the minimum duration cert-manager accepts; renewBefore leaves a 15 s window, so it renews within seconds.
  duration: 1h
  renewBefore: 59m45s
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: verify-web
  namespace: $check_ns
  labels: {verify: check-4}
spec:
  tls:
    - {hosts: [$host], secretName: verify-tls}
  rules:
    - host: $host
      http:
        paths:
          - {path: /, pathType: Prefix, backend: {service: {name: verify-web, port: {name: http}}}}
MANIFEST
)"
  if [[ $? -ne 0 ]]; then fail "could not create the test pod/Service/Certificate/Ingress in $check_ns: $out"; cleanup_4; trap - EXIT; return 0; fi

  if k wait --for=condition=Ready pod/verify-web -n "$check_ns" --timeout=120s >/dev/null 2>&1; then pass "non-root backend pod (PSA restricted namespace) is Ready"
  else fail "backend pod not Ready: $(k get pods verify-web -n "$check_ns" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}' 2>&1)"; cleanup_4; trap - EXIT; return 0; fi
  if k wait --for=condition=Ready certificate/verify-tls -n "$check_ns" --timeout=120s >/dev/null 2>&1; then pass "cert-manager issued the test Certificate from $issuer"
  else fail "Certificate not Ready: $(k get certificate verify-tls -n "$check_ns" -o jsonpath='{.status.conditions[*].message}' 2>&1)"; cleanup_4; trap - EXIT; return 0; fi

  # HTTPS through Lima's :443 -> Traefik :8443, validated against the committed CA only
  local i resp="" code=""
  for i in $(seq 1 30); do
    resp="$(curl -sS --max-time 5 --resolve "$host:443:127.0.0.1" --cacert "$CA_CERT" -w '\n%{http_code}' "https://$host/" 2>&1)"; code="${resp##*$'\n'}"
    [[ "$code" == "200" ]] && break; sleep 2
  done
  local got="${resp%$'\n'*}"; got="${got%$'\n'}"
  if [[ "$code" == "200" && "$got" == "$body" ]]; then pass "https://$host/ -> 200 with the backend body; chain verifies against certs/ca.crt"
  else fail "https://$host/ via :443: ${resp//$'\n'/ }"; fi

  # openssl (not just curl) must accept the name-constrained chain
  local vrc; vrc="$(openssl s_client -servername "$host" -connect 127.0.0.1:443 -CAfile "$CA_CERT" </dev/null 2>&1 | grep -m1 'Verify return code')"
  if [[ "$vrc" == *"code: 0 (ok)"* ]]; then pass "openssl s_client verifies the served chain against certs/ca.crt (name constraints satisfied)"
  else fail "openssl s_client chain verification: ${vrc:-no result}"; fi

  local redirect; redirect="$(curl -sS --max-time 5 --resolve "$host:80:127.0.0.1" -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/" 2>&1)"
  if [[ "$redirect" == "301 https://$host/" || "$redirect" == "308 https://$host/" ]]; then pass "http://$host/ via :80 redirects permanently to HTTPS ($redirect)"
  else fail "http://$host/ via :80: '$redirect' (want 301/308 to https://$host/)"; fi

  # Renewal: the short-lived Certificate is re-issued and Traefik serves the new leaf without a restart
  local serial0 serial="" rev="" renewed=0
  serial0="$(served_serial "$host")"
  for i in $(seq 1 45); do
    rev="$(k get certificate verify-tls -n "$check_ns" -o jsonpath='{.status.revision}' 2>&1)"
    serial="$(served_serial "$host")"
    if [[ "$rev" =~ ^[0-9]+$ && "$rev" -ge 2 && -n "$serial" && -n "$serial0" && "$serial" != "$serial0" ]]; then renewed=1; break; fi
    sleep 2
  done
  if [[ $renewed == 1 ]]; then pass "Certificate auto-renewed (revision $rev) and Traefik serves the new leaf ($serial0 -> $serial)"
  else fail "no renewal within 90 s: revision '$rev', served serial '$serial0' -> '$serial'"; fi
  resp="$(curl -sS --max-time 5 --resolve "$host:443:127.0.0.1" --cacert "$CA_CERT" "https://$host/" 2>&1)"
  if [[ "$resp" == "$body" ]]; then pass "https://$host/ still verifies against certs/ca.crt after renewal"; else fail "https after renewal: $resp"; fi
  cleanup_4; trap - EXIT
}

VERIFY_NS=verify-tmp
VERIFY_NS_CREATED=0
# B-034: a namespace deleted by an earlier check or run stays Terminating for a few seconds; creating objects in it fails.
wait_verify_ns_gone() {
  if [[ "$(k get namespaces "$VERIFY_NS" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Terminating" ]]; then
    k wait --for=delete "namespace/$VERIFY_NS" --timeout=120s >/dev/null 2>&1
  fi
}
cleanup_5() {
  k delete pod verify-storage -n "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  k delete pvc verify-storage -n "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  if [[ "$VERIFY_NS_CREATED" == 1 ]]; then k delete namespace "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1; fi
  VERIFY_NS_CREATED=0
}

check_5() { # default StorageClass: local-path-provisioner, dynamic PVC for a non-root pod, volume cleaned on delete (M4)
  need_cluster || return 0
  local vy="$ROOT/ansible/group_vars/all/versions.yml" role="$ROOT/ansible/roles/storage/defaults/main.yml"
  local sc_name sc_prov data_dir ns
  sc_name="$(sed -n 's/^storage_class_name:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  sc_prov="$(sed -n 's/^storage_provisioner_name:[[:space:]]*\([a-z./-]*\).*/\1/p' "$role")"
  data_dir="$(sed -n 's/^storage_data_dir:[[:space:]]*\(\/[a-z0-9\/_-]*\).*/\1/p' "$role")"
  ns="$(sed -n 's/^ns_storage:[[:space:]]*\([a-z-]*\).*/\1/p' "$ROOT/ansible/group_vars/all/main.yml")"
  if [[ -z "$sc_name" || -z "$sc_prov" || -z "$data_dir" || -z "$ns" ]]; then fail "storage role defaults / ns_storage not found"; return 0; fi

  # Exactly one default class, ours, with the expected behaviour
  local defaults; defaults="$(k get storageclasses -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>&1 | awk '$2 == "true" {print $1}')"
  if [[ "$defaults" == "$sc_name" ]]; then pass "$sc_name is the only default StorageClass"; else fail "default StorageClasses: '$(tr '\n' ' ' <<<"$defaults")' (want only $sc_name)"; fi
  local sc; sc="$(k get storageclasses "$sc_name" -o jsonpath='{.provisioner} {.volumeBindingMode} {.reclaimPolicy}' 2>&1)"
  if [[ "$sc" == "$sc_prov WaitForFirstConsumer Delete" ]]; then pass "$sc_name: provisioner $sc_prov, WaitForFirstConsumer, reclaimPolicy Delete"; else fail "$sc_name spec: $sc"; fi

  # Provisioner: ready, image by pinned digest, requests set, namespace PSA labels
  local ready; ready="$(k get deployments local-path-provisioner -n "$ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>&1)"
  if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "provisioner Deployment ready ($ready)"; else fail "provisioner replicas/ready: $ready"; fi
  local want_img got_img
  want_img="docker.io/rancher/local-path-provisioner:$(pinned local_path_provisioner_version)@$(pinned local_path_provisioner_digest)"
  got_img="$(k get deployments local-path-provisioner -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1)"
  if [[ "$got_img" == "$want_img" ]]; then pass "provisioner image is the pinned tag@digest"; else fail "provisioner image '$got_img' (want $want_img)"; fi
  local pod_info; pod_info="$(k get pods -n "$ns" -l app=local-path-provisioner -o jsonpath='{range .items[*]}{.status.qosClass} {.status.containerStatuses[0].imageID}{"\n"}{end}' 2>&1)"
  if [[ -n "$pod_info" ]] && ! grep -q '^BestEffort' <<<"$pod_info" && ! grep -qv "@$(pinned local_path_provisioner_digest)\$" <<<"$pod_info"; then
    pass "provisioner pod has requests (not BestEffort) and runs the pinned digest (imageID)"
  else fail "provisioner pod: ${pod_info:-no pods}"; fi
  local mode label
  for mode in enforce audit warn; do
    label="$(k get namespaces "$ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "privileged" ]]; then pass "$ns PSA $mode=privileged (platform namespace: helper pods use hostPath)"; else fail "$ns PSA $mode='$label'"; fi
  done

  # The helper pod that creates/removes volume directories must use the pinned busybox, not `busybox`
  local helper; helper="$(k get configmaps local-path-config -n "$ns" -o jsonpath='{.data.helperPod\.yaml}' 2>&1)"
  if grep -q "image: docker.io/library/busybox:$(pinned local_path_helper_version)@$(pinned local_path_helper_digest)\$" <<<"$helper"; then pass "helperPod image is pinned by tag@digest"
  else fail "helperPod image not the pinned busybox: $(grep 'image:' <<<"$helper")"; fi

  # End to end: PVC without storageClassName + PSA-restricted non-root pod writes a file
  local img; img="docker.io/library/busybox:$(pinned local_path_helper_version)@$(pinned local_path_helper_digest)"
  wait_verify_ns_gone
  VERIFY_NS_CREATED=0
  if ! k get namespaces "$VERIFY_NS" >/dev/null 2>&1; then VERIFY_NS_CREATED=1; fi
  trap cleanup_5 EXIT
  local out
  out="$(k apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Namespace
metadata:
  name: $VERIFY_NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: verify-storage
  namespace: $VERIFY_NS
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-storage
  namespace: $VERIFY_NS
spec:
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: t
      image: $img
      command: [sh, -c, "mkdir -p /data/sub && echo verify-ok > /data/sub/f && sleep 3600"]
      resources:
        requests: {cpu: 10m, memory: 8Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - {name: data, mountPath: /data}
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: verify-storage
MANIFEST
)"
  if [[ $? -ne 0 ]]; then fail "could not create the test PVC/pod in $VERIFY_NS: $out"; cleanup_5; trap - EXIT; return 0; fi

  if k wait --for=condition=Ready pod/verify-storage -n "$VERIFY_NS" --timeout=180s >/dev/null 2>&1; then pass "non-root pod using a PVC without storageClassName became Ready"
  else
    fail "test pod not Ready: $(k get pods verify-storage -n "$VERIFY_NS" -o jsonpath='{.status.phase} {.status.containerStatuses[0].state}' 2>&1)"
    cleanup_5; trap - EXIT; return 0
  fi
  local pvc; pvc="$(k get pvc verify-storage -n "$VERIFY_NS" -o jsonpath='{.status.phase} {.spec.storageClassName} {.spec.volumeName}' 2>&1)"
  local phase pv_sc pv; read -r phase pv_sc pv <<<"$pvc"
  if [[ "$phase" == "Bound" && "$pv_sc" == "$sc_name" ]]; then pass "PVC Bound with the default class ($pv_sc)"; else fail "PVC: $pvc"; fi
  if [[ "$(k exec -n "$VERIFY_NS" verify-storage -- cat /data/sub/f 2>&1)" == "verify-ok" ]]; then pass "file written by the non-root pod reads back"; else fail "could not read /data/sub/f from the pod"; fi

  local hostdir; hostdir="$(k get pv "$pv" -o jsonpath='{.spec.hostPath.path}' 2>&1)"
  if [[ "$hostdir" == "$data_dir"/* ]] && node test -f "$hostdir/sub/f"; then pass "volume data is on the node under $data_dir"; else fail "PV path '$hostdir' not under $data_dir or file missing"; fi

  # Teardown removes root-owned-parent dirs holding files owned by UID 1000 (needs the helper's DAC_OVERRIDE)
  k delete pod verify-storage -n "$VERIFY_NS" --wait=true --timeout=60s >/dev/null 2>&1
  k delete pvc verify-storage -n "$VERIFY_NS" --wait=true --timeout=60s >/dev/null 2>&1
  local i gone=0
  for i in $(seq 1 30); do
    if ! k get pv "$pv" >/dev/null 2>&1; then gone=1; break; fi; sleep 2
  done
  if [[ $gone == 1 ]]; then pass "PV $pv deleted after the PVC (reclaimPolicy Delete)"; else fail "PV $pv still present 60s after PVC deletion"; fi
  gone=0
  for i in $(seq 1 15); do
    if node test ! -e "$hostdir"; then gone=1; break; fi; sleep 2
  done
  if [[ $gone == 1 ]]; then pass "volume directory removed from the node (non-root-owned files deleted)"; else fail "$hostdir still on the node"; fi
  cleanup_5; trap - EXIT
}

# check_6 queries Prometheus and Alertmanager through the API-server service proxy (admin kubeconfig, no port-forward).
# Test objects live in the role-owned monitoring namespace (labelled verify=check-6) and in verify-tmp; all are removed.
CHECK6_NS=""
cleanup_6() {
  if [[ -n "$CHECK6_NS" ]]; then k delete pod,configmap -n "$CHECK6_NS" -l verify=check-6 --ignore-not-found --wait=false >/dev/null 2>&1; fi
  k delete pod verify-netpol -n "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1
  if [[ "$VERIFY_NS_CREATED" == 1 ]]; then k delete namespace "$VERIFY_NS" --ignore-not-found --wait=false >/dev/null 2>&1; fi
  VERIFY_NS_CREATED=0
}
# svc_get <namespace> <service:port> <path>
svc_get() { k get --raw "/api/v1/namespaces/$1/services/$2/proxy/$3" 2>&1; }
# grafana_get <path> [password]: HTTPS via Lima :443 and Traefik, trusting only certs/ca.crt; the password goes to curl on stdin, never into argv or output.
grafana_get() {
  local path="$1" pw="${2:-}"
  if [[ -n "$pw" ]]; then
    printf 'user = "admin:%s"\n' "$pw" | curl -sS --max-time 10 -K - --resolve "$GRAFANA_HOST:443:127.0.0.1" --cacert "$CA_CERT" -w '\n%{http_code}' "https://$GRAFANA_HOST$path" 2>&1
  else
    curl -sS --max-time 10 --resolve "$GRAFANA_HOST:443:127.0.0.1" --cacert "$CA_CERT" -w '\n%{http_code}' "https://$GRAFANA_HOST$path" 2>&1
  fi
}

check_6() { # Prometheus, Grafana, node + etcd alerts in Alertmanager (M6)
  need_cluster || return 0
  if ! command -v jq >/dev/null 2>&1; then fail "jq is required on the host for check_6"; return 0; fi
  local vy="$ROOT/ansible/group_vars/all/versions.yml" main="$ROOT/ansible/group_vars/all/main.yml" role="$ROOT/ansible/roles/monitoring/defaults/main.yml"
  local ns ne_ns rel gsecret gtls host issuer duration renew
  ns="$(sed -n 's/^ns_monitoring:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  host="$(sed -n 's/^grafana_hostname:[[:space:]]*\([a-z.-]*\).*/\1/p' "$main")"
  issuer="$(sed -n 's/^pki_cluster_issuer:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  duration="$(sed -n 's/^pki_cert_duration:[[:space:]]*\([0-9a-z]*\).*/\1/p' "$main")"
  renew="$(sed -n 's/^pki_cert_renew_before:[[:space:]]*\([0-9a-z]*\).*/\1/p' "$main")"
  ne_ns="$(sed -n 's/^monitoring_node_exporter_namespace:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  rel="$(sed -n 's/^monitoring_release:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  gsecret="$(sed -n 's/^monitoring_grafana_secret:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  gtls="$(sed -n 's/^monitoring_grafana_tls_secret:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  if [[ -z "$ns" || -z "$host" || -z "$issuer" || -z "$duration" || -z "$renew" || -z "$ne_ns" || -z "$rel" || -z "$gsecret" || -z "$gtls" ]]; then
    fail "monitoring role defaults or group_vars keys not found"; return 0
  fi
  GRAFANA_HOST="$host"
  local prom="$rel-prometheus:http-web" am="$rel-alertmanager:http-web"

  # --- Workloads ready: operator, Grafana, kube-state-metrics, node-exporter, Prometheus, Alertmanager
  local ready dep sts
  for dep in operator grafana kube-state-metrics; do
    ready="$(k get deployments "$rel-$dep" -n "$ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>&1)"
    if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "Deployment $rel-$dep ready ($ready)"; else fail "Deployment $rel-$dep replicas/ready: $ready"; fi
  done
  ready="$(k get daemonsets "$rel-prometheus-node-exporter" -n "$ne_ns" -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}' 2>&1)"
  if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "DaemonSet node-exporter ready ($ready)"; else fail "DaemonSet node-exporter desired/ready: $ready"; fi
  for sts in "prometheus-$rel-prometheus" "alertmanager-$rel-alertmanager"; do
    ready="$(k get statefulsets "$sts" -n "$ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas}' 2>&1)"
    if [[ "$ready" =~ ^([1-9][0-9]*)\ \1$ ]]; then pass "StatefulSet $sts ready ($ready)"; else fail "StatefulSet $sts replicas/ready: $ready"; fi
  done
  local chart want_chart
  want_chart="kube-prometheus-stack-$(pinned kube_prometheus_stack_chart_version)"
  chart="$(k get deployments "$rel-operator" -n "$ns" -o jsonpath='{.metadata.labels.chart}' 2>&1)"
  if [[ "$chart" == "$want_chart" ]]; then pass "chart is the pinned $want_chart"; else fail "chart '$chart' (want $want_chart)"; fi

  # --- Hardening: PSA labels, digest-pinned images, requests, restricted-style security contexts
  local mode label
  for mode in enforce audit warn; do
    label="$(k get namespaces "$ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "restricted" ]]; then pass "$ns PSA $mode=restricted"; else fail "$ns PSA $mode='$label'"; fi
  done
  for mode in enforce audit warn; do
    label="$(k get namespaces "$ne_ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "privileged" ]]; then pass "$ne_ns PSA $mode=privileged (platform namespace: node-exporter needs hostNetwork/hostPID/hostPath)"; else fail "$ne_ns PSA $mode='$label'"; fi
  done
  local digests res n bad
  digests="$(awk '/^monitoring_images:/ {f = 1; next} f && /^[^ ]/ {f = 0} f' "$vy" | grep -o 'sha256:[0-9a-f]\{64\}')"
  if [[ -z "$digests" ]]; then fail "no monitoring image digests in versions.yml"; else
    for n in "$ns" "$ne_ns"; do
      res="$(images_unpinned "$n" "$digests")"; bad="${res#* }"; res="${res%% *}"
      if [[ "$res" -gt 0 && -z "${bad// /}" ]]; then pass "all $res containers in $n run by pinned digest (spec image and imageID)"
      else fail "$n not digest-pinned (n=$res): ${bad:-no containers}"; fi
    done
  fi
  bad="$({ k get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}'; k get pods -n "$ne_ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.qosClass}{"\n"}{end}'; } 2>&1 | awk 'NF && $2 == "BestEffort" {printf "%s ", $1}')"
  if [[ -z "$bad" ]]; then pass "monitoring pods have resource requests"; else fail "BestEffort pods: $bad"; fi
  bad="$(k get pods -n "$ns" -o json 2>&1 | jq -r '.items[] | .metadata.name as $p | .spec as $s
    | ( [ ($s.containers + ($s.initContainers // []))[]
          | select((.securityContext.runAsNonRoot == true or $s.securityContext.runAsNonRoot == true | not)
                or (.securityContext.allowPrivilegeEscalation != false)
                or (.securityContext.privileged == true)
                or (((.securityContext.capabilities.drop // []) | index("ALL")) == null)
                or ((.securityContext.seccompProfile.type // $s.securityContext.seccompProfile.type // "") != "RuntimeDefault")
                or (.securityContext.readOnlyRootFilesystem != true))
          | "\($p)/\(.name)" ]
        + (if ($s.hostNetwork == true or $s.hostPID == true or $s.hostIPC == true) then ["\($p)/host-namespaces"] else [] end) )[]' | tr '\n' ' ')"
  if [[ -z "${bad// /}" ]]; then pass "every $ns container: runAsNonRoot, no privilege escalation, drop ALL, seccomp RuntimeDefault, read-only rootfs; no host namespaces"
  else fail "$ns containers not restricted-clean: $bad"; fi
  # B-040: node-exporter needs host namespaces and mounts (PSA privileged) but nothing else: non-root, no new privileges, no capabilities, seccomp
  bad="$(k get pods -n "$ne_ns" -o json 2>&1 | jq -r '.items[] | .metadata.name as $p | .spec as $s | $s.containers[]
    | select((.securityContext.runAsNonRoot == true or $s.securityContext.runAsNonRoot == true | not)
          or (.securityContext.allowPrivilegeEscalation != false)
          or (.securityContext.privileged == true)
          or (((.securityContext.capabilities.drop // []) | index("ALL")) == null)
          or ((.securityContext.capabilities.add // []) | length > 0)
          or ((.securityContext.seccompProfile.type // $s.securityContext.seccompProfile.type // "") != "RuntimeDefault")
          or (.securityContext.readOnlyRootFilesystem != true))
    | "\($p)/\(.name)"' 2>&1 | tr '\n' ' ')"
  if [[ -z "${bad// /}" ]]; then pass "$ne_ns containers: runAsNonRoot, no privilege escalation, drop ALL (no added caps), seccomp RuntimeDefault, read-only rootfs"
  else fail "$ne_ns containers not hardened: $bad"; fi

  # --- Storage and sizing: Prometheus on a default-class PVC with retention limits; room left for the llama.cpp pod
  local pvc; pvc="$(k get pvc -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.storageClassName}{" "}{.status.phase}{"\n"}{end}' 2>&1)"
  if grep -Eq "^prometheus-$rel-prometheus-db-.* local-path Bound\$" <<<"$pvc"; then pass "Prometheus data is on a Bound local-path PVC"; else fail "Prometheus PVC: ${pvc:-none}"; fi
  local ret; ret="$(k get prometheuses "$rel-prometheus" -n "$ns" -o jsonpath='{.spec.retention} {.spec.retentionSize}' 2>&1)"
  if [[ "$ret" =~ ^[0-9]+[a-z]\ [0-9]+[A-Za-z]+$ ]]; then pass "Prometheus retention bounded by time and size ($ret)"; else fail "Prometheus retention/retentionSize: '$ret'"; fi
  # B-042: query caps in the live Prometheus args, sized so concurrency x samples x bytes/sample fits the heap headroom under the memory limit
  local qc qs qt qb qo qh qargs
  qc="$(sed -n 's/^monitoring_query_max_concurrency:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  qs="$(sed -n 's/^monitoring_query_max_samples:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  qt="$(sed -n 's/^monitoring_query_timeout:[[:space:]]*\([0-9a-z]*\).*/\1/p' "$role")"
  qb="$(sed -n 's/^monitoring_query_bytes_per_sample:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  qo="$(sed -n 's/^monitoring_query_overlap:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  qh="$(sed -n 's/^monitoring_query_headroom_mib:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  qargs="$(k get pod "prometheus-$rel-prometheus-0" -n "$ns" -o json 2>&1 | jq -r '[.spec.containers[] | select(.name == "prometheus") | .args[] | select(startswith("--query."))] | sort | join(" ")' 2>&1)"
  if [[ -z "$qc" || -z "$qs" || -z "$qt" || -z "$qb" || -z "$qo" || -z "$qh" ]]; then fail "monitoring_query_* defaults not found in the monitoring role"
  elif [[ "$qargs" != "--query.max-concurrency=$qc --query.max-samples=$qs --query.timeout=$qt" ]]; then fail "Prometheus query args '$qargs' differ from the role defaults (concurrency $qc, samples $qs, timeout $qt)"
  elif [[ $((qc * qo * qs * qb)) -le $((qh * 1048576)) ]]; then pass "Prometheus query caps: $qc concurrent x $qo overlap x $qs samples x ${qb}B = $((qc * qo * qs * qb / 1048576))Mi <= ${qh}Mi heap headroom (timeout $qt)"
  else fail "Prometheus query caps too loose: $qc x $qo x $qs x ${qb}B = $((qc * qo * qs * qb / 1048576))Mi > ${qh}Mi headroom (OOM risk)"; fi
  local gogc want_gogc; want_gogc="$(sed -n 's/^monitoring_prometheus_gogc:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  gogc="$(k get pod "prometheus-$rel-prometheus-0" -n "$ns" -o json 2>&1 | jq -r '.spec.containers[] | select(.name == "prometheus") | .env[]? | select(.name == "GOGC") | .value' 2>&1)"
  if [[ -n "$want_gogc" && "$gogc" == "$want_gogc" ]]; then pass "Prometheus runs with GOGC=$gogc (heap does not float up to the memory limit)"; else fail "Prometheus GOGC '$gogc' (want '$want_gogc')"; fi
  local restarts; restarts="$(k get pod "prometheus-$rel-prometheus-0" -n "$ns" -o jsonpath='{.status.containerStatuses[?(@.name=="prometheus")].lastState.terminated.reason}' 2>&1)"
  if [[ "$restarts" != "OOMKilled" ]]; then pass "Prometheus container was not OOMKilled"; else fail "Prometheus container last state: OOMKilled (raise the limit or lower the query caps)"; fi
  # Budget (B-041): every container has a memory request and limit, and the sums stay under the caps that leave room for llama.cpp (M9)
  local cap_req cap_lim mem
  cap_req="$(sed -n 's/^monitoring_budget_requests_mib:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  cap_lim="$(sed -n 's/^monitoring_budget_limits_mib:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  mem="$({ k get pods -n "$ns" -o json; k get pods -n "$ne_ns" -o json; } 2>&1 | jq -rs '
    def mib: if . == null then null elif test("Gi$") then (.[:-2] | tonumber * 1024) elif test("Mi$") then (.[:-2] | tonumber)
      elif test("Ki$") then (.[:-2] | tonumber / 1024) elif test("G$") then (.[:-1] | tonumber * 953.67) elif test("M$") then (.[:-1] | tonumber * 0.9537)
      elif test("^[0-9]+$") then (tonumber / 1048576) else null end;
    [.[].items[].spec.containers[] | {n: .name, r: (.resources.requests.memory | mib), l: (.resources.limits.memory | mib)}] as $c
    | "\([$c[] | select(.r == null or .l == null) | .n] | join(",")) \($c | map(.r // 0) | add | floor) \($c | map(.l // 0) | add | floor) \($c | length)"' 2>&1)"
  if [[ -z "$cap_req" || -z "$cap_lim" ]]; then fail "monitoring_budget_*_mib not found in the monitoring role defaults"
  elif [[ "$mem" =~ ^([^\ ]*)\ ([0-9]+)\ ([0-9]+)\ ([0-9]+)$ ]]; then
    local unset_c="${BASH_REMATCH[1]}" sum_req="${BASH_REMATCH[2]}" sum_lim="${BASH_REMATCH[3]}" n_c="${BASH_REMATCH[4]}"
    if [[ -z "$unset_c" ]]; then pass "all $n_c monitoring containers have memory requests and limits"; else fail "containers without a memory request or limit: $unset_c"; fi
    if [[ "$sum_req" -le "$cap_req" && "$sum_lim" -le "$cap_lim" ]]; then pass "memory budget: requests ${sum_req}Mi <= ${cap_req}Mi, limits ${sum_lim}Mi <= ${cap_lim}Mi (leaves room for llama.cpp, M9)"
    else fail "memory budget exceeded: requests ${sum_req}Mi (cap ${cap_req}Mi), limits ${sum_lim}Mi (cap ${cap_lim}Mi)"; fi
  else fail "could not compute the memory budget: ${mem:0:200}"; fi

  # --- Grafana credentials: Secret exists and is referenced by the Deployment (no plaintext); the host copy is private and only used to log in
  local desc; desc="$(k describe secret "$gsecret" -n "$ns" 2>&1)"
  if grep -q '^admin-password:' <<<"$desc" && grep -q '^admin-user:' <<<"$desc"; then pass "Secret $gsecret (admin-user, admin-password) exists in $ns"; else fail "Secret $gsecret missing or incomplete in $ns"; fi
  local envref; envref="$(k get deployments "$rel-grafana" -n "$ns" -o json 2>&1 | jq -r '.spec.template.spec.containers[] | select(.name == "grafana") | .env[] | select(.name == "GF_SECURITY_ADMIN_PASSWORD") | "\(.valueFrom.secretKeyRef.name) \(.value // "no-plaintext")"' 2>&1)"
  if [[ "$envref" == "$gsecret no-plaintext" ]]; then pass "Grafana takes the admin password from Secret $gsecret, not from a plaintext env value"; else fail "Grafana admin password env: '$envref'"; fi
  local pwfile="$ROOT/.secrets/grafana-admin-password" fmode pw=""
  fmode="$(stat -f '%Lp' "$pwfile" 2>/dev/null || stat -c '%a' "$pwfile" 2>/dev/null)"
  if [[ -f "$pwfile" && "$fmode" == "600" ]]; then pass ".secrets/grafana-admin-password exists with mode 600"; else fail ".secrets/grafana-admin-password missing or mode '$fmode' (want 600)"; fi
  if [[ -f "$pwfile" ]]; then pw="$(<"$pwfile")"; fi
  # B-039: Grafana is reachable from the Mac; its ServiceAccount must not read the CA key or any other Secret
  local gsa="system:serviceaccount:$ns:$rel-grafana" can_ns
  for can_ns in cert-manager kube-system "$ns"; do
    if [[ "$(k auth can-i get secrets -n "$can_ns" --as="$gsa" 2>&1)" == "no" ]]; then pass "Grafana ServiceAccount cannot get Secrets in $can_ns"
    else fail "Grafana ServiceAccount can read Secrets in $can_ns"; fi
  done
  if [[ "$(k auth can-i list secrets --all-namespaces --as="$gsa" 2>&1)" == "no" ]]; then pass "Grafana ServiceAccount cannot list Secrets cluster-wide"; else fail "Grafana ServiceAccount can list Secrets cluster-wide"; fi
  if [[ "$(k auth can-i list configmaps -n "$ns" --as="$gsa" 2>&1)" == "yes" ]]; then pass "Grafana ServiceAccount reads ConfigMaps in $ns (sidecar provisioning)"; else fail "Grafana ServiceAccount cannot list ConfigMaps in $ns"; fi
  bad="$(k get deployments "$rel-grafana" -n "$ns" -o json 2>&1 | jq -r '[.spec.template.spec.containers[] | select(.name | startswith("grafana-sc-")) | select(([.env[] | select(.name == "RESOURCE" and .value == "configmap")] | length) != 1 or ([.env[] | select(.name == "NAMESPACE" and .value == "ALL")] | length) != 0) | .name] | join(" ")' 2>&1)"
  if [[ -z "$bad" ]]; then pass "Grafana sidecars watch ConfigMaps only, not all namespaces"; else fail "Grafana sidecars not narrowed: $bad"; fi

  # --- Scrape targets: every kubeadm control-plane component, kubelet, node-exporter and the stack itself, all UP
  # A just-restarted Prometheus needs one scrape interval before every target reports: wait for that, not for a fix.
  local targets; targets="$(svc_get "$ns" "$prom" api/v1/targets)"
  for _ in $(seq 1 45); do
    jq -e '[.data.activeTargets[] | select(.health != "up")] | length == 0' >/dev/null 2>&1 <<<"$targets" && break
    sleep 2; targets="$(svc_get "$ns" "$prom" api/v1/targets)"
  done
  if ! jq -e '.status == "success"' >/dev/null 2>&1 <<<"$targets"; then fail "Prometheus targets API unreachable via the service proxy: ${targets:0:200}"; else
    local job up_n
    for job in kube-etcd node-exporter kubelet apiserver kube-controller-manager kube-scheduler kube-proxy kube-state-metrics coredns "$rel-prometheus" "$rel-alertmanager" "$rel-grafana" "$rel-operator" traefik; do
      up_n="$(jq -r --arg j "$job" '[.data.activeTargets[] | select(.labels.job == $j and .health == "up")] | length' <<<"$targets")"
      if [[ "$up_n" =~ ^[1-9][0-9]*$ ]]; then pass "target job $job: $up_n UP"; else fail "target job $job has no UP target"; fi
    done
    bad="$(jq -r '[.data.activeTargets[] | select(.health != "up") | "\(.labels.job)@\(.scrapeUrl) \(.lastError)"] | join("; ")' <<<"$targets")"
    if [[ -z "$bad" ]]; then pass "no scrape target is down ($(jq '.data.activeTargets | length' <<<"$targets") active)"; else fail "targets not UP: ${bad:0:300}"; fi
  fi

  # --- Rules: node-health, etcd-health and Traefik alerts loaded and evaluating without errors
  # Right after a Prometheus restart some groups (30d burn-rate rules) report health "unknown" until their first evaluation: wait for it.
  local rules; rules="$(svc_get "$ns" "$prom" api/v1/rules)"
  for _ in $(seq 1 90); do
    jq -e '[.data.groups[].rules[] | select(.health == "unknown")] | length == 0' >/dev/null 2>&1 <<<"$rules" && break
    sleep 2; rules="$(svc_get "$ns" "$prom" api/v1/rules)"
  done
  if ! jq -e '.status == "success"' >/dev/null 2>&1 <<<"$rules"; then fail "Prometheus rules API unreachable: ${rules:0:200}"; else
    local alert
    for alert in KubeNodeNotReady KubeNodeUnreachable KubeletDown NodeFilesystemAlmostOutOfSpace NodeClockNotSynchronising etcdMembersDown etcdNoLeader etcdInsufficientMembers TraefikDown TraefikIngressNotSynced Watchdog; do
      if jq -e --arg a "$alert" '[.data.groups[].rules[] | select(.type == "alerting" and .name == $a)] | length > 0' >/dev/null <<<"$rules"; then pass "alert rule $alert loaded"; else fail "alert rule $alert not loaded"; fi
    done
    bad="$(jq -r '[.data.groups[] | .name as $g | .rules[] | select(.health != "ok" or ((.lastError // "") != "")) | "\($g)/\(.name)"] | join(" ")' <<<"$rules")"
    if [[ -z "$bad" ]]; then pass "all $(jq '[.data.groups[].rules[]] | length' <<<"$rules") rules in $(jq '.data.groups | length' <<<"$rules") groups have health ok and no lastError"; else fail "rules unhealthy: ${bad:0:300}"; fi
  fi

  # --- Pipeline: Prometheus -> Alertmanager; the always-firing Watchdog proves delivery end to end
  local ams i state="" phase="" out; ams="$(svc_get "$ns" "$prom" api/v1/alertmanagers)"
  if [[ "$(jq -r '.data.activeAlertmanagers | length' 2>/dev/null <<<"$ams")" =~ ^[1-9] ]]; then pass "Prometheus has an active Alertmanager endpoint"; else fail "Prometheus sees no active Alertmanager: ${ams:0:200}"; fi
  for i in $(seq 1 30); do
    state="$(svc_get "$ns" "$am" api/v2/alerts | jq -r '[.[] | select(.labels.alertname == "Watchdog")] | .[0].status.state // "absent"' 2>/dev/null)"
    [[ "$state" == "active" ]] && break; sleep 2
  done
  if [[ "$state" == "active" ]]; then pass "Alertmanager holds the Watchdog alert as active (Prometheus -> Alertmanager delivery works)"; else fail "Watchdog in Alertmanager: '${state:-unreachable}'"; fi

  # --- Alerts fire: a real node or etcd failure cannot be provoked without disrupting the cluster, so promtool unit-tests the rule
  # files Prometheus actually loaded (the operator's ConfigMap, not copies) in a throwaway pod (promtool needs a writable /tmp).
  local img cmname; img="$(k get prometheuses "$rel-prometheus" -n "$ns" -o jsonpath='{.spec.image}' 2>&1)"
  cmname="prometheus-$rel-prometheus-rulefiles-0"
  CHECK6_NS="$ns"; trap cleanup_6 EXIT
  k delete pod verify-promtool -n "$ns" --ignore-not-found --wait=true >/dev/null 2>&1
  k delete configmap verify-promtool-tests -n "$ns" --ignore-not-found >/dev/null 2>&1
  out="$(k create configmap verify-promtool-tests -n "$ns" --from-file=alert-tests.yaml="$ROOT/ansible/roles/monitoring/files/alert-tests.yaml" 2>&1 \
    && k label configmap verify-promtool-tests -n "$ns" verify=check-6 2>&1 \
    && k apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: verify-promtool
  namespace: $ns
  labels: {verify: check-6}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: promtool
      image: $img
      command: [promtool, test, rules, /tests/alert-tests.yaml]
      resources:
        requests: {cpu: 10m, memory: 64Mi}
        limits: {memory: 256Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
      volumeMounts:
        - {name: tests, mountPath: /tests}
        - {name: rules, mountPath: /etc/prometheus/rules/$cmname}
        - {name: tmp, mountPath: /tmp}
  volumes:
    - {name: tests, configMap: {name: verify-promtool-tests}}
    - {name: rules, configMap: {name: $cmname}}
    - {name: tmp, emptyDir: {}}
MANIFEST
)"
  if [[ $? -ne 0 ]]; then fail "could not create the promtool pod: ${out:0:300}"; else
    for i in $(seq 1 60); do
      phase="$(k get pod verify-promtool -n "$ns" -o jsonpath='{.status.phase}' 2>&1)"
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break; sleep 2
    done
    out="$(k logs verify-promtool -n "$ns" 2>&1)"
    if [[ "$phase" == "Succeeded" ]]; then pass "promtool: node (KubeNodeNotReady, NodeFilesystemAlmostOutOfSpace), etcd (NoLeader, InsufficientMembers, MembersDown) and Traefik alerts fire on failing input against the loaded rules"
    else fail "promtool rule tests ($phase): $(tr '\n' ' ' <<<"${out:0:600}")"; fi
  fi

  # --- Grafana through Traefik over TLS from the internal CA, no anonymous access, Prometheus datasource healthy, default dashboards
  local cert; cert="$(k get certificates "$gtls" -n "$ns" -o jsonpath='{.spec.issuerRef.name} {.spec.duration} {.spec.renewBefore} {.status.conditions[?(@.type=="Ready")].status}' 2>&1)"
  if [[ "$cert" == "$issuer $duration $renew True" ]]; then pass "Certificate $gtls from $issuer is Ready (duration $duration, renewBefore $renew)"; else fail "Certificate $gtls: $cert"; fi
  local resp code body
  resp="$(grafana_get /api/health)"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  if [[ "$code" == "200" && "$(jq -r '.database' 2>/dev/null <<<"$body")" == "ok" ]]; then pass "https://$host/api/health -> 200, database ok (chain verifies against certs/ca.crt, via Lima :443 and Traefik)"
  else fail "https://$host/api/health: ${resp//$'\n'/ }"; fi
  local vrc; vrc="$(openssl s_client -servername "$host" -connect 127.0.0.1:443 -CAfile "$CA_CERT" </dev/null 2>&1 | grep -m1 'Verify return code')"
  if [[ "$vrc" == *"code: 0 (ok)"* ]]; then pass "openssl s_client verifies the Grafana chain against certs/ca.crt"; else fail "openssl s_client chain verification: ${vrc:-no result}"; fi
  resp="$(grafana_get /api/org)"; code="${resp##*$'\n'}"
  if [[ "$code" == "401" ]]; then pass "anonymous access is off (/api/org without credentials -> 401)"; else fail "anonymous /api/org -> $code (want 401)"; fi
  if [[ -z "$pw" ]]; then fail "no Grafana admin password on the host: cannot log in"; else
    resp="$(grafana_get /api/org "$pw")"; code="${resp##*$'\n'}"
    if [[ "$code" == "200" ]]; then pass "admin login with the generated password works"; else fail "admin login -> $code"; fi
    resp="$(grafana_get /api/datasources/uid/prometheus/health "$pw")"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    if [[ "$code" == "200" && "$(jq -r '.status' 2>/dev/null <<<"$body")" == "OK" ]]; then pass "Grafana's Prometheus datasource is healthy"; else fail "datasource health ($code): ${body:0:200}"; fi
    resp="$(grafana_get '/api/search?type=dash-db' "$pw")"; code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    n="$(jq 'length' 2>/dev/null <<<"$body")"
    if [[ "$code" == "200" && "$n" =~ ^[1-9][0-9]*$ ]]; then pass "$n default dashboards provisioned"; else fail "dashboards ($code): ${body:0:200}"; fi
  fi

  # --- NetworkPolicies: default-deny ingress+egress, enforced (a pod outside the namespace reaches CoreDNS metrics but not Prometheus)
  local np; np="$(k get networkpolicies default-deny -n "$ns" -o jsonpath='{.spec.podSelector}{.spec.policyTypes}' 2>&1)"
  if [[ "$np" == '{}["Ingress","Egress"]' ]]; then pass "$ns has a default-deny NetworkPolicy for ingress and egress"; else fail "$ns default-deny: $np"; fi
  local prom_ip dns_ip busy
  prom_ip="$(k get pod "prometheus-$rel-prometheus-0" -n "$ns" -o jsonpath='{.status.podIP}' 2>&1)"
  dns_ip="$(k get pods -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}' 2>&1)"
  busy="docker.io/library/busybox:$(pinned local_path_helper_version)@$(pinned local_path_helper_digest)"
  wait_verify_ns_gone
  VERIFY_NS_CREATED=0
  if ! k get namespaces "$VERIFY_NS" >/dev/null 2>&1; then VERIFY_NS_CREATED=1; fi
  out="$(k apply -f - 2>&1 <<MANIFEST
apiVersion: v1
kind: Namespace
metadata: {name: $VERIFY_NS}
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-netpol
  namespace: $VERIFY_NS
  labels: {verify: check-6}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: $busy
      command:
        - sh
        - -c
        - "wget -T 3 -q -O /dev/null http://$dns_ip:9153/metrics && echo DNS_OPEN; wget -T 3 -q -O /dev/null http://$prom_ip:9090/-/ready && echo PROM_OPEN || echo PROM_BLOCKED"
      resources:
        requests: {cpu: 10m, memory: 8Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: [ALL]}
MANIFEST
)"
  if [[ $? -ne 0 ]]; then fail "could not create the NetworkPolicy probe pod: ${out:0:300}"; else
    for i in $(seq 1 60); do
      phase="$(k get pod verify-netpol -n "$VERIFY_NS" -o jsonpath='{.status.phase}' 2>&1)"
      [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break; sleep 2
    done
    out="$(k logs verify-netpol -n "$VERIFY_NS" 2>&1 | tr '\n' ' ')"
    if [[ "$out" == *DNS_OPEN* && "$out" == *PROM_BLOCKED* && "$out" != *PROM_OPEN* ]]; then pass "NetworkPolicy enforced: a pod outside $ns reaches CoreDNS but not Prometheus:9090"
    else fail "NetworkPolicy probe ($phase): ${out:0:200}"; fi
  fi
  cleanup_6; trap - EXIT
}

# check_7 only reads names, sizes and mtimes under backups/ (snapshots hold every Secret); content is read on the node by etcdutl only.
check_7() { # scheduled etcd snapshots stored outside the cluster (M7, B-010)
  CURRENT_REQ=7
  need_cluster || return 0
  if ! command -v jq >/dev/null 2>&1; then fail "jq is required on the host for check_7"; return 0; fi
  local main="$ROOT/ansible/group_vars/all/main.yml" role="$ROOT/ansible/roles/etcd_backup/defaults/main.yml"
  local bdir keep stale glob unit script fstype ns rule
  bdir="$(sed -n 's/^node_backup_dir:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$main")"
  keep="$(sed -n 's/^etcd_backup_retention:[[:space:]]*\([0-9]*\).*/\1/p' "$main")"
  ns="$(sed -n 's/^ns_monitoring:[[:space:]]*\([a-z-]*\).*/\1/p' "$main")"
  stale="$(sed -n 's/^etcd_backup_stale_after_seconds:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  glob="$(sed -n 's/^etcd_backup_snapshot_glob:[[:space:]]*"\([^"]*\)".*/\1/p' "$role")"
  unit="$(sed -n 's/^etcd_backup_unit:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  script="$(sed -n 's/^etcd_backup_script:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$role")"
  fstype="$(sed -n 's/^etcd_backup_mount_fstype:[[:space:]]*\([a-z0-9]*\).*/\1/p' "$role")"
  rule="$(sed -n 's/^etcd_backup_rule_name:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  if [[ -z "$bdir" || -z "$keep" || -z "$ns" || -z "$stale" || -z "$glob" || -z "$unit" || -z "$script" || -z "$fstype" || -z "$rule" ]]; then
    fail "etcd_backup defaults or group_vars keys not found"; return 0
  fi
  hstat() { stat -f '%z %m' "$1" 2>/dev/null || stat -c '%s %Y' "$1" 2>/dev/null; } # size mtime (BSD, then GNU)

  # --- Timer and unit
  if [[ "$(node systemctl is-active "$unit.timer" 2>&1)" == "active" ]]; then pass "$unit.timer is active"; else fail "$unit.timer is not active"; fi
  if [[ "$(node systemctl is-enabled "$unit.timer" 2>&1)" == "enabled" ]]; then pass "$unit.timer is enabled"; else fail "$unit.timer is not enabled"; fi
  if node systemctl cat "$unit.timer" 2>&1 | grep -q '^Persistent=true'; then pass "timer is Persistent (catches up after downtime)"; else fail "timer is not Persistent"; fi
  if [[ "$(node systemctl show "$unit.service" -p RequiresMountsFor --value 2>&1)" == *"$bdir"* ]]; then pass "$unit.service has RequiresMountsFor=$bdir"; else fail "$unit.service lacks RequiresMountsFor=$bdir (B-010)"; fi
  if [[ "$(node systemctl show "$unit.service" -p Result --value 2>&1)" == "success" ]]; then pass "last $unit.service run succeeded"; else fail "last $unit.service run did not succeed (journalctl -u $unit)"; fi

  # --- B-010: the node directory is the host mount, and the script refuses to write anywhere else
  local fs; fs="$(node findmnt -n -o FSTYPE -M "$bdir" 2>&1)"
  if [[ "$fs" == "$fstype" ]]; then pass "$bdir on the node is a $fstype mountpoint"; else fail "$bdir on the node: '$fs' (want a $fstype mountpoint)"; fi
  local out rc
  out="$(node env BACKUP_DIR=/var/tmp KEEP=1 TEXTFILE_DIR=/var/tmp METRICS_FILE=check7.prom MOUNT_FSTYPE="$fstype" ENDPOINT=x PKI_DIR=x SNAPSHOT_GLOB="$glob" "$script" 2>&1)"; rc=$?
  if [[ $rc -ne 0 && "$out" == *"refusing to write"* ]] && ! node sh -c 'ls /var/tmp/etcd-snapshot-* /var/tmp/.etcd-snapshot-* /var/tmp/check7.prom' >/dev/null 2>&1; then
    pass "the script refuses to write to a directory that is not the $fstype mount (nothing written to the VM disk)"
  else fail "the script did not refuse a non-mount directory (rc=$rc): ${out:0:200}"; fi

  # --- etcdctl/etcdutl match the pinned version and the etcd kubeadm runs
  local want img; want="$(pinned etcdctl_version)"
  img="$(k get pods "etcd-$NODE_NAME" -n kube-system -o jsonpath='{.spec.containers[0].image}' 2>&1)"
  if [[ "$img" == *"/etcd:${want#v}-"* ]]; then pass "pinned etcdctl $want matches the running etcd image ($img)"; else fail "etcd image '$img' vs pinned etcdctl $want"; fi
  if [[ "$(node etcdctl version 2>&1)" == *"etcdctl version: ${want#v}"* && "$(node etcdutl version 2>&1)" == *"etcdutl version: ${want#v}"* ]]; then pass "node etcdctl and etcdutl are $want"
  else fail "node etcdctl/etcdutl are not $want"; fi

  # --- Snapshots in host ./backups, the same files on the node (proves the mount), fresh, pruned
  local f name host_names="" latest="" now; now="$(date +%s)"
  shopt -s nullglob
  for f in "$ROOT"/backups/$glob; do
    name="${f##*/}"; host_names+="$name"$'\n'; latest="$name"
  done
  shopt -u nullglob
  host_names="$(sort <<<"${host_names%$'\n'}")"
  if [[ -z "$latest" ]]; then fail "no snapshot ($glob) in host ./backups"; else
    latest="$(tail -n 1 <<<"$host_names")"
    local hs hm age; read -r hs hm <<<"$(hstat "$ROOT/backups/$latest")"
    age=$((now - hm))
    if [[ "$hs" -gt 1000000 ]]; then pass "latest host snapshot $latest is $hs bytes"; else fail "latest host snapshot $latest is only $hs bytes"; fi
    if [[ $age -le $stale ]]; then pass "latest snapshot is ${age}s old (limit ${stale}s = 2x schedule)"; else fail "latest snapshot is ${age}s old (limit ${stale}s)"; fi
    local ns_ nm; read -r ns_ nm <<<"$(node stat -c '%s %Y' "$bdir/$latest" 2>&1)"
    if [[ "$ns_" == "$hs" && $((nm - hm)) -ge -2 && $((nm - hm)) -le 2 ]]; then pass "the same file ($hs bytes, same mtime) is visible on the node at $bdir: it is the host mount"
    else fail "host $latest ($hs B, $hm) differs from the node's view ($ns_ B, $nm)"; fi
    local node_names; node_names="$(node find "$bdir" -maxdepth 1 -name "$glob" -printf '%f\n' 2>&1 | sort)"
    if [[ "$node_names" == "$host_names" ]]; then pass "host ./backups and $bdir list the same $(wc -l <<<"$host_names" | tr -d ' ') snapshot(s)"; else fail "host and node snapshot lists differ"; fi
    if [[ "$(wc -l <<<"$host_names" | tr -d ' ')" -le "$keep" ]]; then pass "at most $keep snapshots kept (retention)"; else fail "more than $keep snapshots kept"; fi
    if [[ "$(node find "$bdir" -maxdepth 1 -name '.etcd-snapshot-*.tmp*' 2>&1)" == "" ]]; then pass "no half-written tmp snapshot left behind"; else fail "tmp snapshot left in $bdir"; fi
    local st; st="$(node etcdutl snapshot status "$bdir/$latest" --write-out=json 2>&1)"
    if jq -e '.revision > 0 and .totalKey > 0 and (.hash | type == "number")' >/dev/null 2>&1 <<<"$st"; then pass "etcdutl snapshot status OK for $latest (revision $(jq .revision <<<"$st"), $(jq .totalKey <<<"$st") keys)"
    else fail "etcdutl snapshot status failed for $latest: ${st:0:200}"; fi
  fi

  # --- Metric through node-exporter's textfile collector, staleness rule loaded and quiet
  local prom am q e m; prom="$(pinned_role monitoring monitoring_release)-prometheus:http-web"; am="$(pinned_role monitoring monitoring_release)-alertmanager:http-web"
  m=etcd_backup_last_success_timestamp_seconds
  qprom() { svc_get "$ns" "$prom" "api/v1/query?query=$(jq -rn --arg q "$1" '$q|@uri')"; }
  local i age_p=""
  for i in $(seq 1 40); do
    q="$(qprom "time() - max($m)")"; age_p="$(jq -r '.data.result[0].value[1] // empty' 2>/dev/null <<<"$q")"
    [[ -n "$age_p" ]] && break; sleep 3
  done
  if [[ -n "$age_p" ]] && awk -v a="$age_p" -v s="$stale" 'BEGIN{exit !(a >= -5 && a < s)}'; then pass "Prometheus scrapes $m (last success ${age_p%.*}s ago, textfile collector works)"
  else fail "Prometheus has no fresh $m (age '${age_p:-none}'): is node-exporter reading the textfile directory?"; fi
  # A new rule file takes a config-reloader cycle to load and one evaluation to leave health "unknown".
  local rules
  for i in $(seq 1 60); do
    rules="$(svc_get "$ns" "$prom" api/v1/rules)"
    jq -e '[.data.groups[].rules[] | select(.type == "alerting" and .name == "EtcdBackupStale" and .health != "unknown")] | length == 1' >/dev/null 2>&1 <<<"$rules" && break
    sleep 3
  done
  e="$(jq -r --arg r "EtcdBackupStale" '[.data.groups[].rules[] | select(.type == "alerting" and .name == $r)][0] | .query // empty' <<<"$rules" 2>/dev/null)"
  if [[ -n "$e" ]]; then pass "alert rule EtcdBackupStale loaded in Prometheus"; else fail "alert rule EtcdBackupStale not loaded"; fi
  if jq -e '[.data.groups[].rules[] | select(.type == "alerting" and .name == "EtcdBackupStale")][0] | .health == "ok" and .state == "inactive"' >/dev/null 2>&1 <<<"$rules"; then
    pass "EtcdBackupStale is healthy and not firing"
  else fail "EtcdBackupStale is not healthy/inactive"; fi
  if [[ "$(svc_get "$ns" "$am" api/v2/alerts | jq -r '[.[] | select(.labels.alertname == "EtcdBackupStale")] | length' 2>/dev/null)" == "0" ]]; then pass "no EtcdBackupStale alert in Alertmanager"
  else fail "EtcdBackupStale is present in Alertmanager (or Alertmanager unreachable)"; fi
  # The rule's own expression: quiet now, and it yields a sample on both failure modes (stale threshold crossed, metric absent).
  if [[ -n "$e" ]]; then
    local stale_expr absent_expr
    stale_expr="$(sed -E 's/> [0-9]+\)/> 0)/' <<<"$e")"; absent_expr="${e//$m/etcd_backup_never_exported}"
    if [[ "$(qprom "$e" | jq -r '.data.result | length' 2>/dev/null)" == "0" ]]; then pass "rule expression is empty while backups are fresh"; else fail "rule expression returns a sample although backups are fresh"; fi
    if [[ "$(qprom "$stale_expr" | jq -r '.data.result | length' 2>/dev/null)" =~ ^[1-9] ]]; then pass "rule expression fires once the snapshot is older than the threshold"; else fail "rule expression does not fire when stale"; fi
    if [[ "$(qprom "$absent_expr" | jq -r '.data.result | length' 2>/dev/null)" =~ ^[1-9] ]]; then pass "rule expression fires when the metric is absent"; else fail "rule expression does not fire when the metric is absent"; fi
  fi
}

# can-i answer ("yes"/"no") for the operator identity; arguments go to `kubectl auth can-i`.
cani_op() { kop auth can-i "$@" 2>/dev/null | tail -n 1; }

check_8a() { # read-only operator role + operator kubeconfig (M8)
  CURRENT_REQ=8a
  need_cluster || return 0
  if ! command -v jq >/dev/null 2>&1; then fail "jq is required on the host for check_8a"; return 0; fi
  if [[ ! -f "$KUBECONFIG_OPERATOR" ]]; then fail "${KUBECONFIG_OPERATOR#"$ROOT"/} missing (run: make provision TAGS=hardening)"; return 0; fi
  local role="$ROOT/ansible/roles/hardening/defaults/main.yml" user group crole renew
  user="$(sed -n 's/^hardening_operator_user:[[:space:]]*\([a-z]*\).*/\1/p' "$role")"
  group="$(sed -n 's/^hardening_operator_group:[[:space:]]*"\([^"]*\)".*/\1/p' "$role")"
  crole="$(sed -n 's/^hardening_clusterrole:[[:space:]]*\([a-z-]*\).*/\1/p' "$role")"
  renew="$(sed -n 's/^hardening_cert_renew_days:[[:space:]]*\([0-9]*\).*/\1/p' "$role")"
  if [[ -z "$user" || -z "$group" || -z "$crole" || -z "$renew" ]]; then fail "hardening defaults not found"; return 0; fi

  # --- credentials on the host
  local fmode f
  for f in "$KUBECONFIG_OPERATOR" "$ROOT/.secrets/operator.key"; do
    fmode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)"
    if [[ "$fmode" == 600 ]]; then pass "${f#"$ROOT"/} is mode 0600"; else fail "${f#"$ROOT"/} mode is '$fmode', want 600"; fi
  done
  local server; server="$(kop config view -o jsonpath='{.clusters[0].cluster.server}' 2>&1)"
  if [[ "$server" == "https://127.0.0.1:6443" ]]; then pass "operator kubeconfig server is the Lima forward $server"; else fail "operator kubeconfig server is '$server'"; fi
  local cert; cert="$(kop config view --raw -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null | base64 -d 2>/dev/null)"
  if [[ -z "$cert" ]]; then fail "operator kubeconfig has no client certificate"; else
    local subj; subj="$(openssl x509 -noout -subject -nameopt multiline <<<"$cert" 2>&1)"
    if grep -Eq "commonName[[:space:]]+= $user\$" <<<"$subj" && grep -Eq "organizationName[[:space:]]+= $group\$" <<<"$subj"; then pass "client cert subject is CN=$user, O=$group"; else fail "client cert subject unexpected: $subj"; fi
    if openssl x509 -noout -checkend 0 <<<"$cert" >/dev/null 2>&1; then pass "client cert is not expired ($(openssl x509 -noout -enddate <<<"$cert" 2>&1))"; else fail "client cert is expired"; fi
    if openssl x509 -noout -checkend $((renew * 86400)) <<<"$cert" >/dev/null 2>&1; then pass "client cert is outside the ${renew}-day renewal window"; else fail "client cert expires within ${renew} days (run: make provision TAGS=hardening)"; fi
    if grep -q "kubeadm:cluster-admins\|system:masters" <<<"$subj"; then fail "client cert carries an admin group"; else pass "client cert carries no admin group"; fi
  fi

  # --- identity as the API server sees it
  local who uname groups
  who="$(kop auth whoami -o json 2>&1)"
  uname="$(jq -r '.status.userInfo.username // empty' <<<"$who" 2>/dev/null)"
  groups="$(jq -r '.status.userInfo.groups[]? // empty' <<<"$who" 2>/dev/null)"
  if [[ "$uname" == "$user" ]]; then pass "whoami: username is $user"; else fail "whoami: username is '$uname' ($who)"; fi
  if grep -qx "$group" <<<"$groups"; then pass "whoami: member of $group"; else fail "whoami: groups are '$(tr '\n' ' ' <<<"$groups")'"; fi
  if grep -Eqx 'system:masters|kubeadm:cluster-admins' <<<"$groups"; then fail "whoami: member of an admin group"; else pass "whoami: not in system:masters or kubeadm:cluster-admins"; fi

  # --- the role itself (admin view): get/list/watch only, no wildcards, no secrets, bound only by our group
  local rj rbad
  rj="$(k get clusterrole "$crole" -o json 2>&1)"
  rbad="$(jq -r '[.rules[] | select((.verbs - ["get","list","watch"]) | length > 0)] | length' <<<"$rj" 2>/dev/null)"
  if [[ "$rbad" == 0 ]]; then pass "ClusterRole $crole grants only get/list/watch"; else fail "ClusterRole $crole has '$rbad' rules with other verbs"; fi
  rbad="$(jq -r '[.rules[] | select(((.resources // []) + (.apiGroups // []) + (.verbs // []) + (.nonResourceURLs // [])) | index("*"))] | length' <<<"$rj" 2>/dev/null)"
  if [[ "$rbad" == 0 ]]; then pass "ClusterRole $crole has no wildcards"; else fail "ClusterRole $crole has '$rbad' rules with wildcards"; fi
  rbad="$(jq -r '[.rules[] | select((.resources // []) | map(select(test("^(secrets|serviceaccounts/token|pods/(exec|attach|portforward|proxy)|.*/proxy|certificatesigningrequests/approval|signers)$"))) | length > 0)] | length' <<<"$rj" 2>/dev/null)"
  if [[ "$rbad" == 0 ]]; then pass "ClusterRole $crole lists no secrets, exec, attach, portforward, proxy, token or approval resources"; else fail "ClusterRole $crole lists '$rbad' dangerous rules"; fi
  local bj rbn rb
  bj="$(k get clusterrolebindings -o json 2>&1)"
  rbn="$(jq -r --arg u "$user" --arg g "$group" '[.items[] | select(any(.subjects[]?; (.kind == "User" and .name == $u) or (.kind == "Group" and .name == $g))) | .metadata.name + "->" + .roleRef.name] | sort | join(",")' <<<"$bj" 2>/dev/null)"
  if [[ "$rbn" == "$crole->$crole" ]]; then pass "only ClusterRoleBinding $crole binds $user / $group"; else fail "bindings for $user / $group: '$rbn'"; fi
  rb="$(k get rolebindings -A -o json 2>&1 | jq -r --arg u "$user" --arg g "$group" '[.items[] | select(any(.subjects[]?; (.kind == "User" and .name == $u) or (.kind == "Group" and .name == $g)))] | length' 2>/dev/null)"
  if [[ "$rb" == 0 ]]; then pass "no namespaced RoleBinding grants $user / $group more"; else fail "RoleBindings for $user / $group: '$rb'"; fi

  # --- allowed: day-to-day inspection
  local v r bad=""
  for r in pods nodes namespaces events services configmaps persistentvolumes persistentvolumeclaims serviceaccounts deployments.apps statefulsets.apps daemonsets.apps replicasets.apps jobs.batch cronjobs.batch \
    ingresses.networking.k8s.io networkpolicies.networking.k8s.io storageclasses.storage.k8s.io customresourcedefinitions.apiextensions.k8s.io clusterroles.rbac.authorization.k8s.io \
    certificates.cert-manager.io clusterissuers.cert-manager.io prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com; do
    for v in get list watch; do [[ "$(cani_op "$v" "$r" -A)" == yes ]] || bad="$bad $v/$r"; done
  done
  if [[ -z "$bad" ]]; then pass "can-i: get/list/watch on 25 inspection resources cluster-wide"; else fail "can-i: denied$bad"; fi
  if [[ "$(cani_op get pods --subresource=log -n kube-system)" == yes ]]; then pass "can-i: get pods/log (logs are readable, documented)"; else fail "can-i: pods/log denied"; fi

  # --- denied: secrets, cluster-wide and per namespace
  bad=""
  for v in get list watch; do
    [[ "$(cani_op "$v" secrets -A)" == no ]] || bad="$bad $v/-A"
    for r in kube-system monitoring llm cert-manager traefik default; do [[ "$(cani_op "$v" secrets -n "$r")" == no ]] || bad="$bad $v/$r"; done
  done
  if [[ -z "$bad" ]]; then pass "can-i: no get/list/watch on secrets (cluster-wide and in 6 namespaces)"; else fail "can-i: secrets readable:$bad"; fi

  # --- denied: every write verb on the resources an operator could abuse
  bad=""
  for r in pods deployments.apps statefulsets.apps daemonsets.apps jobs.batch namespaces nodes configmaps services serviceaccounts persistentvolumes ingresses.networking.k8s.io networkpolicies.networking.k8s.io \
    clusterroles.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io roles.rbac.authorization.k8s.io rolebindings.rbac.authorization.k8s.io \
    certificatesigningrequests.certificates.k8s.io customresourcedefinitions.apiextensions.k8s.io certificates.cert-manager.io prometheusrules.monitoring.coreos.com secrets; do
    for v in create update patch delete deletecollection; do [[ "$(cani_op "$v" "$r" -A)" == no ]] || bad="$bad $v/$r"; done
  done
  if [[ -z "$bad" ]]; then pass "can-i: no create/update/patch/delete/deletecollection on 21 resource kinds"; else fail "can-i: writable:$bad"; fi
  bad=""
  [[ "$(cani_op '*' '*' -A)" == no ]] || bad="$bad */*"
  for r in exec attach portforward proxy; do [[ "$(cani_op create pods --subresource="$r" -n kube-system)" == no ]] || bad="$bad pods/$r"; done
  for r in get create; do
    [[ "$(cani_op "$r" pods --subresource=proxy -n kube-system)" == no ]] || bad="$bad $r:pods/proxy"
    [[ "$(cani_op "$r" nodes --subresource=proxy)" == no ]] || bad="$bad $r:nodes/proxy"
    [[ "$(cani_op "$r" services --subresource=proxy -n kube-system)" == no ]] || bad="$bad $r:services/proxy"
  done
  [[ "$(cani_op update pods --subresource=ephemeralcontainers -n kube-system)" == no ]] || bad="$bad pods/ephemeralcontainers"
  [[ "$(cani_op create pods --subresource=eviction -n kube-system)" == no ]] || bad="$bad pods/eviction"
  [[ "$(cani_op create serviceaccounts --subresource=token -n kube-system)" == no ]] || bad="$bad serviceaccounts/token"
  [[ "$(cani_op update nodes --subresource=status)" == no ]] || bad="$bad nodes/status"
  for r in users groups serviceaccounts uids; do [[ "$(cani_op impersonate "$r")" == no ]] || bad="$bad impersonate/$r"; done
  for v in escalate bind; do
    for r in clusterroles.rbac.authorization.k8s.io roles.rbac.authorization.k8s.io; do [[ "$(cani_op "$v" "$r")" == no ]] || bad="$bad $v/$r"; done
  done
  [[ "$(cani_op update certificatesigningrequests --subresource=approval)" == no ]] || bad="$bad csr/approval"
  [[ "$(cani_op approve signers.certificates.k8s.io)" == no ]] || bad="$bad csr/approve-signer"
  [[ "$(cani_op sign signers.certificates.k8s.io)" == no ]] || bad="$bad csr/sign-signer"
  if [[ -z "$bad" ]]; then pass "can-i: no */*, exec/attach/portforward/proxy, token, impersonate, escalate/bind, CSR approve/sign, eviction"; else fail "can-i: allowed:$bad"; fi

  # --- what system:authenticated adds (Calico's passthrough binding, system:basic-user) must not be a write path
  local rules unexpected
  rules="$(kop auth can-i --list 2>&1)"
  unexpected="$(awk 'NR > 1 { v = $0; sub(/^[^[]*\[[^]]*\][[:space:]]+\[[^]]*\][[:space:]]+/, "", v); if (v ~ /(create|update|patch|delete|\*|impersonate|escalate|bind|approve|sign)/) print $1 }' <<<"$rules" |
    grep -Ev '^(selfsubject(access|rules)?reviews\.(authentication|authorization)\.k8s\.io|(globalnetworkpolicies|networkpolicies|stagedglobalnetworkpolicies|stagednetworkpolicies)\.projectcalico\.org)$')"
  if [[ -z "$unexpected" ]]; then pass "can-i --list: write verbs only on self-reviews (system:basic-user) and Calico policies (calico-tiered-policy-passthrough)"; else fail "can-i --list: unexpected write rules: $(tr '\n' ' ' <<<"$unexpected")"; fi
  if [[ "$(cani_op get tiers.projectcalico.org)" == no ]]; then pass "operator cannot get Calico tiers, so Calico's passthrough grant is not a write path"; else fail "operator can get Calico tiers: policy writes would go through"; fi

  # --- real requests, not just SelfSubjectAccessReviews
  local out apipod="kube-apiserver-$NODE_NAME"
  if out="$(kop get nodes -o name 2>&1)" && [[ "$out" == "node/$NODE_NAME" ]]; then pass "kubectl get nodes works as $user"; else fail "get nodes as $user failed: $out"; fi
  if out="$(kop get pods -A -o name 2>&1)" && [[ -n "$out" ]]; then pass "kubectl get pods -A works as $user ($(wc -l <<<"$out" | tr -d ' ') pods)"; else fail "get pods -A as $user failed: $out"; fi
  if out="$(kop logs -n kube-system "$apipod" --tail=1 2>&1)" && [[ "$out" != *orbidden* ]]; then pass "kubectl logs works as $user"; else fail "logs as $user failed: $out"; fi
  expect_forbidden() { # <label> <command...>: the API server must answer Forbidden
    local label="$1" o; shift
    if o="$("$@" 2>&1)"; then fail "$label: succeeded as $user: $o"
    elif [[ "$o" == *[Ff]orbidden* ]]; then pass "$label: Forbidden"
    else fail "$label: failed, but not Forbidden: $o"; fi
  }
  expect_forbidden "get secrets -n kube-system" kop get secrets -n kube-system
  expect_forbidden "get secrets -A" kop get secrets -A
  expect_forbidden "create configmap (dry-run=server)" kop create configmap verify-8a --dry-run=server -n default
  expect_forbidden "delete configmap (dry-run=server)" kop delete configmap kube-root-ca.crt --dry-run=server -n default
  expect_forbidden "label node (dry-run=server)" kop label node "$NODE_NAME" verify-8a=1 --overwrite --dry-run=server
  expect_forbidden "scale coredns (dry-run=server)" kop scale deployment coredns -n kube-system --replicas=1 --dry-run=server
  expect_forbidden "exec in the apiserver pod" kop exec -n kube-system "$apipod" -- true
  expect_forbidden "create token for default SA" kop create token default -n default
  expect_forbidden "Calico NetworkPolicy create (dry-run=server)" kop create --dry-run=server -f - <<'YAML'
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata: {name: verify-8a, namespace: default}
spec: {selector: all(), types: [Ingress]}
YAML
  # Nothing may have been created by the probes above.
  if k get configmap verify-8a -n default >/dev/null 2>&1 || k get node "$NODE_NAME" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q verify-8a; then fail "a write probe left an object behind"; else pass "no write probe left an object behind"; fi
}

check_8b() { # app workloads cannot run as root / privileged: PSA restricted on app namespaces (M9)
  need_cluster || return 0
  if ! llm_vars; then fail "llm_app defaults / versions not found"; return 0; fi
  local ns="$LLM_NS" mode label out

  for mode in enforce audit warn; do
    label="$(k get namespaces "$ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode}" 2>&1)"
    if [[ "$label" == "restricted" ]]; then pass "$ns PSA $mode=restricted"; else fail "$ns PSA $mode='$label'"; fi
    label="$(k get namespaces "$ns" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$mode-version}" 2>&1)"
    if [[ "$label" == "$LLM_PSA_VERSION" ]]; then pass "$ns PSA $mode-version pinned to $LLM_PSA_VERSION"; else fail "$ns PSA $mode-version='$label' (want $LLM_PSA_VERSION)"; fi
  done

  # --- the API server rejects root / privileged / host pods in the namespace (server-side dry run: nothing is created)
  pod_yaml() { # <name> <extra pod-spec line, may be empty> <container securityContext>
    cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $ns}
spec:
  automountServiceAccountToken: false
  $2
  containers:
    - name: c
      image: $LLM_IMAGE
      command: [sleep, "1"]
      securityContext: $3
MANIFEST
  }
  local good='{allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 10001, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}'
  out="$(pod_yaml verify-8b-ok '' "$good" | k apply --dry-run=server -f - 2>&1)"
  if [[ "$out" == *"created (server dry run)"* ]]; then pass "control: a compliant pod is accepted in $ns (dry-run)"; else fail "control pod rejected in $ns: ${out:0:300}"; fi
  local label_case label spec sc want
  for label_case in \
    "root user||{allowPrivilegeEscalation: false, runAsUser: 0, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}|runAsNonRoot" \
    "no securityContext||{}|allowPrivilegeEscalation" \
    "privileged||{privileged: true, allowPrivilegeEscalation: true, runAsNonRoot: true, runAsUser: 10001, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}|privileged" \
    "added capability||{allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 10001, capabilities: {drop: [ALL], add: [SYS_ADMIN]}, seccompProfile: {type: RuntimeDefault}}|capabilities" \
    "hostNetwork|hostNetwork: true|$good|hostNetwork" \
    "hostPath volume|volumes: [{name: h, hostPath: {path: /}}]|$good|hostPath"; do
    IFS='|' read -r label spec sc want <<<"$label_case"
    out="$(pod_yaml verify-8b-bad "$spec" "$sc" | k apply --dry-run=server -f - 2>&1)"
    if [[ "$out" == *"violates PodSecurity \"restricted:$LLM_PSA_VERSION\""* && "$out" == *"$want"* ]]; then pass "$label pod rejected in $ns by PSA restricted:$LLM_PSA_VERSION ($want)"
    else fail "$label pod not rejected as expected in $ns: ${out:0:300}"; fi
  done

  # --- every running container (init included) complies; effective UID proven inside the container
  local pods; pods="$(k get pods -n "$ns" -o json 2>&1)"
  if ! jq -e '.items | length > 0' >/dev/null 2>&1 <<<"$pods"; then fail "no pods in $ns: ${pods:0:200}"; return 0; fi
  local bad
  bad="$(jq -r '.items[] | . as $p | ($p.spec.securityContext // {}) as $ps
    | (($p.spec.containers // []) + ($p.spec.initContainers // []))[] | (.securityContext // {}) as $cs
    | select(
        ($cs.privileged == true) or ($p.spec.hostNetwork == true) or ($p.spec.hostPID == true) or ($p.spec.hostIPC == true)
        or (($cs.runAsNonRoot // $ps.runAsNonRoot) != true)
        or (($cs.runAsUser // $ps.runAsUser // 0) == 0)
        or ($cs.allowPrivilegeEscalation != false)
        or (($cs.capabilities.drop // []) != ["ALL"]) or (($cs.capabilities.add // []) != [])
        or ((($cs.seccompProfile // $ps.seccompProfile // {}).type) != "RuntimeDefault")
        or ($cs.readOnlyRootFilesystem != true)
      ) | "\($p.metadata.name)/\(.name)"' <<<"$pods" | tr '\n' ' ')"
  local n; n="$(jq -r '[.items[] | (.spec.containers + (.spec.initContainers // []))[]] | length' <<<"$pods")"
  if [[ -z "$bad" ]]; then pass "all $n containers in $ns: non-root, no privilege escalation, drop ALL, seccomp RuntimeDefault, read-only root, no host namespaces"; else fail "non-compliant containers: $bad"; fi
  bad="$(jq -r '.items[] | select(.spec.volumes[]? | .hostPath != null) | .metadata.name' <<<"$pods" | tr '\n' ' ')"
  if [[ -z "$bad" ]]; then pass "no pod in $ns mounts a hostPath"; else fail "hostPath volumes in: $bad"; fi
  bad="$(jq -r '.items[] | select((.status.qosClass == "BestEffort") or (.spec.automountServiceAccountToken != false)) | .metadata.name' <<<"$pods" | tr '\n' ' ')"
  if [[ -z "$bad" ]]; then pass "pods in $ns have resource requests and no ServiceAccount token mounted"; else fail "BestEffort or token-mounting pods: $bad"; fi
  local pod uid; pod="$(llm_pod)"
  uid="$(k exec -n "$ns" "$pod" -c llama-server -- id -u 2>&1)"
  if [[ "$uid" == "$LLM_UID" ]]; then pass "llama-server runs as UID $uid inside the container (not root)"; else fail "id -u in $pod: $uid"; fi
  out="$(k exec -n "$ns" "$pod" -c llama-server -- sh -c 'touch /app/x 2>&1; grep -i "^NoNewPrivs\|^Seccomp:" /proc/1/status' 2>&1 | tr '\n' ' ')"
  if [[ "$out" == *"Read-only file system"* && "$out" == *"NoNewPrivs:"*1* && "$out" == *"Seccomp:"*2* ]]; then pass "root filesystem is read-only; process has NoNewPrivs=1 and a seccomp filter"; else fail "runtime hardening: ${out:0:200}"; fi

  # --- images by digest: spec image and running imageID
  local res; res="$(images_unpinned "$ns" "$LLM_DIGEST")"
  if [[ "${res%% *}" -gt 0 && "$res" == "${res%% *} " ]]; then pass "all ${res%% *} containers in $ns run $LLM_IMAGE by digest (spec image and imageID)"; else fail "not digest-pinned: $res"; fi
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
  if ! llm_vars; then fail "llm_app defaults / versions not found"; return 0; fi
  local ns="$LLM_NS" out pod mf="$LLM_MODEL_DIR/$LLM_MODEL_FILE"

  out="$(k get deployments "$LLM_NAME" -n "$ns" -o jsonpath='{.spec.replicas} {.status.readyReplicas} {.spec.template.spec.containers[0].image}' 2>&1)"
  if [[ "$out" == "1 1 $LLM_IMAGE" ]]; then pass "Deployment $LLM_NAME: 1/1 ready, image $LLM_IMAGE"; else fail "Deployment: $out"; fi
  pod="$(llm_pod)"
  out="$(k get pod "$pod" -n "$ns" -o jsonpath='{.status.phase} {.status.containerStatuses[0].ready} {.status.containerStatuses[0].restartCount} {.spec.containers[0].startupProbe.httpGet.path} {.spec.containers[0].readinessProbe.httpGet.path} {.spec.containers[0].livenessProbe.httpGet.path} {.spec.containers[0].resources.requests.memory} {.spec.containers[0].resources.limits.memory} {.spec.containers[0].resources.requests.cpu} {.spec.containers[0].resources.limits.cpu}' 2>&1)"
  if [[ "$out" =~ ^Running\ true\ 0\ /health\ /health\ /health\ [0-9]+Mi\ [0-9]+Mi\ [0-9]+\ [0-9]+$ ]]; then pass "pod $pod Running, 0 restarts, /health startup+readiness+liveness probes, CPU and memory requests+limits ($out)"; else fail "pod state: $out"; fi
  out="$(k get pvc "$LLM_MODEL_PVC" -n "$ns" -o jsonpath='{.status.phase} {.spec.storageClassName}' 2>&1)"
  if [[ "$out" == "Bound local-path" ]]; then pass "model PVC $LLM_MODEL_PVC is Bound on the default StorageClass ($out)"; else fail "model PVC: $out"; fi

  # --- TLS: certificate from the internal CA with the shared duration/renewBefore, Ingress through Traefik
  out="$(k get certificates "$LLM_TLS_SECRET" -n "$ns" -o jsonpath='{.spec.issuerRef.name} {.spec.duration} {.spec.renewBefore} {.spec.dnsNames[*]} {.status.conditions[?(@.type=="Ready")].status}' 2>&1)"
  if [[ "$out" == "$LLM_ISSUER $LLM_DURATION $LLM_RENEW $LLM_HOST True" ]]; then pass "Certificate $LLM_TLS_SECRET: $LLM_ISSUER, duration $LLM_DURATION, renewBefore $LLM_RENEW, $LLM_HOST, Ready"; else fail "Certificate: $out"; fi
  out="$(k get ingress "$LLM_NAME" -n "$ns" -o jsonpath='{.spec.rules[0].host} {.spec.tls[0].secretName} {.spec.rules[0].http.paths[0].backend.service.name}' 2>&1)"
  if [[ "$out" == "$LLM_HOST $LLM_TLS_SECRET $LLM_NAME" ]]; then pass "Ingress $LLM_NAME: $LLM_HOST -> Service $LLM_NAME, TLS secret $LLM_TLS_SECRET"; else fail "Ingress: $out"; fi

  # --- completion over TLS from the Mac, trusting only certs/ca.crt
  local body resp code content
  body='{"model":"'"$LLM_MODEL_ALIAS"'","messages":[{"role":"user","content":"Reply with one short greeting."}],"max_tokens":24,"temperature":0}'
  resp="$(llm_https -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}' "https://$LLM_HOST/v1/chat/completions" 2>&1)"
  code="${resp##*$'\n'}"
  content="$(jq -r '.choices[0].message.content // empty' <<<"${resp%$'\n'*}" 2>/dev/null)"
  if [[ "$code" == 200 && -n "$content" ]]; then pass "POST https://$LLM_HOST/v1/chat/completions (CA-verified TLS) returned a completion: ${content:0:60}"; else fail "chat completion (HTTP $code): ${resp:0:300}"; fi
  out="$(llm_https "https://$LLM_HOST/v1/models" 2>&1 | jq -r '.data[0].id // empty' 2>/dev/null)"
  if [[ "$out" == "$LLM_MODEL_ALIAS" ]]; then pass "/v1/models lists $out"; else fail "/v1/models: '$out'"; fi

  # --- the model file on the PVC: exact size and sha256
  local size sha inode0 mtime0
  size="$(k exec -n "$ns" "$pod" -c llama-server -- stat -c '%s' "$mf" 2>&1)"
  if [[ "$size" == "$LLM_MODEL_SIZE" ]]; then pass "model file $mf on the PVC is $size bytes (pinned size)"; else fail "model file size: $size (want $LLM_MODEL_SIZE)"; fi
  sha="$(k exec -n "$ns" "$pod" -c llama-server -- sha256sum "$mf" 2>&1 | awk '{print $1}')"
  if [[ "$sha" == "$LLM_MODEL_SHA" ]]; then pass "model file sha256 matches the pinned value"; else fail "model sha256: $sha"; fi
  out="$(k get pod "$pod" -n "$ns" -o jsonpath='{.spec.volumes[?(@.name=="model")].persistentVolumeClaim.claimName} {.spec.containers[0].volumeMounts[?(@.name=="model")].readOnly} {.spec.initContainers[0].name} {.spec.initContainers[0].volumeMounts[?(@.name=="model")].readOnly}' 2>&1)"
  if [[ "$out" == "$LLM_MODEL_PVC true verify-model true" ]]; then pass "the server pod mounts the model PVC read-only in both containers (the init container only verifies)"; else fail "model mount: $out"; fi
  out="$(k get jobs,pods -n "$ns" -l "app.kubernetes.io/component=$LLM_FETCH" -o name 2>&1)"
  if [[ -z "$out" ]]; then pass "no $LLM_FETCH Job or pod is left behind (Ansible deletes it after completion)"; else fail "leftover model-fetch objects: $out"; fi
  read -r inode0 mtime0 < <(k exec -n "$ns" "$pod" -c llama-server -- stat -c '%i %Y' "$mf" 2>&1)

  # --- restart: a new pod reuses the cached file, no download
  local uid0 newpod="" i ready
  uid0="$(k get pod "$pod" -n "$ns" -o jsonpath='{.metadata.uid}' 2>&1)"
  k delete pod "$pod" -n "$ns" --wait=true --timeout=120s >/dev/null 2>&1
  for i in $(seq 1 90); do
    newpod="$(llm_pod)"
    if [[ -n "$newpod" ]]; then
      ready="$(k get pod "$newpod" -n "$ns" -o jsonpath='{.metadata.uid} {.status.containerStatuses[0].ready}' 2>/dev/null)"
      [[ "$ready" == *" true" && "${ready%% *}" != "$uid0" ]] && break
    fi
    sleep 3
  done
  if [[ "$ready" == *" true" && "${ready%% *}" != "$uid0" ]]; then pass "pod deleted; replacement $newpod is Ready"; else fail "no Ready replacement pod after delete (last: $newpod '$ready')"; return 0; fi
  out="$(k logs "$newpod" -n "$ns" -c verify-model 2>&1)"
  if [[ "$out" == *"model verified"* && "$out" != *downloading* && "$out" != *"model downloaded"* ]]; then pass "init container after restart: model verified from the PVC, no download (${out:0:60})"; else fail "init container log: ${out:0:200}"; fi
  out="$(k get jobs,pods -n "$ns" -l "app.kubernetes.io/component=$LLM_FETCH" -o name 2>&1)"
  if [[ -z "$out" ]]; then pass "the restart started no $LLM_FETCH Job or pod (the server pod cannot download: no egress)"; else fail "restart created model-fetch objects: $out"; fi
  local ts; ts="$(k get pod "$newpod" -n "$ns" -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason} {.status.initContainerStatuses[0].state.terminated.startedAt} {.status.initContainerStatuses[0].state.terminated.finishedAt}' 2>&1)"
  local s e; read -r _ s e <<<"$ts"
  local dur=$(( $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$e" +%s 2>/dev/null || date -u -d "$e" +%s) - $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$s" +%s 2>/dev/null || date -u -d "$s" +%s) ))
  if [[ "$ts" == Completed* && $dur -lt 30 ]]; then pass "init container Completed in ${dur}s (checksum only)"; else fail "init container: $ts (${dur}s)"; fi
  local inode1 mtime1
  read -r inode1 mtime1 < <(k exec -n "$ns" "$newpod" -c llama-server -- stat -c '%i %Y' "$mf" 2>&1)
  if [[ "$inode1" == "$inode0" && "$mtime1" == "$mtime0" ]]; then pass "model file untouched across the restart (inode $inode1, mtime $mtime1)"; else fail "model file changed: inode $inode0 -> $inode1, mtime $mtime0 -> $mtime1"; fi
  for i in $(seq 1 20); do
    resp="$(llm_https -H 'Content-Type: application/json' -d "$body" -w '\n%{http_code}' "https://$LLM_HOST/v1/chat/completions" 2>&1)"; code="${resp##*$'\n'}"
    [[ "$code" == 200 ]] && break; sleep 3
  done
  content="$(jq -r '.choices[0].message.content // empty' <<<"${resp%$'\n'*}" 2>/dev/null)"
  if [[ "$code" == 200 && -n "$content" ]]; then pass "completion over TLS works again after the restart"; else fail "completion after restart (HTTP $code): ${resp:0:300}"; fi
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
