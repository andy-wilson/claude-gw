#!/usr/bin/env bash
# rc-inspect against a fake profile: sessions JSON, worktree scan and prune safety.
# Run by `make test-docker` in a Debian 13 container with the repo at /r (read-only).
set -uo pipefail
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

for i in 1 2 3 4 5; do apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq git jq procps >/dev/null 2>&1 && break; sleep 5; done
install -m 0755 /r/bin/rc-inspect /usr/local/bin/
useradd -m cc-home; mkdir -p /etc/claude-rc /mnt/claude-gw/home; chown cc-home /mnt/claude-gw/home
# Quotes and outer spaces, as systemd's EnvironmentFile allows.
printf 'CLAUDE_CONFIG_DIR= "/home/cc-home/.claude-cc-home"\nWORKDIR='"'"'/mnt/claude-gw/home'"'"'  \nNTFY_TOKEN=secret\n' > /etc/claude-rc/cc-home.env

su -s /bin/bash cc-home -c '
set -e; cd /mnt/claude-gw/home; git init -q -b main; git config --global user.email t@t; git config --global user.name t
echo x > f; echo "*.log" > .gitignore; git add .; git commit -qm seed
for b in done dirty open busy recent ign sub; do git worktree add -q .claude/worktrees/$b -b $b; done
git -C .claude/worktrees/done commit -q --allow-empty -m d; git merge -q done
echo y > .claude/worktrees/dirty/new
echo y > .claude/worktrees/ign/notes.log
git -C .claude/worktrees/open commit -q --allow-empty -m o
git worktree add -q --detach .claude/worktrees/det
P=~/.claude-cc-home/projects; W=/mnt/claude-gw/home/.claude/worktrees
mkdir -p $P/-mnt-claude-gw-home $P/-mnt-claude-gw-home--claude-worktrees-recent $P/-mnt-claude-gw-home--claude-worktrees-sub-src $P/-mnt-claude-gw-home--claude-worktrees-busy
# A worktree session with a prompt, a reply, a tool call and a half-written last line.
{
  echo "{\"type\":\"system\",\"timestamp\":\"2026-11-01T10:00:00Z\",\"cwd\":\"$W/recent\",\"gitBranch\":\"recent\"}"
  echo "{\"type\":\"user\",\"timestamp\":\"2026-11-01T10:00:01Z\",\"cwd\":\"$W/recent\",\"message\":{\"content\":\"fix the\tbuild\nplease\"}}"
  echo "{\"type\":\"assistant\",\"timestamp\":\"2026-11-01T10:00:05Z\",\"cwd\":\"$W/recent\",\"gitBranch\":\"recent\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Looking at it.\"},{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"make test\"}}]}}"
  echo "{\"type\":\"user\",\"timestamp\":\"2026-11-01T10:00:09Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}}"
  printf "{\"type\":\"assistant\",\"mess"
} > $P/-mnt-claude-gw-home--claude-worktrees-recent/1111aaaa-0000-0000-0000-000000000001.jsonl
echo "{\"type\":\"user\",\"cwd\":\"$W/sub/src\",\"message\":{\"content\":\"in a subdir\"}}" > $P/-mnt-claude-gw-home--claude-worktrees-sub-src/2222bbbb-0000-0000-0000-000000000002.jsonl
echo "{\"type\":\"user\",\"cwd\":\"$W/busy\",\"message\":{\"content\":\"busy one\"}}" > $P/-mnt-claude-gw-home--claude-worktrees-busy/3333cccc-0000-0000-0000-000000000003.jsonl
touch -d "30 minutes ago" $P/-mnt-claude-gw-home--claude-worktrees-busy/*.jsonl
echo "{\"type\":\"user\",\"message\":{\"content\":\"too old\"}}" > $P/-mnt-claude-gw-home/4444dddd-0000-0000-0000-000000000004.jsonl
touch -d "3 days ago" $P/-mnt-claude-gw-home/*.jsonl
for i in $(seq 40); do echo "{}" > $P/-mnt-claude-gw-home/x$i.jsonl; done
touch -d "1 hour ago" $P/-mnt-claude-gw-home/x*.jsonl
'
# A live session process (its name contains claude) inside the busy worktree.
su -s /bin/bash cc-home -c 'cd /mnt/claude-gw/home/.claude/worktrees/busy && exec -a claude sleep 120' &
sleep 1

out="$(rc-inspect cc-home sessions)"; rc=$?
check "sessions exits 0 with 40+ transcripts and a partial line" '[ $rc = 0 ]'
check "sessions caps at 30" '[ "$(printf "%s\n" "$out" | wc -l)" = 30 ]'
check "sessions drops transcripts older than 36 h" '! printf "%s" "$out" | grep -q 4444dddd'
s1="$(printf '%s\n' "$out" | grep 1111aaaa)"
check "first prompt, whitespace folded" '[ "$(printf "%s" "$s1" | jq -r .prompt)" = "fix the build please" ]'
check "cwd and branch from the records" '[ "$(printf "%s" "$s1" | jq -r .branch)" = recent ] && printf "%s" "$s1" | jq -e ".cwd | endswith(\"/recent\")" >/dev/null'
check "activity newest first: tool, reply, prompt" '[ "$(printf "%s" "$s1" | jq -r "[.activity[].kind] | join(\",\")")" = "tool,assistant,user" ]'
check "tool call summarised by its command" '[ "$(printf "%s" "$s1" | jq -r ".activity[0].text")" = "Bash make test" ]'
check "recently written session is live" '[ "$(printf "%s" "$s1" | jq -r .live)" = true ]'
s3="$(printf '%s\n' "$out" | grep 3333cccc)"
check "session with a claude process in its worktree is live" '[ "$(printf "%s" "$s3" | jq -r .live)" = true ]'
check "untouched worktree is not dirty" '[ "$(printf "%s" "$s3" | jq -r .dirty)" = false ]'

wt="$(rc-inspect cc-home worktrees)"
row() { printf '%s\n' "$wt" | awk -v b="$1" '$4 == b {print $1, $2, $3}'; }
check "done: merged, clean, free" '[ "$(row done)" = "yes yes no" ]'
check "dirty: not clean" '[ "$(row dirty)" = "yes no no" ]'
check "ignored files count as not clean" '[ "$(row ign)" = "yes no no" ]'
check "unmerged: not merged" '[ "$(row open)" = "no yes no" ]'
check "live process: in use" '[ "$(row busy)" = "yes yes yes" ]'
check "recent transcript: in use" '[ "$(row recent)" = "yes yes yes" ]'
check "transcript in a subdirectory: in use" '[ "$(row sub)" = "yes yes yes" ]'

pr="$(rc-inspect cc-home prune)"
check "prune removes only the safe one" '[ "$(printf "%s\n" "$pr" | tail -n1)" = "pruned 1 worktree(s)" ] && printf "%s" "$pr" | grep -qx "removed done"'
check "prune keeps the others" '[ "$(rc-inspect cc-home worktrees | tail -n +2 | wc -l)" = 7 ]'

check "bad profile refused" '! rc-inspect "x;y" sessions 2>/dev/null'
check "unknown command refused" '! rc-inspect cc-home rm 2>/dev/null'
printf 'CLAUDE_CONFIG_DIR=/x\nWORKDIR=/tmp\n' > /etc/claude-rc/cc-home.env
check "prune fails on a workdir that is not a repo" '! rc-inspect cc-home prune 2>/dev/null'

echo "$fails failure(s)"; exit $((fails > 0))
