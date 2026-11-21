#!/usr/bin/env bash
# Port-forward the Prometheus and Alertmanager UIs to the Mac's loopback until Ctrl-C.
# Not exposed by Ingress: neither has a login (docs/usage.md#web-pages).
#   scripts/monitoring-ui.sh <admin kubeconfig>
set -euo pipefail

KUBECONFIG_ADMIN="${1:?usage: $0 <admin kubeconfig>}"
NS=monitoring
[[ -r "$KUBECONFIG_ADMIN" ]] || { echo "No $KUBECONFIG_ADMIN: provision the cluster first (make provision)." >&2; exit 1; }

pids=()
# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() { for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done; }  # bash 3.2-safe when empty
trap cleanup EXIT
trap 'exit 0' INT TERM   # Ctrl-C is the normal way out

# --address 127.0.0.1: only this Mac, never the LAN.
for fwd in prometheus:9090 alertmanager:9093; do
  kubectl --kubeconfig "$KUBECONFIG_ADMIN" port-forward -n "$NS" --address 127.0.0.1 \
    "svc/kps-${fwd%%:*}" "${fwd#*:}:${fwd#*:}" >/dev/null &
  pids+=("$!")
done

echo "Prometheus:   http://localhost:9090"
echo "Alertmanager: http://localhost:9093"
echo "Ctrl-C to stop."

# Stop both when either forward dies (pod restart, VM down, port taken).
while kill -0 "${pids[0]}" 2>/dev/null && kill -0 "${pids[1]}" 2>/dev/null; do sleep 1; done
echo "A port-forward stopped (pod restarted, VM down or port in use); run make monitoring-ui again." >&2
exit 1
