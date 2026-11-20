#!/usr/bin/env bash
# Map the ingress hostnames to the Lima port-forward on the host.
#   scripts/hosts-entry.sh           # show what would be added
#   scripts/hosts-entry.sh --apply   # add it (uses sudo)
#   scripts/hosts-entry.sh --remove  # delete the line this script added (uses sudo)
set -euo pipefail

HOSTS_LINE="127.0.0.1 llm.local grafana.local"
MARKER="# indev-k8s"

flush_dns() {  # macOS caches /etc/hosts lookups; Linux resolvers read the file directly
  [[ "$(uname -s)" == Darwin ]] || return 0
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

present() { grep -q "[[:space:]]$MARKER\$" /etc/hosts; }

case "${1:-}" in
  --remove)
    if ! present; then echo "Not in /etc/hosts, nothing to remove."; exit 0; fi
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    grep -v "[[:space:]]$MARKER\$" /etc/hosts >"$tmp" || true
    # shellcheck disable=SC2024  # the temp file is ours; only the write to /etc/hosts needs root
    sudo tee /etc/hosts <"$tmp" >/dev/null   # rewrites in place, keeping owner and mode
    flush_dns
    echo "Removed: $HOSTS_LINE $MARKER"
    ;;
  --apply)
    if present; then echo "Already present in /etc/hosts:"; grep "$MARKER" /etc/hosts; exit 0; fi
    printf '%s %s\n' "$HOSTS_LINE" "$MARKER" | sudo tee -a /etc/hosts >/dev/null
    flush_dns
    echo "Added: $HOSTS_LINE"
    ;;
  "")
    if present; then echo "Already present in /etc/hosts:"; grep "$MARKER" /etc/hosts; exit 0; fi
    echo "Would add to /etc/hosts:"
    echo "  $HOSTS_LINE $MARKER"
    echo "Run again with --apply (needs sudo), or add it by hand."
    ;;
  *) echo "Usage: $0 [--apply|--remove]" >&2; exit 2 ;;
esac
