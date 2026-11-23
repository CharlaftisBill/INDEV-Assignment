#!/usr/bin/env bash
# The Lima VM is air-gapped like a reviewer's VM: open its egress tunnel to the host proxy (scripts/external.sh).
# Lima's SSH port changes on every start, so the conf for external.sh is generated each time.
#   scripts/lima-egress.sh <vm-name> <limactl>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="$1"; LIMACTL="$2"
CONF="$ROOT/.cache/lima-vm.conf"
port="$("$LIMACTL" list "$VM" --format '{{.SSHLocalPort}}')"
[[ "$port" =~ ^[0-9]+$ && "$port" != 0 ]] || { echo "lima-egress: Lima VM '$VM' is not running (make vm-up)" >&2; exit 1; }
mkdir -p "$ROOT/.cache"
printf 'host=127.0.0.1\nuser=%s\nport=%s\nssh_key=%s\nhost_key_check=no\n' "$(id -un)" "$port" "$HOME/.lima/_config/user" >"$CONF"
EXT_CONF="$CONF" exec "$ROOT/scripts/external.sh" egress start
