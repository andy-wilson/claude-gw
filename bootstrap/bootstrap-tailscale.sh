#!/usr/bin/env bash
# Restrict sshd logins to the tailnet and the local LAN. Run INSIDE the container as root,
# after `tailscale up` has succeeded. sshd listens on all interfaces (the LAN address is
# DHCP, so binding to it would be fragile) and AllowUsers filters by source address.
# Console fallback if it goes wrong: pct enter <CTID> on the Proxmox host.
set -euo pipefail

LAN_CIDR="${LAN_CIDR:?set LAN_CIDR to the LAN subnet(s) allowed to SSH in, space-separated, e.g. 192.168.1.0/24}"
TAILNET_CIDRS="100.64.0.0/10 fd7a:115c:a1e0::/48"

tailscale ip -4 >/dev/null 2>&1 || { echo "tailscale has no address yet; run 'tailscale up' first" >&2; exit 1; }

allow=""
for c in $TAILNET_CIDRS $LAN_CIDR; do allow="$allow *@$c"; done

# Replaces the earlier tailnet-only ListenAddress setup.
rm -f /etc/ssh/sshd_config.d/20-tailnet-only.conf /etc/systemd/system/ssh.service.d/override.conf
rmdir /etc/systemd/system/ssh.service.d 2>/dev/null || true
cat > /etc/ssh/sshd_config.d/20-allowed-sources.conf <<EOF
AllowUsers$allow
EOF
systemctl daemon-reload
sshd -t
systemctl restart ssh
echo "sshd logins allowed from:$allow"
ss -tlnp | grep ':22 ' || true
echo "If you lose access: pct enter <CTID> on the Proxmox host and remove /etc/ssh/sshd_config.d/20-allowed-sources.conf"
