#!/usr/bin/env bash
# Map the ingress hostnames to the Lima port-forward on the Mac.
#   scripts/hosts-entry.sh          # show what would be added
#   scripts/hosts-entry.sh --apply  # add it (uses sudo)
set -euo pipefail

HOSTS_LINE="127.0.0.1 llm.local grafana.local"
MARKER="# indev-k8s"

if grep -q "$MARKER" /etc/hosts; then
  echo "Already present in /etc/hosts:"
  grep "$MARKER" /etc/hosts
  exit 0
fi

if [[ "${1:-}" == "--apply" ]]; then
  printf '%s %s\n' "$HOSTS_LINE" "$MARKER" | sudo tee -a /etc/hosts >/dev/null
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  echo "Added: $HOSTS_LINE"
else
  echo "Would add to /etc/hosts:"
  echo "  $HOSTS_LINE $MARKER"
  echo "Run again with --apply (needs sudo), or add it by hand."
fi
