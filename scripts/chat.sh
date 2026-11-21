#!/usr/bin/env bash
# Minimal terminal chat with the llama.cpp server at https://llm.local (streams the reply, keeps history).
#   scripts/chat.sh        /reset clears history, /quit or Ctrl-D exits, Ctrl-C stops a reply (at the prompt: exits)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="https://llm.local/v1/chat/completions"
# --resolve: skip the ~5 s mDNS lookup macOS does for .local names on every curl run;
# 127.0.0.1:443 is the same Lima forward /etc/hosts points at.
# --data-binary @-: the body (whole history) goes on stdin, not into `ps`.
CURL=(curl -sSN --fail-with-body --cacert "$ROOT/certs/ca.crt" --resolve llm.local:443:127.0.0.1
      -H 'Content-Type: application/json' --data-binary @-)
for t in curl jq; do command -v "$t" >/dev/null || { echo "$t not found: run make deps" >&2; exit 1; }; done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/chat.XXXXXX")"; raw="$tmp/raw"; reply="$tmp/reply"; err="$tmp/err"; question="$tmp/question"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 129' HUP; trap 'exit 143' TERM   # so the EXIT trap still removes the replies
stopped=0
msgs='[]'
bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
note() { echo "${dim}($*)${off}" >&2; }

# Drop C0/C1 control characters except \t and \n, so nothing from the server can drive the terminal.
CLEAN='gsub("[\u0000-\u0008\u000b-\u001f\u007f-\u009f]"; "")'
# One jq reads the SSE stream: keep "data: {...}" lines, print each token as it arrives.
TOKENS="select(startswith(\"data: \")) | ltrimstr(\"data: \") | select(. != \"[DONE]\")
        | fromjson? | .choices[0].delta.content // empty | $CLEAN"

# send: stream a reply to $msgs. 0 ok, 1 error (printed), 2 history too long for the context, 3 stopped by Ctrl-C.
send() {
  if jq -c '{stream: true, messages: .}' <<<"$msgs" | "${CURL[@]}" "$URL" 2>"$err" | tee "$raw" \
       | jq --unbuffered -Rrj "$TOKENS" | tee "$reply"; then
    # jq's exit code only reflects the last line, so a malformed stream can look fine:
    # a complete reply ends with the server's [DONE].
    grep -q '^data: \[DONE\]' "$raw" && return 0
  fi
  (( stopped )) && return 3
  [[ "$(jq -r '.error.type? // empty' "$raw" 2>/dev/null)" == exceed_context_size_error ]] && return 2
  # Prefer the server's own message, then curl's (connection refused, TLS, ...).
  local why; why="$(jq -r ".error.message? // empty | $CLEAN" "$raw" 2>/dev/null || true)"
  [[ -n "$why" ]] || why="$(cat "$err")"
  echo; note "request failed: ${why:-incomplete or malformed reply from the server}"
  note "if the server is down: make verify REQ=9"
  return 1
}

echo "${dim}Chatting with llm.local. /reset clears history, /quit or Ctrl-D exits, Ctrl-C stops a reply.${off}"
while IFS= read -r -e -p "${bold}you>${off} " line; do
  case "$line" in
    '') continue ;;
    /quit) break ;;
    /reset) msgs='[]'; note "history cleared"; continue ;;
  esac
  history -s "$line"
  printf '%s' "$line" >"$question"   # via a file, so the question is not in `ps` either
  before="$msgs"
  msgs="$(jq -c --rawfile c "$question" '. + [{role: "user", content: $c}]' <<<"$msgs")"

  printf '%sllm>%s ' "$bold" "$off"
  # Ctrl-C while a reply streams: curl/jq die, bash waits for them, then sees the flag.
  # Only here: at the prompt Ctrl-C keeps its default (exit), as readline ignores a trapped INT.
  stopped=0; trap 'stopped=1' INT
  rc=0; send || rc=$?
  # The model's context is small (2048 tokens): drop the oldest exchange until the question fits.
  dropped=0
  while (( rc == 2 )) && [[ "$(jq length <<<"$msgs")" -gt 1 ]]; do
    msgs="$(jq -c '.[2:]' <<<"$msgs")"; dropped=$((dropped + 1))
    rc=0; send || rc=$?
  done
  trap - INT

  case "$rc" in
    0)
      echo
      (( dropped )) && note "context full: dropped the $dropped oldest exchange(s)"
      grep -q '"finish_reason":"length"' "$raw" && note "reply cut off at the context limit"
      msgs="$(jq -c --rawfile c "$reply" '. + [{role: "assistant", content: $c}]' <<<"$msgs")" ;;
    2) echo; note "message too long for the model's context, history kept; shorten it"; msgs="$before" ;;
    3) echo; note "stopped"; msgs="$before" ;;
    *) msgs="$before" ;;   # error already printed; drop the unanswered question
  esac
done
echo
