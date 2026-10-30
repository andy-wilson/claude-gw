# claude-gw

Always-on Claude Code **Remote Control** gateway for a home Proxmox lab. One unprivileged LXC runs `claude remote-control` in server mode per account profile, supervised by systemd + tmux, so you can start a session against your lab from the Claude mobile app or claude.ai/code anywhere, with no SSH step. Tailscale provides the fallback SSH path and ntfy.sh pushes alerts to your phone when supervision cannot recover.

Sessions flow through Anthropic's relay (the gateway polls outbound), so nothing is exposed at the router. Each profile is a separate Linux user with its own `CLAUDE_CONFIG_DIR`, so two accounts never share credentials or transcripts. The only lab filesystem a session can touch is one dedicated share bind-mounted at `/mnt/lab`.

Architecture diagrams, component design, security model, change control, definition of done and phases: [`docs/design.md`](docs/design.md).

## Requirements and caveats

- A claude.ai subscription with Remote Control (Pro/Max, or Team/Enterprise with it enabled by an Owner). API keys and long-lived tokens are refused by Remote Control.
- Proxmox VE for `proxmox/*.sh`; everything else needs only Debian 12 with systemd.
- A Tailscale account and an ntfy.sh topic (with an access token).
- Built against Claude Code 2.1.312. It relies on `claude remote-control` flags and on the wording of its error messages (`FATAL_RE` in `bin/rc-health`), neither of which is a stable interface. Pin the version and rerun `tests/acceptance.md` after every update.
- The profile names `cc-home` and `cc-work` are fixed in `bootstrap/bootstrap.sh` and `systemd/sudoers.d/claude-rc`; adding another means editing both.

## Layout

```
proxmox/     create-lxc.sh, snapshot.sh         run on the Proxmox host
bootstrap/   bootstrap.sh, bootstrap-tailscale.sh, profile-login.sh   run in the container
systemd/     claude-rc@.service, alert unit, health service + timer, sudoers
bin/         rc-start, rc-health, rc-alert, ntfy-send   -> /usr/local/bin
profiles/    settings.json (-> /etc/claude-code/managed-settings.json), hooks/, workdir-CLAUDE.md
etc/         *.env.example  -> copy to /etc/claude-rc/<profile>.env (never committed)
docs/        design.md: architecture, components, DoD
tests/       acceptance.md checklist; results/<tag>.md committed per release
Makefile     deploy TAG=vX.Y | rollback | status | verify
```

## Bring-up (home profile)

On the Proxmox host:

```bash
CTID=<ctid> STORAGE=local-lvm TEMPLATE=debian-12-standard_12.12-1_amd64.tar.zst LAB_SHARE=/<pool>/lab-share ./proxmox/create-lxc.sh
```

In the container (`pct enter <ctid>` or SSH as root):

```bash
git clone https://github.com/andy-wilson/claude-gw /opt/claude-gw
cd /opt/claude-gw && make bootstrap
tailscale up --ssh=false
LAN_CIDR=192.168.1.0/24 bootstrap/bootstrap-tailscale.sh   # LAN subnet(s) allowed to SSH in
cp etc/claude-rc/cc-home.env.example /etc/claude-rc/cc-home.env && $EDITOR /etc/claude-rc/cc-home.env
bootstrap/profile-login.sh cc-home        # interactive: login, consent, trust
git tag v0.1 && make deploy TAG=v0.1
make status
```

Then on the phone: Claude app → Code → the `home-claude-gw` card → start a session.

## Day 2

| Task | Command |
| --- | --- |
| Back up before any change | `proxmox/snapshot.sh take <ctid> <slug>` (host, vzdump) |
| Deploy a release | `make deploy TAG=v0.2` |
| Roll back | `make rollback` or `proxmox/snapshot.sh back <ctid> <volid>` |
| Health / what is deployed | `make status` |
| Watch a server's terminal | `sudo -u cc-home tmux -L rc-cc-home attach` (detach: `Ctrl-b d`) |
| Re-auth a claude.ai connector | `sudo -u cc-home env CLAUDE_CONFIG_DIR=/home/cc-home/.claude-cc-home claude mcp login "<name>" --no-browser` |
| Update Claude Code | snapshot → `npm i -g @anthropic-ai/claude-code@<ver>` → `make deploy` → run `tests/acceptance.md` → tag |

## Alerts

ntfy.sh topic per profile (`NTFY_TOPIC` in the env file). Bodies are deliberately generic.

| Priority | Source | Meaning |
| --- | --- | --- |
| urgent | `claude-rc-alert@` (systemd OnFailure) | Unit hit its restart limit; needs a human |
| high | `rc-health` | Two consecutive missed checks, or a fatal pattern in the log |
| high / default / low | Claude `Notification` hook | Permission prompt / question / idle |
| low | `rc-health` | Recovered |

## License

MIT, see `LICENSE`.
