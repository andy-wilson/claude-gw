#!/usr/bin/env bash
# Create the claude-gw LXC on a Proxmox node.
# Run ON THE PROXMOX HOST as root. Idempotent-ish: refuses to run if CTID exists.
#
# Usage:
#   CTID=120 STORAGE=local-lvm LAB_SHARE=/srv/lab ./create-lxc.sh
#
# Everything is a variable so the local Claude Code session can set them
# from the lab's conventions rather than editing this file.
set -euo pipefail

CTID="${CTID:?set CTID, e.g. 120}"
HOSTNAME="${HOSTNAME_CT:-claude-gw}"
STORAGE="${STORAGE:-local-lvm}"               # rootfs storage
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"  # where templates live
TEMPLATE="${TEMPLATE:-}"                       # default: newest debian-13-standard
BRIDGE="${BRIDGE:-vmbr0}"
IP="${IP:-dhcp}"                               # or 192.168.1.50/24
GW="${GW:-}"                                   # only needed with a static IP
CORES="${CORES:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
SWAP_MB="${SWAP_MB:-512}"
DISK_GB="${DISK_GB:-32}"
LAB_SHARE="${LAB_SHARE:?set LAB_SHARE to the host path of the dedicated lab share}"
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/authorized_keys}"  # seeded into root for first login

if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists; refusing to overwrite. Use proxmox/snapshot.sh and pct destroy deliberately." >&2
  exit 1
fi

if [ -z "$TEMPLATE" ]; then
  pveam update
  TEMPLATE="$(pveam available --section system | awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' | sort -V | tail -n1)"
  [ -n "$TEMPLATE" ] || { echo "no debian-13-standard template listed by pveam; set TEMPLATE=" >&2; exit 1; }
fi
if [ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]; then
  echo "Downloading template $TEMPLATE"
  pveam update
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

NET="name=eth0,bridge=$BRIDGE,ip=$IP"
[ -n "$GW" ] && NET="$NET,gw=$GW"

pct create "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" \
  --rootfs "$STORAGE:$DISK_GB" \
  --net0 "$NET" \
  --onboot 1 \
  --start 0 \
  --ssh-public-keys "$SSH_PUBKEY" \
  --description "Claude Code Remote Control gateway. See github.com/andy-wilson/claude-gw"

# Dedicated lab share: the ONLY lab filesystem the gateway sees (design decision 28 Oct).
# Unprivileged CT: container uid N maps to host uid 100000+N. The bootstrap creates
# cc-home as uid 1001 and cc-work as uid 1002, group cc-lab gid 1010.
# Make the share writable by host gid 101010 so both profiles can write.
mkdir -p "$LAB_SHARE"
chgrp 101010 "$LAB_SHARE" || true
chmod 2775 "$LAB_SHARE"
pct set "$CTID" -mp0 "$LAB_SHARE,mp=/mnt/lab"

# Tailscale in an unprivileged LXC needs /dev/net/tun passed through.
CONF="/etc/pve/lxc/$CTID.conf"
if ! grep -q 'dev/net/tun' "$CONF"; then
  cat >> "$CONF" <<'EOF'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
fi

pct start "$CTID"
echo "Waiting for network..."
for _ in $(seq 1 30); do
  if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done

# Baseline backup before anything is installed (pct snapshot is unavailable with a bind mount).
vzdump "$CTID" --mode snapshot --storage local --compress zstd --notes-template "pre-bootstrap"

echo
echo "CT $CTID ($HOSTNAME) is up. Next:"
echo "  pct push $CTID bootstrap/bootstrap.sh /root/bootstrap.sh"
echo "  pct exec $CTID -- bash /root/bootstrap.sh"
echo "or clone the repo inside the container and run make bootstrap."
