# CLAUDE.md — claude-gw repo

This repo builds and operates the home-lab Claude Code Remote Control gateway. `README.md` describes the design;
`tests/acceptance.md` is the source of truth for what done means.

## How to work here

- Plan before executing. For anything beyond a one-line fix, state the steps and the
  rollback before running them, and wait for a go.
- Definition of done is `tests/acceptance.md`. A change is not done until the relevant
  ATs pass and the result is written to `tests/results/<tag>.md`.
- Full change control: snapshot the container before touching it
  (`proxmox/snapshot.sh take <CTID> <slug>` on the host), tag after
  (`git tag vX.Y`), deploy only from a tag (`make deploy TAG=vX.Y`).
- Go is the preferred language for anything beyond shell (phase 3 `rcctl`). Keep shell
  POSIX-ish bash, `set -euo pipefail`, shellcheck-clean.
- Keep replies short and lead with the result; the operator is often on a phone.

## Hard rules

1. Never write `/etc/claude-rc/*.env` from this repo or commit one. They hold the ntfy token.
2. Never use `--permission-mode bypassPermissions` on the gateway, and never put an API key,
   `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_BASE_URL` in a profile env: Remote Control refuses them.
3. The three interactive prompts (`claude auth login`, Remote Control consent, workspace trust)
   must be done by the operator at a terminal via `bootstrap/profile-login.sh`. Do not try to
   automate or bypass them.
4. `/mnt/lab` is the only lab filesystem the gateway mounts. Do not add other bind mounts.
5. Work in a branch; `main` moves only by merge, and tags only on `main`.
6. If an acceptance test fails after a deploy, roll back (`make rollback`) rather than fix forward,
   unless the fix is a one-line reversible change.

## Where things run

| Script | Runs on | As |
| --- | --- | --- |
| `proxmox/*.sh` | Proxmox host | root |
| `bootstrap/*.sh`, `make *` | inside the container | root |
| `bin/rc-start` | inside, via tmux from systemd | profile user (`cc-home`) |
| `bin/rc-health`, `bin/rc-alert` | inside, via timer / OnFailure | root |
| `profiles/hooks/*.sh` | inside each Claude session | profile user |

## Verifying without a container

`make verify` runs `bash -n`, shellcheck and `systemd-analyze verify` on everything. Run it
before every commit. `jq . profiles/settings.json` must succeed.
