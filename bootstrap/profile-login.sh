#!/usr/bin/env bash
# One-time interactive setup for a profile. Run INSIDE the container as root,
# from a real terminal (SSH or pct enter). Walks the three prompts Remote
# Control cannot answer unattended:
#   1. claude auth login        (choose the claude.ai option; NOT an API key)
#   2. Enable Remote Control?   (answer y)
#   3. Trust <workdir>?         (answer y; saved for that directory)
# then exits the server so systemd can own it from here on.
set -euo pipefail

PROFILE="${1:?profile, e.g. cc-home}"
ENV_FILE="/etc/claude-rc/$PROFILE.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy from etc/claude-rc/$PROFILE.env.example)" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
: "${CLAUDE_CONFIG_DIR:?}" "${WORKDIR:?}"

id "$PROFILE" >/dev/null
install -d -o "$PROFILE" -g cc-lab -m 0700 "$CLAUDE_CONFIG_DIR"
install -d -o "$PROFILE" -g cc-lab -m 0775 "$WORKDIR"

run_as() { sudo -u "$PROFILE" -H env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" "$@"; }

# worktree spawn mode needs a git repo in WORKDIR. Seed one with a CLAUDE.md that
# tells every session to read/write HANDOVER.md (the only context that survives a stale session).
if [ ! -d "$WORKDIR/.git" ]; then
  echo "== seeding git repo in $WORKDIR =="
  cp "$(dirname "$0")/../profiles/workdir-CLAUDE.md" "$WORKDIR/CLAUDE.md"
  chown "$PROFILE:cc-lab" "$WORKDIR/CLAUDE.md"
  run_as git -C "$WORKDIR" init -q -b main
  run_as git -C "$WORKDIR" -c user.name="$PROFILE" -c user.email="$PROFILE@claude-gw" add CLAUDE.md
  run_as git -C "$WORKDIR" -c user.name="$PROFILE" -c user.email="$PROFILE@claude-gw" commit -q -m "seed workdir"
fi

echo "== 1/3 claude auth login (pick the claude.ai option) =="
run_as claude auth login

echo "== 2/3 + 3/3 consent and workspace trust =="
echo "A Remote Control server will start in $WORKDIR."
echo "Answer y to 'Trust $WORKDIR?' and y to 'Enable Remote Control?' (it comes after the welcome text)."
echo "Only press Ctrl-C once it shows '✔ Ready'; systemd takes over from here."
cd "$WORKDIR"
run_as claude remote-control --name "${RC_NAME:-$PROFILE}" --spawn "${RC_SPAWN:-worktree}" --no-create-session-in-dir || true

echo
echo "Run this script again to confirm: it should go straight to Ready with no prompts."
echo "Then deploy: make -C /opt/claude-gw deploy TAG=<tag>"
