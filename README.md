# claude-gw

Always-on Claude Code **Remote Control** gateway for a home Proxmox lab. One unprivileged LXC runs `claude remote-control` in server mode per account profile, supervised by systemd + tmux, so you can start a session against your lab from the Claude mobile app or claude.ai/code anywhere, with no SSH step. Tailscale provides the fallback SSH path and ntfy.sh pushes alerts to your phone when supervision cannot recover.

Sessions flow through Anthropic's relay (the gateway polls outbound), so nothing is exposed at the router. Each profile is a separate Linux user with its own `CLAUDE_CONFIG_DIR`, so two accounts never share credentials or transcripts. The only lab filesystem a session can touch is one dedicated share bind-mounted at `/mnt/lab`.

Architecture diagrams, component design, security model, change control, definition of done and phases: [`docs/design.md`](docs/design.md).

## Requirements

### Accounts

- A claude.ai subscription with Remote Control: Pro, Max or Ultra, or Team/Enterprise with Remote Control enabled by an Owner (not available with Zero Data Retention). API keys and long-lived tokens are refused by Remote Control.
- Trusted Devices turned on for the account (recommended): Pro/Max/Ultra in Settings, Account, **Require trusted devices**; Team/Enterprise by an Owner in Organization settings, Capabilities, Remote sessions.
- A Tailscale account, with HTTPS certificates on in the tailnet if you want the control page.
- An ntfy.sh topic per profile with an access token that can only publish to it (sessions of that profile can see the token).

### Proxmox host

- Proxmox VE 9 (tested on 9.2); 8.x should work if `pveam available` lists a `debian-13-standard` template. Root shell on the node. `proxmox/*.sh` run there; everything else runs as root inside the container.
- A Linux bridge with DHCP (or a static IP via `IP=`/`GW=`) and outbound internet from it.
- A dedicated directory on the host for the lab share (`LAB_SHARE`); it becomes `/mnt/lab` and is the only host path the container sees. `create-lxc.sh` sets it to group `101010` (container `cc-lab`) mode `2775`.
- Backup storage for `vzdump` (default `local`): `pct snapshot` is unavailable with a bind mount, so change control uses `vzdump` backups.
- Your SSH public key in `~/.ssh/authorized_keys` on the host (or `SSH_PUBKEY=`), seeded into the container's root for first login.

### Container

`proxmox/create-lxc.sh` creates it with these defaults; set the variables to change them.

| Setting | Default | Notes |
| --- | --- | --- |
| Template | newest `debian-13-standard_*_amd64.tar.zst` from `pveam` | Debian 13 (trixie) is required: systemd 257 (`RestartMode=direct`) and the tests target it. `TEMPLATE=` to pin one |
| Type | unprivileged | Container uid N is host uid 100000+N |
| Features | `nesting=1,keyctl=1` | systemd sandboxing needs nesting in an unprivileged container |
| Devices | `/dev/net/tun` passed through | Tailscale |
| CPU / memory / swap | 2 cores, 4096 MB, 512 MB (`CORES`, `MEMORY_MB`, `SWAP_MB`) | Idle use is under 5 % CPU and 1.5 GB |
| Disk | 32 GB on `local-lvm` (`DISK_GB`, `STORAGE`) | OS, Node, Claude Code and transcripts (`CLAUDE_CONFIG_DIR` in each profile home); session worktrees live under `WORKDIR` in the lab share |
| Network | `eth0` on `vmbr0`, DHCP (`BRIDGE`, `IP`, `GW`) | |
| Mount | `mp0`: `LAB_SHARE` at `/mnt/lab` | No other bind mounts |
| Start at boot | yes | |

`bootstrap/bootstrap.sh` then installs from the internet: Debian packages (git, tmux, jq, sudo, openssh-server, make and a few more), Node 22 from NodeSource, Claude Code from npm (`latest`) and Tailscale. Outbound HTTPS is needed to `deb.debian.org`, `deb.nodesource.com`, `registry.npmjs.org`, `tailscale.com` and `pkgs.tailscale.com`, Tailscale's control and DERP servers, `claude.ai` / `api.anthropic.com` and `ntfy.sh`.

