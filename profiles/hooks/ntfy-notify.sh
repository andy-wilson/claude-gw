#!/usr/bin/env bash
# Claude Code `Notification` hook: fires when Claude needs a decision (permission
# prompt, AskUserQuestion) or goes idle. Mirrors the app's own push to ntfy so the
# phone still hears about it if the Remote Control link is the thing that broke.
# Input: JSON on stdin (session_id, cwd, message, notification_type ...).
set -uo pipefail
input="$(cat)"
kind="$(printf '%s' "$input" | jq -r '.notification_type // "notification"' 2>/dev/null)"
PROFILE="${PROFILE:-$(id -un)}"
export PROFILE
case "$kind" in
  permission_prompt|permission*) prio=high; tags=lock ;;
  idle_prompt|idle*)             prio=low;  tags=zzz ;;
  *)                             prio=default; tags=speech_balloon ;;
esac
# Body is profile + notification kind only (design: no message text, no paths leave the box).
/usr/local/bin/ntfy-send "$prio" "Claude ($PROFILE): $kind" "Claude needs you" "$tags" || true
exit 0
