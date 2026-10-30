#!/usr/bin/env bash
# Claude Code `Stop` hook: keeps $cwd/HANDOVER.md current so a fresh session (after a
# stale Remote Control link, or a deliberate new one) can pick up where this one left off.
# Writes the last assistant message as the "Last state" and keeps the human-maintained
# "Plan / open items" section untouched. Never blocks Claude (exit 0 always).
set -uo pipefail
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
session="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
[ -w "$cwd" ] || exit 0

last=""
if [ -n "$transcript" ] && [ -r "$transcript" ]; then
  # Transcript is JSONL; take the last assistant text block.
  last="$(tac "$transcript" | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | head -n 40 | head -c 2500)"
fi
[ -n "$last" ] || exit 0

f="$cwd/HANDOVER.md"
plan=""
if [ -f "$f" ]; then
  plan="$(awk '/^## Plan \/ open items/{p=1} p' "$f")"
fi
[ -n "$plan" ] || plan=$'## Plan / open items\n\n- (maintained by the session: what is in flight, what is next, what to avoid)\n'

{
  printf '# HANDOVER\n\n'
  printf 'Auto-updated by the Stop hook. A new session should read this first.\n\n'
  printf '## Last state\n\n- when: %s\n- session: %s\n- branch: %s\n\n' \
    "$(date -Is)" "${session:-?}" "$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  printf '%s\n\n' "$last"
  printf '%s\n' "$plan"
} > "$f.tmp" && mv "$f.tmp" "$f"
exit 0
