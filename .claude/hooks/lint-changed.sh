#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): lint the YAML file Claude just changed.
# Exit 0 = fine / not applicable. Exit 2 = lint errors, stderr is fed back to Claude.
set -uo pipefail

payload="$(cat)"
file="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)"

[[ -z "$file" || ! -f "$file" ]] && exit 0
case "$file" in
  *.yml|*.yaml) ;;
  *) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$root" || exit 0
rel="${file#"$root"/}"

# Skip vendored / generated paths
case "$rel" in
  ansible/collections/*|out/*|backups/*|.ansible/*) exit 0 ;;
esac

status=0
out=""

if command -v yamllint >/dev/null 2>&1; then
  if ! res="$(yamllint -f parsable "$rel" 2>&1)"; then
    out+="yamllint ${rel}:"$'\n'"${res}"$'\n'
    status=2
  fi
fi

# ansible-lint on Ansible content (skip templates: *.j2 never reach here; Helm values are plain YAML)
if [[ "$rel" == ansible/* && "$rel" != ansible/roles/*/templates/* ]] && command -v ansible-lint >/dev/null 2>&1; then
  # stderr dropped: it only carries interpreter/compat warnings; violations go to stdout.
  if ! res="$(cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-lint --offline -q --nocolor -f pep8 "${rel#ansible/}" 2>/dev/null)"; then
    out+="ansible-lint ${rel}:"$'\n'"${res}"$'\n'
    status=2
  fi
fi

if [[ $status -ne 0 ]]; then
  printf 'Lint problems in the file you just edited. Fix them before continuing.\n%s' "$out" >&2
fi
exit $status
