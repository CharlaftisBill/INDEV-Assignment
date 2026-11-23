#!/usr/bin/env bash
# Use an existing Debian 13 VM over SSH instead of the Lima VM. Active only while external-vm.conf exists
# at the repo root (copy external-vm.conf.example); without it everything uses Lima as before.
#   scripts/external.sh enabled          exit 0 when external mode is on
#   scripts/external.sh check            verify SSH, sudo, Debian 13, python3, size, addresses (prints the reason when not)
#   scripts/external.sh reach            quiet check: exit 0 when the VM answers over SSH
#   scripts/external.sh run <cmd...>     run a command on the VM as root
#   scripts/external.sh shell            interactive root shell on the VM
#   scripts/external.sh tunnel start|stop|status   host 443/80/6443 -> VM 8443/8000/6443 (what Lima forwards), plus egress
#   scripts/external.sh egress start|stop|status|test   egress=host only: the VM's downloads go through the host
#   scripts/external.sh egress-mode      print host, proxy or direct
#   scripts/external.sh backups-pull [--scheduled]   copy new VM snapshots into ./backups/external (0600), keep the newest 48
#   scripts/external.sh backups-schedule start|stop|status   that pull every 30 min while the tunnel is up (B-063)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR="${TMPDIR:-/tmp}"
CONF="$ROOT/external-vm.conf"

die() { echo "external: $*" >&2; exit 1; }
get() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" | head -n 1 | sed 's/[[:space:]]*$//'; }

group_var() { awk -v k="$1:" '$1 == k {print $2; exit}' "$ROOT/ansible/group_vars/all/main.yml"; }

SOCK="${TMPDIR%/}/indev-k8s-ext-$(id -u).sock"   # ssh control socket (short path: unix sockets are limited to ~100 chars)
FWD_PID="${TMPDIR%/}/indev-k8s-ext-$(id -u).fwd.pid"
FWD_LOG="${TMPDIR%/}/indev-k8s-ext-$(id -u).fwd.log"
# ssh forwards 6443 directly and 443/80 to high loopback ports; loopback-forward.py serves 443/80 from there,
# accepting only local connections (macOS lets non-root bind <1024 only on the wildcard address, as Lima does).
FWD_HIGH_HTTPS=18443; FWD_HIGH_HTTP=18000
PY="$ROOT/.venv/bin/python3"; [[ -x "$PY" ]] || PY=python3

# egress=host: the VM has no internet. Its own SSH session maps the VM's 127.0.0.1:EGRESS_PORT (-R) to
# egress-proxy.py on the host, which relays HTTPS to the hosts in egress-allowlist.txt only. Own control socket,
# so provisioning does not need host ports 443/80/6443.
EGRESS_PORT=18128   # same on both ends; must match vm_egress_port in ansible/inventory/external.yml
EG_SOCK="${TMPDIR%/}/indev-k8s-ext-$(id -u).egress.sock"
EG_PID="${TMPDIR%/}/indev-k8s-ext-$(id -u).egress.pid"
EG_LOG="${TMPDIR%/}/indev-k8s-ext-$(id -u).egress.log"
# B-063: requirement 7 wants snapshots off the node on a schedule. The VM may be air-gapped and cannot reach this host,
# so this host pulls them every 30 min, from a background loop that starts and stops with the tunnel. Not launchd or
# systemd: macOS keeps launchd jobs out of ~/Desktop, ~/Documents and ~/Downloads (TCC), where a clone often lives.
PULL_PID="${TMPDIR%/}/indev-k8s-ext-$(id -u).pull.pid"
PULL_LOG="$ROOT/.cache/backups-pull.log"
PULL_EVERY=1800
PULL_DIR="$ROOT/backups/external"   # B-069: own folder; ./backups itself is Lima's (shared mount, own retention)
SNAP_RE='^etcd-snapshot-[0-9]{8}T[0-9]{6}Z\.db$'   # the names etcd-backup.sh writes; nothing else is copied (B-070)

alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
# -O commands only talk to the control socket; the host argument is a placeholder until the conf is read.
TARGET=indev-ext
ssh_up() { ssh -S "$1" -O check "$TARGET" >/dev/null 2>&1; }
ssh_stop() { if ssh_up "$1"; then ssh -S "$1" -O exit "$TARGET" >/dev/null 2>&1 || true; fi; rm -f "$1"; }
proc_stop() { if alive "$1"; then kill "$(cat "$1")" 2>/dev/null || true; fi; rm -f "$1"; }
tunnel_up() { ssh_up "$SOCK" && alive "$FWD_PID"; }
tunnel_stop() { ssh_stop "$SOCK"; proc_stop "$FWD_PID"; }
# B-068: the loop leads its own process group, so stopping it also stops a pull in flight (ssh, tar); wait for all of it.
pull_stop() {
  if alive "$PULL_PID"; then
    local g; g="$(cat "$PULL_PID")"; kill -TERM -- "-$g" 2>/dev/null || true
    local i=0; while pgrep -g "$g" >/dev/null 2>&1 && (( i < 20 )); do sleep 0.5; i=$((i + 1)); done
    kill -KILL -- "-$g" 2>/dev/null || true
  fi
  rm -f "$PULL_PID"
}
egress_up() { ssh_up "$EG_SOCK" && alive "$EG_PID"; }
egress_stop() { ssh_stop "$EG_SOCK"; proc_stop "$EG_PID"; }
[[ "${1:-}" == enabled ]] && { [[ -f "$CONF" ]]; exit; }
# Work without external-vm.conf: removing the schedule, and a scheduled run after going back to Lima (nothing to pull).
case "${1:-} ${2:-}" in
  "backups-pull --scheduled") [[ -f "$CONF" ]] || exit 0 ;;
  "backups-schedule status") if alive "$PULL_PID"; then echo "pull loop (pid $(cat "$PULL_PID")), every $((PULL_EVERY / 60)) min"; exit 0; else echo "no scheduled pull"; exit 1; fi ;;
  "backups-schedule stop") pull_stop; exit 0 ;;
  # B-064: going back to Lima means deleting the conf; a tunnel left from before must still stop.
  "tunnel stop" | "egress stop") [[ -f "$CONF" ]] || {
    pull_stop
    if ssh_up "$EG_SOCK" || alive "$EG_PID"; then egress_stop; echo "egress stopped"; fi
    if ssh_up "$SOCK" || alive "$FWD_PID"; then tunnel_stop; echo "tunnel stopped"; else echo "tunnel not running"; fi
    exit 0; } ;;
  "tunnel running") ssh_up "$SOCK" || alive "$FWD_PID" || ssh_up "$EG_SOCK" || alive "$EG_PID" || alive "$PULL_PID"; exit ;;
esac
[[ -f "$CONF" ]] || die "no external-vm.conf (copy external-vm.conf.example); the Lima VM is used instead"

