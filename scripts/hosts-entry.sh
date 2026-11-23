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
# On macOS Lima's forward listens on *:443 (dual stack), so ::1 reaches it; on Linux it binds 127.0.0.1,
# ::1 is refused at once and clients fall back to 127.0.0.1.
# Not LINES: after a command run on the terminal (sudo) bash resets LINES to the window height (B-100).
ENTRIES=("127.0.0.1 $NAMES $MARKER" "::1 $NAMES $MARKER")

flush_dns() {  # macOS caches /etc/hosts lookups; Linux resolvers read the file directly
  [[ "$(uname -s)" == Darwin ]] || return 0
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

# Byte-wise grep (LC_ALL=C, -a): in a UTF-8 locale GNU grep drops non-UTF-8 lines, and NUL bytes make
# grep treat the file as binary; either would lose unrelated entries on rewrite (B-060).
g() { LC_ALL=C grep -a "$@"; }
any() { g -q "[[:space:]]$MARKER\$" /etc/hosts 2>/dev/null; }
complete() { local l; for l in "${ENTRIES[@]}"; do g -qxF "$l" /etc/hosts 2>/dev/null || return 1; done; }
show() { g "[[:space:]]$MARKER\$" /etc/hosts; }

tmp=""; trap '[[ -z "$tmp" ]] || rm -f "$tmp"' EXIT
count() { g -c "$1" "$2" || [[ $? -eq 1 ]]; }   # grep -c: rc 1 = zero matches (prints 0), rc 2 = read error
write_hosts() {  # write_hosts [LINE...]: drop our marker lines, append the given ones
  local total ours kept
  tmp="$(mktemp)"
  if ! total="$(count '' /etc/hosts)" || ! ours="$(count "[[:space:]]$MARKER\$" /etc/hosts)"; then
    echo "Refusing to rewrite /etc/hosts: cannot read it." >&2; exit 1
  fi
  g -v "[[:space:]]$MARKER\$" /etc/hosts >"$tmp" || [[ $? -eq 1 ]] || { echo "Refusing to rewrite /etc/hosts: cannot read it." >&2; exit 1; }
  kept="$(count '' "$tmp")"
  if [[ "$kept" -ne $((total - ours)) ]]; then  # every other entry must survive, byte for byte
    echo "Refusing to rewrite /etc/hosts: would keep $kept of its $((total - ours)) other lines." >&2; exit 1
  fi
  [[ $# -eq 0 ]] || printf '%s\n' "$@" >>"$tmp"
  # shellcheck disable=SC2024  # the temp file is ours; only the write to /etc/hosts needs root
  sudo tee /etc/hosts <"$tmp" >/dev/null   # rewrites in place, keeping owner and mode
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
    write_hosts "${ENTRIES[@]}"
    echo "Added:"; printf '  %s\n' "${ENTRIES[@]}"
    ;;
  "")
    if complete; then echo "Already present in /etc/hosts:"; show | sed 's/^/  /'; exit 0; fi
    echo "Would add to /etc/hosts$(any && echo ', replacing the current indev-k8s lines'):"
    printf '  %s\n' "${ENTRIES[@]}"
    echo "Run again with --apply (needs sudo), or add them by hand."
    ;;
  *) echo "Usage: $0 [--apply|--remove|--check]" >&2; exit 2 ;;
esac
