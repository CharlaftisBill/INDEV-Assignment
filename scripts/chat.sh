#!/usr/bin/env bash
# Minimal terminal chat with the llama.cpp server at https://llm.local (streams the reply, keeps history).
#   scripts/chat.sh        commands: /reset clears history, /quit or Ctrl-D exits
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://llm.local/v1/chat/completions"
# --resolve: skip the ~5 s mDNS lookup macOS does for .local names on every curl run;
# 127.0.0.1:443 is the same Lima forward /etc/hosts points at.
CURL=(curl -sSN --fail --cacert "$ROOT/certs/ca.crt" --resolve llm.local:443:127.0.0.1)
for t in curl jq; do command -v "$t" >/dev/null || { echo "$t not found: run make deps" >&2; exit 1; }; done

reply="$(mktemp)"; trap 'rm -f "$reply"' EXIT
msgs='[]'
bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
echo "${dim}Chatting with llm.local. /reset clears history, /quit or Ctrl-D exits.${off}"

while IFS= read -r -e -p "${bold}you>${off} " line; do
  case "$line" in
    '') continue ;;
    /quit) break ;;
    /reset) msgs='[]'; echo "${dim}(history cleared)${off}"; continue ;;
  esac
  history -s "$line"
  msgs="$(jq -c --arg c "$line" '. + [{role: "user", content: $c}]' <<<"$msgs")"

  printf '%sllm>%s ' "$bold" "$off"
  # One jq reads the SSE stream: keep "data: {...}" lines, print each token as it arrives.
  if "${CURL[@]}" "$URL" -H 'Content-Type: application/json' \
       -d "$(jq -c '{stream: true, messages: .}' <<<"$msgs")" \
     | jq --unbuffered -Rrj 'select(startswith("data: ")) | ltrimstr("data: ") | select(. != "[DONE]")
                             | fromjson | .choices[0].delta.content // empty' \
     | tee "$reply"; then
    echo
    msgs="$(jq -c --rawfile c "$reply" '. + [{role: "assistant", content: $c}]' <<<"$msgs")"
  else
    echo; echo "${dim}(request failed; is the VM up? make verify REQ=9)${off}" >&2
    msgs="$(jq -c '.[:-1]' <<<"$msgs")"   # drop the unanswered question
  fi
done
echo