HOST="$(get host)"; USER_="$(get user)"; PORT="$(get port)"; KEY="$(get ssh_key)"; BDIR="$(get backup_dir)"
EGRESS="$(get egress)"; PROXY="$(get proxy)"
PORT="${PORT:-22}"; BDIR="${BDIR:-/var/backups/etcd}"; EGRESS="${EGRESS:-host}"
[[ -n "$HOST" && -n "$USER_" ]] || die "external-vm.conf needs host= and user="
[[ "$PORT" =~ ^[0-9]+$ ]] || die "external-vm.conf: port= must be a number"
[[ "$BDIR" == /* ]] || die "external-vm.conf: backup_dir= must be an absolute path"
case "$EGRESS" in
  host | direct) ;;
  proxy) [[ "$PROXY" =~ ^https?://[^[:space:]]+$ ]] || die "external-vm.conf: egress=proxy needs proxy=http://<host>:<port>" ;;
  *) die "external-vm.conf: egress= must be host, proxy or direct" ;;
esac

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p "$PORT")
[[ -n "$KEY" ]] && SSH+=(-i "$KEY" -o IdentitiesOnly=yes)
TARGET="$USER_@$HOST"
# root logs in as root: no sudo needed (a minimal Debian may not even have it).
if [[ "$USER_" == root ]]; then SUDO=""; else SUDO="sudo -n "; fi

# Arguments are re-quoted so the remote shell sees them exactly as given.
run() { "${SSH[@]}" "$TARGET" "$SUDO$(printf '%q ' "$@")"; }

pull_start() {
  alive "$PULL_PID" && return 0
  mkdir -p "$(dirname "$PULL_LOG")"
  # Detached loop in its own process group (job control on: a background job gets pgid = its pid); pull_stop kills the group.
  set -m
  # shellcheck disable=SC2016  # $0/$1 belong to the inner shell
  nohup /bin/bash -c 'while :; do "$0" backups-pull --scheduled; sleep "$1"; done' "$ROOT/scripts/external.sh" "$PULL_EVERY" \
    >>"$PULL_LOG" 2>&1 </dev/null &
  echo $! >"$PULL_PID"
  set +m
  echo "snapshot pull every $((PULL_EVERY / 60)) min into ./backups/external (log: .cache/backups-pull.log)"
}
egress_start() {
  [[ "$EGRESS" == host ]] || return 0
  egress_up && return 0
  egress_stop
  "$PY" -I "$ROOT/scripts/egress-proxy.py" "$EG_PID" "$EG_LOG" "$EGRESS_PORT" "$ROOT/scripts/egress-allowlist.txt" \
    || die "could not start the egress proxy on host 127.0.0.1:$EGRESS_PORT (port in use?)"
  "${SSH[@]}" -f -N -M -S "$EG_SOCK" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -R "127.0.0.1:$EGRESS_PORT:127.0.0.1:$EGRESS_PORT" "$TARGET" \
    || { egress_stop; die "could not open the egress tunnel: the VM's sshd must allow forwarding (AllowTcpForwarding yes) and port $EGRESS_PORT must be free there"; }
  echo "egress up: VM 127.0.0.1:$EGRESS_PORT -> host proxy (allowlist: scripts/egress-allowlist.txt, log: $EG_LOG)"
}

# ip_in_cidr IP CIDR: exit 0 when IP is inside CIDR (IPv4 only).
ip_int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
ip_in_cidr() {
  local net="${2%/*}" bits="${2#*/}" mask
  mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  (( ($(ip_int "$1") & mask) == ($(ip_int "$net") & mask) ))
}
case "${1:-}" in
  backup-dir) echo "$BDIR" ;;
  reach) "${SSH[@]}" "$TARGET" true >/dev/null 2>&1 ;;
  check)
    "${SSH[@]}" "$TARGET" true 2>/dev/null || die "cannot ssh to $TARGET:$PORT with keys (BatchMode); check host/user/port/ssh_key"
    run true 2>/dev/null || die "$USER_ needs passwordless sudo on the VM (see docs/install.md#your-own-debian-13-vm-over-ssh-instead-of-lima)"
    # shellcheck disable=SC2016  # expanded on the VM, not here
    facts="$("${SSH[@]}" "$TARGET" '. /etc/os-release; echo "$ID $VERSION_ID"; command -v python3 || echo none
      nproc; awk "/MemTotal/ {print int(\$2/1024)}" /proc/meminfo; df -Pm / | awk "NR==2 {print \$4}"
      ip -4 route get 1.1.1.1 2>/dev/null | sed -n "s/.* src \([0-9.]*\).*/\1/p"')"
    { read -r os_id os_ver; read -r py; read -r cpus; read -r mem_mb; read -r free_mb; read -r ip; } <<<"$facts"
    [[ "$os_id $os_ver" == "debian 13" ]] || die "the VM runs '$os_id $os_ver', this project needs Debian 13"
    [[ "$py" != none ]] || die "python3 is missing on the VM (Ansible needs it): sudo apt-get install -y python3"
    (( cpus >= 4 )) || die "the VM has $cpus CPUs, needs 4"
    (( mem_mb >= 7500 )) || die "the VM has ${mem_mb} MiB RAM, needs 8 GiB"
    (( free_mb >= 20000 )) || die "the VM has ${free_mb} MiB free on /, needs ~20 GiB (images, model, Prometheus)"
    [[ -n "$ip" ]] || die "the VM has no IPv4 default route: kubeadm needs one, even without internet (any gateway on its network will do)"
    for c in "$(group_var pod_cidr)" "$(group_var service_cidr)"; do
      ! ip_in_cidr "$ip" "$c" || die "the VM's address $ip is inside the cluster range $c; change pod_cidr/service_cidr in ansible/group_vars/all/main.yml"
    done
    echo "external VM $TARGET: SSH ok, $([[ -n "$SUDO" ]] && echo "sudo ok" || echo root), Debian 13, python3, $cpus CPU, ${mem_mb} MiB RAM, ${free_mb} MiB free, node IP $ip, egress=$EGRESS" ;;
  egress-mode) echo "$EGRESS" ;;
  egress)
    case "${2:-}" in
      start) egress_start ;;
      stop) if egress_up || alive "$EG_PID"; then egress_stop; echo "egress stopped"; fi ;;
      status) [[ "$EGRESS" != host ]] && { echo "egress=$EGRESS (no host proxy)"; exit 0; }; if egress_up; then echo "up"; else echo "down"; exit 1; fi ;;
      test)  # can the VM fetch a pinned source the way apt and containerd will?
        case "$EGRESS" in host) url="http://127.0.0.1:$EGRESS_PORT" ;; proxy) url="$PROXY" ;; direct) url="" ;; esac
        run python3 -c 'import sys, urllib.request as u