### Building the control page (optional)

Docker on a laptop: `make rcctl` builds `dist/rcctl` reproducibly in a Go container; its sha256 is committed in `rcctl/rcctl.sha256`. `make test-docker` runs the shell tests in a Debian 13 container.

## Caveats

- Built against Claude Code 2.1.316. It relies on `claude remote-control` flags and on the wording of its error messages (`FATAL_RE` in `bin/rc-health`), neither of which is a stable interface. Updates come from npm's `latest` release through `rc-update`, which reverts if the servers come back unhealthy; rerun `tests/acceptance.md` after updates you care about.
- Anyone who controls your claude.ai account, Anthropic's relay or the Claude Code npm package can run commands on the gateway and reach whatever it can reach on your network. Restrict its egress and credentials; see "If Anthropic, the account or Claude Code is compromised" in `docs/design.md`.
- The profile names `cc-home` and `cc-work` are fixed in `bootstrap/bootstrap.sh`; `systemd/sudoers.d/claude-rc` lists only `cc-home`, so a second profile needs its lines added there before the control page can act on it. `bootstrap.sh` creates only `cc-home` unless run with `PROFILES="cc-home cc-work"`.

## Layout

```
proxmox/     create-lxc.sh, snapshot.sh, firewall.sh   run on the Proxmox host
bootstrap/   bootstrap.sh, bootstrap-tailscale.sh, profile-login.sh   run in the container
systemd/     claude-rc@.service, alert unit, health and update services + timers, sudoers
bin/         rc-start, rc-health, rc-alert, rc-update, rc-inspect, ntfy-send -> /usr/local/bin
rcctl/       Go control page (phase 3); make rcctl builds dist/rcctl
profiles/    settings.json (-> /etc/claude-code/managed-settings.json), hooks/, workdir-CLAUDE.md
etc/         claude-rc/*.env.example -> /etc/claude-rc/<profile>.env (never committed); default/rcctl.example
docs/        design.md: architecture, components, DoD
tests/       acceptance.md checklist; results/<tag>.md per release; docker/*.sh (make test-docker)
Makefile     deploy TAG=vX.Y | rollback | status | verify | rcctl | test-docker
```

## Bring-up (home profile)

On the Proxmox host, with a dedicated directory to share with the gateway (it becomes `/mnt/lab`; nothing else on the host is mounted):

```bash
CTID=<ctid> STORAGE=local-lvm LAB_SHARE=/<pool>/lab-share ./proxmox/create-lxc.sh
LAN_CIDR=192.168.1.0/24 DNS=<resolver> ./proxmox/firewall.sh enable <ctid>   # optional egress firewall; DNS is the resolver the container gets from DHCP
```

In the container (`pct enter <ctid>` or SSH as root):

```bash
git clone https://github.com/andy-wilson/claude-gw /opt/claude-gw
cd /opt/claude-gw && make bootstrap
tailscale up --ssh=false
LAN_CIDR=192.168.1.0/24 bootstrap/bootstrap-tailscale.sh   # LAN subnet(s) allowed to SSH in
cp etc/claude-rc/cc-home.env.example /etc/claude-rc/cc-home.env && $EDITOR /etc/claude-rc/cc-home.env
bootstrap/profile-login.sh cc-home        # interactive: login, consent, trust
make deploy TAG=$(git describe --tags --abbrev=0)   # latest release
make status
PROFILE=cc-home ntfy-send low "claude-gw" "test"   # should arrive on the phone
```

Then on the phone: Claude app → Code → the card named by `RC_NAME` (`home-claude-gw` in the example) → start a session. Turn on Trusted Devices for the account, then restart the server (`systemctl restart claude-rc@cc-home` or the control page): only sessions started after the toggle are protected. Work through `tests/acceptance.md`.

## Operations

