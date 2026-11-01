#!/usr/bin/env bash
# rc-health against a real tmux server: a frozen (SIGSTOP) server must count as a miss within the
# probe timeout, not hang the check (AT8). A lone stopped pane process cannot be tested: tmux
# resumes it at once, so a real hang shows up as the whole unit frozen.
# Run by `make test-docker` in a Debian 13 container with the repo at /r (read-only).
set -uo pipefail
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

for i in 1 2 3 4 5; do apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq tmux sudo procps >/dev/null 2>&1 && break; sleep 5; done
install -m 0755 /r/bin/rc-health /usr/local/bin/
useradd -m -s /bin/bash cc-home
mkdir -p /var/lib/claude-rc /var/log/claude-rc /etc/systemd/system/multi-user.target.wants
touch /etc/systemd/system/multi-user.target.wants/claude-rc@cc-home.service
# systemd is not running here: report the unit active with a cgroup; restarts do nothing.
printf '#!/bin/sh\ncase "$1" in is-active) echo active;; show) echo /x;; *) :;; esac\n' > /usr/local/bin/systemctl
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/rc-alert
chmod +x /usr/local/bin/systemctl /usr/local/bin/rc-alert

# Like rc-start: tmux runs a script that execs the server, so only that process matches.
printf '#!/bin/bash\nexec -a "claude remote-control" sleep 600\n' > /usr/local/bin/fake-rc-start; chmod +x /usr/local/bin/fake-rc-start
su cc-home -c 'tmux -L rc-cc-home new-session -d -s rc /usr/local/bin/fake-rc-start'
sleep 1
verdict() { timeout 60 rc-health 2>/dev/null | tail -n1; }
check "running server is healthy" '[ "$(verdict)" = "cc-home: healthy" ]'

tpid="$(pgrep -u cc-home -f "tmux -L rc-cc-home")"
kill -STOP "$tpid"
start=$(date +%s); v="$(verdict)"; took=$(( $(date +%s) - start ))
check "frozen tmux server counts as a miss" '[[ $v == "cc-home: miss 1 "* ]]'
check "the check does not hang (under 30 s)" '[ $took -lt 30 ]'
kill -CONT "$tpid"; sleep 1
check "healthy again after CONT" '[ "$(verdict)" = "cc-home: healthy" ]'

echo "$fails failure(s)"; exit $((fails > 0))
