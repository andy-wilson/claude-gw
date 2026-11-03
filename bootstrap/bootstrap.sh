#!/usr/bin/env bash
# Bootstrap the claude-gw container. Run INSIDE the container as root, once.
# Safe to re-run: every step checks before it changes anything.
#
# What it does:
#   1. OS packages, Node LTS, Claude Code (pinned), tmux, jq, git, tailscale
#   2. Profile users cc-home (1001) and cc-work (1002), group cc-lab (1010)
#   3. Directories: /etc/claude-rc, /var/log/claude-rc, /var/lib/claude-rc
#   4. sshd hardened to key-only (any source until tailscale is up;
#      bootstrap-tailscale.sh limits logins to the tailnet and LAN)
#
# What it does NOT do (interactive, see profile-login.sh):
#   - claude auth login per profile
#   - the Remote Control consent and workspace-trust prompts
#   - tailscale up
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/claude-gw}"
CLAUDE_VERSION="${CLAUDE_VERSION:-latest}"   # npm channel or exact version; later updates: rc-update
NODE_MAJOR="${NODE_MAJOR:-22}"
PROFILES="${PROFILES:-cc-home}"              # add cc-work later if phase 4 happens

log() { printf '\n==> %s\n' "$*"; }

log "OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q curl ca-certificates gnupg git tmux jq sudo unzip \
  openssh-server rsync make procps iproute2 less vim-tiny

log "Node $NODE_MAJOR"
if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" != "$NODE_MAJOR" ]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  apt-get install -y -q nodejs
fi
node -v

log "Claude Code ($CLAUDE_VERSION)"
npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"
claude --version | tee /etc/claude-rc-version 2>/dev/null || true

log "Tailscale"
if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

log "Group and profile users"
getent group cc-lab >/dev/null || groupadd -g 1010 cc-lab
mkuser() {
  local name=$1 uid=$2
  if ! id "$name" >/dev/null 2>&1; then
    useradd -m -u "$uid" -g cc-lab -s /bin/bash "$name"
  fi
  install -d -m 0700 -o "$name" -g cc-lab "/home/$name/.ssh" "/home/$name/bin" \
    "/home/$name/.claude-$name" "/home/$name/work"
}
mkuser cc-home 1001
case " $PROFILES " in *" cc-work "*) mkuser cc-work 1002 ;; esac

log "Directories"
install -d -m 0750 /etc/claude-rc
install -d -m 0755 /var/log/claude-rc
install -d -m 0700 /var/lib/claude-rc
if [ -d /mnt/claude-gw ]; then
  chgrp cc-lab /mnt/claude-gw || true
  chmod 2775 /mnt/claude-gw || true
fi

log "sshd: keys only"
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-claude-gw.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
EOF
systemctl restart ssh

log "Repo"
if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Clone the repo to $REPO_DIR, then run: make -C $REPO_DIR deploy"
else
  echo "Repo present at $REPO_DIR"
fi

cat <<EOF

Bootstrap done. Remaining interactive steps:
  1. tailscale up --ssh=false            (authorise in the browser)
  2. $REPO_DIR/bootstrap/bootstrap-tailscale.sh   (sshd logins from tailnet + LAN only)
  3. cp $REPO_DIR/etc/claude-rc/cc-home.env.example /etc/claude-rc/cc-home.env && edit it
  4. $REPO_DIR/bootstrap/profile-login.sh cc-home  (claude login, consent, trust)
  5. make -C $REPO_DIR deploy TAG=<tag>
EOF
