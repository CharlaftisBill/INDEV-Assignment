#!/usr/bin/env bash
# Reviewer dry run: what a reviewer with their own air-gapped Debian 13 VM does, from nothing.
# A stand-in VM (separate Lima instance, no forwards or mounts, a firewall that drops everything leaving it
# except SSH replies and NTP), a fresh clone of REF from origin, external-vm.conf, then
# `make deps && make e2e KEEP_VM=1` in a real terminal (the CA prompt is answered "n"), then `make smoke`.
#   scripts/reviewer-dryrun.sh start [REF]   rebuild VM + clone, run detached (default REF: main); 15-30 min
#   scripts/reviewer-dryrun.sh wait          block up to 9 min; exit 0 PASS, 1 FAIL, 3 still running
#   scripts/reviewer-dryrun.sh status        same summary, no waiting
#   scripts/reviewer-dryrun.sh cleanup       stop the clone's tunnel, delete the VM and the work folder
# Needs: the hosts entry (scripts/hosts-entry.sh --apply, sudo) and free host ports 443/80/6443 (Lima's k8s stopped).
# Not part of the product: it only drives the documented reviewer steps. Lessons it encodes: the stand-in firewall
# filters in postrouting (an output-hook oifname filter also drops in-VM ClusterIP traffic, which a real external
# firewall never sees), and NTP is allowed (docs/assumptions.md, B-102).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="${DRYRUN_VM:-indev-reviewer}"
DIR="${DRYRUN_DIR:-${TMPDIR:-/tmp}}"; DIR="${DIR%/}/indev-reviewer-dryrun"
CLONE="$DIR/INDEV-Assignment"
LOG="$DIR/run.log"          # full output of the reviewer's commands (terminal transcript)
PID="$DIR/run.pid"
RESULT="$DIR/result"        # PASS or FAIL once finished
WAIT_MAX=540                # under an agent's 10-min command limit

LIMACTL="$ROOT/.tools/bin/limactl"
[[ -x "$LIMACTL" ]] || LIMACTL="$(command -v limactl || true)"

die() { echo "reviewer-dryrun: $*" >&2; exit 2; }
running() { [[ -f "$PID" ]] && kill -0 "$(cat "$PID")" 2>/dev/null; }
vm() { "$LIMACTL" shell "$VM" "$@"; }

preflight() {
  [[ -n "$LIMACTL" ]] || die "no limactl: run make deps in this checkout (or install Lima) first"
  grep -q '# indev-k8s' /etc/hosts || die "hosts entry missing: run scripts/hosts-entry.sh --apply (asks for sudo), then start again"
  local p busy=""
  for p in 443 80 6443 18443 18000 18128; do
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 && busy+=" $p"
  done
  [[ -z "$busy" ]] || die "host ports in use:$busy (Lima's k8s VM: limactl stop k8s; an old dry run: $0 cleanup)"
}

firewall() {  # the stand-in for the reviewer's network
  cat <<'EOF'
table inet reviewer_net
delete table inet reviewer_net
table inet reviewer_net {
  chain egress_post {
    type filter hook postrouting priority 50; policy accept;
    oifname "eth0" ct state established,related accept
    oifname "eth0" udp dport 123 accept
    oifname "eth0" counter drop
  }
}
EOF
}

# Runs a command in a pseudo-terminal (the reviewer's terminal): output to stdout, "n" to the CA question,
# "N" to any other [y/N] question (a sudo step would need a person: preflight makes sure none is left).
PTY_DRIVER='
import os, pty, sys, re
pid, fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
buf = b""
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    sys.stdout.buffer.write(data); sys.stdout.flush()
    buf = (buf + data)[-400:]
    if re.search(rb"create a new CA\? \[r/n\] *$", buf):
        os.write(fd, b"n\n"); buf = b""
    elif re.search(rb"\[y/N\] *$", buf):
        os.write(fd, b"N\n"); buf = b""
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
'