| Task | Command |
| --- | --- |
| Back up before any change | `proxmox/snapshot.sh take <ctid> <slug>` (host, vzdump) |
| Deploy a release | `git fetch --tags && make deploy TAG=vX.Y` |
| Roll back | `make rollback` (previous tag) or `proxmox/snapshot.sh back <ctid> <volid>` (whole container) |
| Know a deploy landed | `make deploy` and `make rollback` end with one push: low "claude-gw deployed <tag> (was <tag>)" as soon as every server is healthy and up 10 s, or high "NOT healthy" after 60 s |
| Health / what is deployed | `make status` |
| Watch a server's terminal | `sudo -u cc-home tmux -L rc-cc-home attach` (detach: `Ctrl-b d`; `Ctrl-c` stops the server) |
| SSH from the phone (last resort) | Add the phone's public key to root's `authorized_keys` in the container. With the Tailscale app connected, `ssh root@<tailnet IP>` (the short name may not resolve on cellular); in Blink name the key (`ssh -i <key>` or a saved host), as its agent offers none by default |
| Re-run the interactive logins | `bootstrap/profile-login.sh cc-home` |
| Re-auth a claude.ai connector | `sudo -u cc-home env CLAUDE_CONFIG_DIR=/home/cc-home/.claude-cc-home claude mcp login "<name>" --no-browser` |
| Update Claude Code | `rc-update` (newer `latest` only; `CLAUDE_CHANNEL=stable rc-update` for the slower channel) or `rc-update <version>` (any version, including back); restarts the servers and reverts if unhealthy |
| Auto-update nightly (opt-in) | `systemctl enable --now claude-rc-update.timer` (`disable --now` to stop); ntfy low on success, high on revert |
| Egress firewall | `proxmox/firewall.sh status\|enable\|disable <ctid>` (host). Off means sessions can reach your whole LAN and the Proxmox host; `disable` says so and asks you to type the CTID |
| Let sessions reach a LAN host | `proxmox/firewall.sh allow <ctid> <ip\|cidr> [comment]` (host, all ports, /16 at widest); `remove`, `list` |
| Control page (opt-in) | laptop: `make rcctl`, copy `dist/rcctl` to `/opt/claude-gw/dist/` in the container, `make deploy`. Then `cp etc/default/rcctl.example /etc/default/rcctl`, set `RCCTL_ALLOW` to your Tailscale login, `systemctl enable --now rcctl`, and open the login URL from `journalctl -u rcctl` once. Needs HTTPS certificates on in the tailnet. Page: `https://claude-gw-ctl.<tailnet>.ts.net` |
| Tidy the alert history | Control page, Alerts: Clear history hides everything up to now (the journal keeps it); current problems stay |
| Silence health alerts | Control page, Alerts: 1 h or 4 h. The urgent "down" alert still sends; permission-prompt notifications are not affected |
| Clean up session worktrees | Control page, Worktrees: Prune removes each worktree that is merged into `main`, has no changed, untracked or ignored files, and has no session in it or using it in the last 24 h, and deletes its branch |

## Alerts

ntfy.sh topic per profile (`NTFY_TOPIC` in the env file). Bodies are deliberately generic.

| Priority | Source | Meaning |
| --- | --- | --- |
| urgent | `claude-rc-alert@` (systemd OnFailure) | Unit hit its restart limit. Sent once per outage, also during a silence; `rc-health` keeps retrying every 2 min and sends "recovered" when it comes back |
| high | `rc-health` | Two consecutive missed checks, a fatal pattern in the log, or the client unable to reach Anthropic for 4 min (`DISCONNECT_ALERT_AFTER`; no restart, it is retrying) |
| high / default / low | Claude `Notification` hook | Permission prompt / question / idle. Sent by the session as the profile user, so not in the `rc-alert` journal or on the control page |
| low | `rc-health` | Recovered |

## Warranty

No warranty is implied. Use at your own risk. This software runs an AI agent with access to your lab; you are responsible for what it can reach and what it does.

## License

MIT, see `LICENSE`.
