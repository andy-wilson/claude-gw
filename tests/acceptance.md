# Acceptance tests

Copy this file to `tests/results/<tag>.md`, fill the
Result column (PASS / FAIL / SKIP + one line of evidence), commit with the tag.
"Off-network" means the phone on mobile data, Wi-Fi off.

| ID | Test | How | Pass when | Phase | Result |
| --- | --- | --- | --- | --- | --- |
| AT1 | New session from phone, off-network | Claude app → Code → `home-claude-gw` card → `ls /mnt/lab` | listing within 30 s of the tap | 1 | |
| AT2 | Same from each laptop | claude.ai/code → same card → same prompt | as AT1 | 1 | |
| AT3 | Session reaches lab hosts | prompt: `ssh <labhost> uptime` | real output | 1 | |
| AT4 | Process crash recovers | in CT: `pkill -9 -u cc-home -f remote-control` | `systemctl is-active claude-rc@cc-home` back within 20 s; card online in app within 60 s | 2 | |
| AT5 | Container reboot recovers | host: `pct reboot <CTID>` | card online within 2 min; no manual step | 2 | |
| AT6 | Network outage recovers | host firewall: block CT outbound 443 for 15 min, unblock | ntfy `high` "disconnected" about 4 min in (client retrying, no restart); if the client gives up, the server restarts; card online within 2 min of unblock; one "recovered" push | 2 | |
| AT7 | Hard failure alerts | in CT: `chmod 000 /usr/local/bin/rc-start; systemctl restart claude-rc@cc-home` and wait | `claude-rc-alert@cc-home` fired; ntfy `urgent` on phone within 2 min of 5th failure; then `chmod 755` + `systemctl reset-failed` restores | 2 | |
| AT8 | Hung process caught | in CT: `pkill -STOP -u cc-home -f remote-control` | restart within 2 min; ntfy `high` then `low` recovery | 2 | |
| AT9 | Tailscale + SSH fallback | phone on mobile data, Tailscale app connected, phone key in root's `authorized_keys`: Blink/Termius → `ssh root@<tailnet IP>` with the key named explicitly (Blink: `ssh -i <key> ...` or a saved host; its agent offers nothing by default); `sudo -u cc-home tmux -L rc-cc-home attach` | attached to the live server; `Ctrl-b d` detaches cleanly | 1 | |
| AT10 | Control page | phone: open `https://claude-gw-ctl.<tailnet>.ts.net`; the Proxmox session runs each failure step | all good: green, "All good", Claude Code version, tag, last check. One `systemctl kill -s STOP claude-rc@<profile>` miss: amber "1 missed check (alerts at 2)", no push. AT7 method: red "down, retrying every 2 min", urgent alert in the history as sent, "recovered" pushed after the restore. A session started from the phone shows under Now within 30 s with its first prompt, then under Earlier today; times in the phone's timezone. Its details page shows prompts, replies and tool calls newest first, worktree, branch, uncommitted changes. Silence 1 h, then a STOP until 2 misses: no push, one folded "silenced" row, the alert sent after Alerts on. Prune removes only safe worktrees; rc-update runs and logs. Every action is in `journalctl -u rcctl` with the login; a headerless POST and another login get 403 | 3 | |
| AT11 | Account isolation | from a home session: read `/home/cc-work/.claude-cc-work/.credentials.json`; run `cat /etc/claude-rc/cc-home.env` | both fail with permission denied at the OS level | 4 | |
| AT12 | Work profile visibility | phone signed into the work account | only `work-claude-gw` card visible | 4 | |
| AT13 | Permission prompt reaches phone | from the phone, ask a session to `rm` a tracked file (a managed `ask` rule) | the session waits for approval; Claude push **and** ntfy `high` arrive; approving from the phone unblocks | 2 | |
| AT14 | Rollback | tag a deliberately broken `rc-start` as `vX.Y-bad`, `make deploy TAG=vX.Y-bad`, observe AT7, `make rollback` | servers back within 2 min; `make status` shows previous tag | 3 | |
| AT15 | Trusted Devices enforced | open a session from an un-enrolled browser | enrolment prompt; session not visible until enrolled | 1 | |
| AT16 | Claude Code update and revert | in CT: `rc-update` (from an older version), `rc-update` again, then `rc-update 9.9.9` (no such version) | first updates to `latest`, healthy, ntfy `low`; second says up to date; the bad one reverts to the previous version with ntfy `high`; `make status` shows the installed version | 2 | |
| AT17 | Egress firewall | host: `proxmox/firewall.sh enable <CTID>`; in CT as the profile: `curl -sI https://api.anthropic.com`, `nc -zw3 <proxmox-host> 8006`, `nc -zw3 <other-LAN-host> 22`, then `firewall.sh allow <CTID> <lab-host>` and `nc -zw3 <lab-host> <port>`; host: `firewall.sh disable <CTID>`, `status`, `enable` | internet and allowed hosts reachable; the Proxmox host and other LAN hosts time out; SSH in from the LAN and tailnet still works; card online and a session runs; disable warns, needs the CTID typed, is logged in the host syslog, and `status` shows DISABLED until re-enabled | 2, opt-in: only if the firewall is enabled | |

Non-functional (record numbers):

| Check | How | Target | Result |
| --- | --- | --- | --- |
| Idle CPU | `top -bn1` with both servers idle | < 5 % | |
| Idle RSS | `systemctl status claude-rc@*` memory line | < 1.5 GB total | |
| LAN exposure | `ss -tulpn` on eth0 | only tailscale UDP 41641 and sshd listening; sshd `AllowUsers` limited to the tailnet and `LAN_CIDR` | |
| Bootstrap time | wall clock from `pct create` to AT1, excluding interactive logins | < 20 min | |