do_run() {  # the detached part
  local ref="$1" rc=0 port nft_pin
  echo "== $(date -u +%FT%TZ) reviewer dry run of $ref"
  echo "== stand-in VM $VM: fresh Debian 13, 4 CPU / 8 GiB / 40 GiB, no forwards, no mounts, no container runtime"
  "$LIMACTL" create -y --name="$VM" --cpus=4 --memory=8 --disk=40 \
    --set '.portForwards=[{"guestPortRange":[1,65535],"guestIP":"0.0.0.0","ignore":true}] | .mounts=[] | .containerd.system=false | .containerd.user=false' \
    template:debian-13
  "$LIMACTL" start "$VM"
  # nft for the stand-in firewall, at the version the playbook pins anyway (installed before the air gap).
  nft_pin="$(awk '$1 == "nftables:" {gsub(/"/, "", $2); print $2}' "$ROOT/ansible/group_vars/all/versions.yml")"
  vm sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "nftables=${nft_pin:?no nftables pin}" >/dev/null
  firewall | vm sudo nft -f -
  echo "== air gap: internet $(vm timeout 6 curl -sI https://deb.debian.org >/dev/null 2>&1 && echo OPEN || echo blocked)," \
    "DNS $(vm timeout 4 getent hosts deb.debian.org >/dev/null 2>&1 && echo OPEN || echo blocked)," \
    "containerd $(vm sh -c 'command -v containerd' >/dev/null 2>&1 && echo PRESENT || echo absent)"

  echo "== fresh clone of $ref from origin, external-vm.conf from the example (README step 1)"
  git clone -q --branch "$ref" "$(git -C "$ROOT" remote get-url origin)" "$CLONE"
  port="$("$LIMACTL" list "$VM" --format '{{.SSHLocalPort}}')"
  sed -e 's/^host=.*/host=127.0.0.1/' -e "s/^user=.*/user=$(id -un)/" -e "s/^port=.*/port=$port/" \
    -e 's|^# ssh_key=.*|ssh_key=~/.lima/_config/user|' "$CLONE/external-vm.conf.example" >"$CLONE/external-vm.conf"
  git -C "$CLONE" log --oneline -1

  echo "== make deps && make e2e KEEP_VM=1"
  (cd "$CLONE" && /usr/bin/python3 -I -c "$PTY_DRIVER" bash -c 'make deps && make e2e KEEP_VM=1') || rc=$?
  echo "== e2e exit $rc"
  if (( rc == 0 )); then
    echo "== make smoke"; (cd "$CLONE" && make smoke) || rc=$?
  fi
  echo "== stand-in drops: $(vm sudo nft list table inet reviewer_net 2>/dev/null | grep -o 'packets [0-9]*' | head -1)"
  if (( rc == 0 )); then echo PASS >"$RESULT"; else echo FAIL >"$RESULT"; fi
  echo "== $(date -u +%FT%TZ) $(cat "$RESULT")"
}

summary() {
  [[ -f "$LOG" ]] || { echo "no dry run in $DIR"; return 2; }
  local clean; clean="$(LC_ALL=C tr -d '\r' <"$LOG" | sed 's/\x1b\[[0-9;]*m//g')"
  echo "log: $LOG"
  grep -a -E '^== ' <<<"$clean" || true
  grep -a -E '^k8s-node +:' <<<"$clean" | sed 's/^/recap: /' || true
  grep -a -E 'Summary:' <<<"$clean" | tail -1 || true
  grep -a -E '^ *(FAIL|SKIP) \[|\*\*\* \[|fatal: \[' <<<"$clean" | head -20 || true
  if running; then echo "state: running"; return 3; fi
  [[ "$(cat "$RESULT" 2>/dev/null)" == PASS ]] && { echo "state: PASS"; return 0; }
  echo "state: FAIL"; return 1
}

case "${1:-}" in
  start)
    running && die "already running (pid $(cat "$PID")); $0 wait"
    preflight
    "$0" cleanup >/dev/null 2>&1 || true   # a dry run starts from nothing
    mkdir -p "$DIR"
    set -m
    nohup "$0" _run "${2:-main}" >"$LOG" 2>&1 </dev/null &
    echo $! >"$PID"
    set +m
    echo "started (pid $(cat "$PID")), log $LOG; 15-30 min. Next: $0 wait" ;;
  _run) do_run "$2" ;;
  wait)
    i=0; while running && (( i < WAIT_MAX )); do sleep 10; i=$((i + 10)); done
    summary ;;
  status) summary ;;
  cleanup)
    if running; then kill -- -"$(cat "$PID")" 2>/dev/null || kill "$(cat "$PID")" 2>/dev/null || true; fi
    [[ -x "$CLONE/scripts/external.sh" ]] && (cd "$CLONE" && scripts/external.sh tunnel stop >/dev/null 2>&1 || true)
    [[ -n "$LIMACTL" ]] && "$LIMACTL" delete -f "$VM" >/dev/null 2>&1 || true
    rm -rf "$DIR"
    echo "cleaned: VM $VM, tunnel, $DIR" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