h = {"https": sys.argv[1]} if sys.argv[1] else {}
u.build_opener(u.ProxyHandler(h)).open("https://deb.debian.org/debian/dists/trixie/Release", timeout=20).read(1)' "$url" 2>/dev/null \
          || die "the VM cannot reach deb.debian.org with egress=$EGRESS${url:+ (via $url)}; see docs/install.md#internet-access-from-the-vm"
        echo "egress=$EGRESS: the VM reaches the internet${url:+ through $url}" ;;
      *) die "usage: egress start|stop|status|test" ;;
    esac ;;
  run) shift; run "$@" ;;
  shell) if [[ -n "$SUDO" ]]; then exec "${SSH[@]}" -t "$TARGET" sudo -i; else exec "${SSH[@]}" -t "$TARGET"; fi ;;
  tunnel)
    case "${2:-}" in
      start)
        egress_start
        pull_start
        if tunnel_up; then exit 0; fi
        tunnel_stop
        "${SSH[@]}" -f -N -M -S "$SOCK" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
          -L "127.0.0.1:$FWD_HIGH_HTTPS:127.0.0.1:8443" -L "127.0.0.1:$FWD_HIGH_HTTP:127.0.0.1:8000" \
          -L 127.0.0.1:6443:127.0.0.1:6443 "$TARGET" \
          || die "could not open the SSH tunnel: is host port 6443, $FWD_HIGH_HTTPS or $FWD_HIGH_HTTP in use (a running Lima VM 'k8s': limactl stop k8s)?"
        "$PY" -I "$ROOT/scripts/loopback-forward.py" "$FWD_PID" "$FWD_LOG" "443:$FWD_HIGH_HTTPS" "80:$FWD_HIGH_HTTP" \
          || { tunnel_stop; die "could not listen on host 443/80: in use (a running Lima VM 'k8s': limactl stop k8s)? Linux: make deps sets ip_unprivileged_port_start"; }
        echo "tunnel up: host 443/80/6443 -> $HOST (local connections only; make tunnel-stop closes it)" ;;
      stop)
        if alive "$PULL_PID"; then pull_stop; echo "snapshot pull stopped"; fi
        if egress_up || alive "$EG_PID"; then egress_stop; echo "egress stopped"; fi
        if ssh_up "$SOCK" || alive "$FWD_PID"; then tunnel_stop; echo "tunnel stopped"; else echo "tunnel not running"; fi ;;
      status) if tunnel_up && { [[ "$EGRESS" != host ]] || egress_up; }; then echo "up"; else echo "down"; exit 1; fi ;;
      running) ssh_up "$SOCK" || alive "$FWD_PID" || ssh_up "$EG_SOCK" || alive "$EG_PID" || alive "$PULL_PID" ;;  # any part left, for uninstall
      *) die "usage: tunnel start|stop|status|running" ;;
    esac ;;
  backups-pull)
    [[ "${2:-}" == --scheduled ]] && printf '%s ' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    keep="$(group_var etcd_backup_retention)"; keep="${keep:-48}"
    mkdir -p "$PULL_DIR"; chmod 700 "$PULL_DIR"
    # Snapshots hold every Secret: read as root on the VM, streamed over SSH, never printed. Only names matching
    # SNAP_RE and not yet here are fetched (B-067, B-070): a name with a newline splits into lines that match nothing.
    want=(); while IFS= read -r f; do
      [[ "$f" =~ $SNAP_RE && ! -e "$PULL_DIR/$f" ]] && want+=("$f")
    done < <(run find "$BDIR" -maxdepth 1 -type f -name 'etcd-snapshot-*.db' -printf '%f\n' | sort | tail -n "$keep")
    n=0
    if (( ${#want[@]} > 0 )); then
      tmp="$(mktemp -d "$PULL_DIR/.pull.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
      run tar -C "$BDIR" -cf - -- "${want[@]}" | tar -C "$tmp" -xf -
      for f in "${want[@]}"; do
        [[ -f "$tmp/$f" && ! -L "$tmp/$f" ]] || continue; chmod 600 "$tmp/$f"; mv -f "$tmp/$f" "$PULL_DIR/$f"; n=$((n + 1))
      done
    fi
    # Same retention as on the VM: the newest $keep by name. A glob, never a newline-split list (B-070).
    shopt -s nullglob; all=("$PULL_DIR"/etcd-snapshot-*.db); shopt -u nullglob
    drop=$(( ${#all[@]} - keep )); i=0; while (( i < drop )); do rm -f -- "${all[$i]}"; i=$((i + 1)); done
    echo "pulled $n new snapshot(s) from $TARGET:$BDIR into backups/external/ (keeping the newest $keep)" ;;
  backups-schedule)
    case "${2:-}" in
      start) pull_start ;;
      *) die "usage: backups-schedule start|stop|status" ;;
    esac ;;
  *) die "usage: $0 enabled|check|reach|run|shell|backup-dir|egress-mode|egress|tunnel|backups-pull|backups-schedule" ;;
esac
