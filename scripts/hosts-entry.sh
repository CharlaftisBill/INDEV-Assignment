#!/usr/bin/env bash
# Map the ingress hostnames to the Lima port-forward on the host (IPv4 and IPv6 loopback).
#   scripts/hosts-entry.sh           # show what would be added
#   scripts/hosts-entry.sh --apply   # add both lines, or replace an incomplete set (uses sudo)
#   scripts/hosts-entry.sh --remove  # delete the lines this script added (uses sudo)
#   scripts/hosts-entry.sh --check   # exit 0 only if both lines are present
set -euo pipefail

NAMES="llm.local grafana.local"
MARKER="# indev-k8s"
# ::1 too: without an AAAA answer macOS sends the .local AAAA query to mDNS and waits 5 s (B-059).
# Lima's forward listens on *:443 (dual stack), so ::1 reaches it.
LINES=("127.0.0.1 $NAMES $MARKER" "::1 $NAMES $MARKER")

flush_dns() {  # macOS caches /etc/hosts lookups; Linux resolvers read the file directly
  [[ "$(uname -s)" == Darwin ]] || return 0
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

any() { grep -q "[[:space:]]$MARKER\$" /etc/hosts 2>/dev/null; }
complete() { local l; for l in "${LINES[@]}"; do grep -qxF "$l" /etc/hosts 2>/dev/null || return 1; done; }
show() { grep "[[:space:]]$MARKER\$" /etc/hosts; }

write_hosts() {  # write_hosts [LINE...]: drop our marker lines, append the given ones
  local tmp; tmp="$(mktemp)"
  { grep -v "[[:space:]]$MARKER\$" /etc/hosts || true; [[ $# -eq 0 ]] || printf '%s\n' "$@"; } >"$tmp"
  # shellcheck disable=SC2024  # the temp file is ours; only the write to /etc/hosts needs root
  sudo tee /etc/hosts <"$tmp" >/dev/null   # rewrites in place, keeping owner and mode
  rm -f "$tmp"
  flush_dns
}

case "${1:-}" in
  --check) complete ;;
  --remove)
    if ! any; then echo "Not in /etc/hosts, nothing to remove."; exit 0; fi
    echo "Removing:"; show | sed 's/^/  /'
    write_hosts
    ;;
  --apply)
    if complete; then echo "Already present in /etc/hosts:"; show | sed 's/^/  /'; exit 0; fi
    any && { echo "Replacing an incomplete entry:"; show | sed 's/^/  /'; }
    write_hosts "${LINES[@]}"
    echo "Added:"; printf '  %s\n' "${LINES[@]}"
    ;;
  "")
    if complete; then echo "Already present in /etc/hosts:"; show | sed 's/^/  /'; exit 0; fi
    echo "Would add to /etc/hosts$(any && echo ', replacing the current indev-k8s lines'):"
    printf '  %s\n' "${LINES[@]}"
    echo "Run again with --apply (needs sudo), or add them by hand."
    ;;
  *) echo "Usage: $0 [--apply|--remove|--check]" >&2; exit 2 ;;
esac
