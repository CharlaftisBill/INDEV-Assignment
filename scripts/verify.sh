#!/usr/bin/env bash
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
  local want_tr_chart="traefik-$(pinned traefik_chart_version)"
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
    if grep -Eq "[:*]$p[[:space:]]" <<<"$listen"; then pass "node listens on :$p (Lima forwards it)"; else fail "nothing listens on :$p on the node"; fi
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
