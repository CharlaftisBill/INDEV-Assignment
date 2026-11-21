#!/usr/bin/env bash
# Minimal terminal chat with the llama.cpp server at https://llm.local (streams the reply, keeps history).
#   scripts/chat.sh        commands: /reset clears history, /quit or Ctrl-D exits
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://llm.local/v1/chat/completions"
# --resolve: skip the ~5 s mDNS lookup macOS does for .local names on every curl run;
# 127.0.0.1:443 is the same Lima forward /etc/hosts points at.
# --data-binary @-: the body (whole history) goes on stdin, not into `ps`.
CURL=(curl -sSN --fail-with-body --cacert "$ROOT/certs/ca.crt" --resolve llm.local:443:127.0.0.1
      -H 'Content-Type: application/json' --data-binary @-)
for t in curl jq; do command -v "$t" >/dev/null || { echo "$t not found: run make deps" >&2; exit 1; }; done

raw="$(mktemp)"; reply="$(mktemp)"; err="$(mktemp)"; trap 'rm -f "$raw" "$reply" "$err"' EXIT
msgs='[]'
bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
note() { echo "${dim}($*)${off}" >&2; }

# One jq reads the SSE stream: keep "data: {...}" lines, print each token as it arrives.
# Control characters other than \t and \n are dropped so model output can't drive the terminal.
TOKENS='select(startswith("data: ")) | ltrimstr("data: ") | select(. != "[DONE]")
        | fromjson | .choices[0].delta.content // empty | gsub("[\u0000-\u0008\u000b-\u001f\u007f]"; "")'

# send: stream a reply to $msgs; 0 = ok, 2 = history too long for the context, 1 = other error.
send() {
  if jq -c '{stream: true, messages: .}' <<<"$msgs" | "${CURL[@]}" "$URL" 2>"$err" | tee "$raw" \
       | jq --unbuffered -Rrj "$TOKENS" | tee "$reply"; then
    return 0
  fi
  [[ "$(jq -r '.error.type? // empty' "$raw" 2>/dev/null)" == exceed_context_size_error ]] && return 2
  # Prefer the server's own message; fall back to curl's (connection refused, TLS, ...).
  local why; why="$(jq -r '.error.message? // empty' "$raw" 2>/dev/null || true)"
  echo; note "request failed: ${why:-$(cat "$err")}"
  note "if the server is down: make verify REQ=9"
  return 1
}

echo "${dim}Chatting with llm.local. /reset clears history, /quit or Ctrl-D exits.${off}"
while IFS= read -r -e -p "${bold}you>${off} " line; do
  case "$line" in
    '') continue ;;
    /quit) break ;;
    /reset) msgs='[]'; note "history cleared"; continue ;;
  esac
  history -s "$line"
  msgs="$(jq -c --arg c "$line" '. + [{role: "user", content: $c}]' <<<"$msgs")"

  printf '%sllm>%s ' "$bold" "$off"
  rc=0; send || rc=$?
  # The model's context is small (2048 tokens): drop the oldest exchange until the question fits.
  while (( rc == 2 )); do
    if [[ "$(jq length <<<"$msgs")" -le 1 ]]; then
      note "message too long for the model's context; shorten it"; break
    fi
    msgs="$(jq -c '.[2:]' <<<"$msgs")"
    note "context full: dropped the oldest exchange"
    rc=0; send || rc=$?
  done

  if (( rc == 0 )); then
    echo
    grep -q '"finish_reason":"length"' "$raw" && note "reply cut off at the context limit"
    msgs="$(jq -c --rawfile c "$reply" '. + [{role: "assistant", content: $c}]' <<<"$msgs")"
  else
    msgs="$(jq -c '.[:-1]' <<<"$msgs")"   # drop the unanswered question
  fi
done
echo
