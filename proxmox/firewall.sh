#!/usr/bin/env bash
# Egress firewall for the claude-gw container. Run ON THE PROXMOX HOST, as root.
# It lives on the host so a compromised container cannot turn it off.
# With it on, the container reaches DNS, the internet (tcp 22/80/443, Tailscale udp) and the
# lab_allow set; every other private address is dropped, this host included.
#
#   ./firewall.sh status <CTID>
#   LAN_CIDR="192.168.1.0/24" DNS=192.168.1.1 ./firewall.sh enable <CTID>   (first time; then just enable)
#   ./firewall.sh disable <CTID> [--confirm <CTID>]   -> warns, asks you to type the CTID
#   ./firewall.sh allow  <CTID> <ipv4|cidr> [comment] -> all ports; /16 at widest; FORCE=1 to include this host
#   ./firewall.sh remove <CTID> <ipv4|cidr>
#   ./firewall.sh list   <CTID>
# Changes apply within about 10 s (pve-firewall polls). IPv4 only: the container has no IPv6 route.
set -euo pipefail

cmd="${1:?status|enable|disable|allow|remove|list}"; CTID="${2:?CTID}"
FW=/etc/pve/firewall
CTFW="$FW/$CTID.fw"
HOSTFW="/etc/pve/nodes/$(hostname)/host.fw"

die() { echo "$*" >&2; exit 1; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
log() { logger -t claude-gw-firewall "CT $CTID: $* (by ${SUDO_USER:-$(id -un)}${SSH_CLIENT:+ from ${SSH_CLIENT%% *}})"; }
opt() { if [ -f "$1" ]; then sed -n "s/^$2: *//p" "$1" | head -n1; fi; }
net0() { pct config "$CTID" | sed -n 's/^net0: //p'; }
# /etc/pve is pmxcfs: write in place rather than sed -i's rename.
rewrite() { local tmp; tmp="$(mktemp)"; cat > "$tmp"; cat "$tmp" > "$1"; rm -f "$tmp"; }
set_enable() { sed "s/^enable: .*/enable: $1/" "$CTFW" | rewrite "$CTFW"; }
need_ctfw() { [ -f "$CTFW" ] || die "no $CTFW yet: run '$0 enable $CTID' first"; }

ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
in_cidr() {  # in_cidr <ip> <ip[/prefix]>
  local p="${2#*/}" m; [ "$p" = "$2" ] && p=32
  m=$(( (0xffffffff << (32 - p)) & 0xffffffff ))
  [ $(( $(ip2int "$1") & m )) -eq $(( $(ip2int "${2%/*}") & m )) ]
}
valid() {  # valid <ip[/prefix]> <widest prefix>
  local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$' i
  [[ $1 =~ $re ]] || return 1
  for i in 1 2 3 4; do [ $((10#${BASH_REMATCH[$i]})) -le 255 ] || return 1; done
  [ "${BASH_REMATCH[6]:-32}" -ge "$2" ] && [ "${BASH_REMATCH[6]:-32}" -le 32 ]
}

list() { need_ctfw; awk '/^\[/{s=($0 ~ /^\[IPSET lab_allow\]/); next} s && NF' "$CTFW"; }

status() {
  local c e n
  c="$(opt "$FW/cluster.fw" enable)"; e="$(opt "$CTFW" enable)"; n="$(net0)"
  if [ "$c" = 1 ] && [ "$e" = 1 ] && [[ $n == *firewall=1* ]]; then
    echo "egress firewall for CT $CTID: ENABLED"
  else
    red "egress firewall for CT $CTID: DISABLED (datacenter=${c:-off} ct=${e:-none} net0 firewall=$([[ $n == *firewall=1* ]] && echo 1 || echo 0))"
  fi
  pve-firewall status
  if [ -f "$CTFW" ]; then echo "lab_allow:"; list | sed 's/^/  /'; fi
}

template() {
  cat <<EOF
[OPTIONS]
enable: 1
dhcp: 1
policy_in: DROP
policy_out: DROP

[IPSET lab_allow] # LAN hosts sessions may reach, all ports (firewall.sh allow/remove)

[IPSET private] # dropped on the way out unless a rule above the DROP matches
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
169.254.0.0/16

[IPSET ssh_from] # ranges allowed to SSH in (LAN_CIDR)
$(printf '%s\n' "${cidrs[@]}")

[RULES]

IN SSH(ACCEPT) -source +ssh_from
IN ACCEPT -source +private -p udp -dport 41641 # Tailscale direct
IN Ping(ACCEPT) -source +private
OUT DNS(ACCEPT) -dest $DNS
OUT ACCEPT -dest +lab_allow
OUT ACCEPT -dest +private -p udp -dport 41641 # Tailscale direct to LAN peers
OUT DROP -dest +private
OUT HTTPS(ACCEPT)
OUT HTTP(ACCEPT)
OUT SSH(ACCEPT)
OUT ACCEPT -p udp -dport 3478 # Tailscale STUN
OUT ACCEPT -p udp -dport 41641 # Tailscale direct
EOF
}

case "$cmd" in
  status) status ;;
  list) list ;;
  enable)
    if [ ! -f "$CTFW" ]; then
      : "${LAN_CIDR:?first enable: set LAN_CIDR (ranges allowed to SSH in) and DNS (resolver in the container)}"
      : "${DNS:?first enable: set DNS to the resolver in the container (see its /etc/resolv.conf)}"
      read -ra cidrs <<< "${LAN_CIDR//,/ }"
      for c in "${cidrs[@]}"; do valid "$c" 8 || die "LAN_CIDR: not an IPv4 range: $c"; done
      valid "$DNS" 32 || die "DNS: not an IPv4 address: $DNS"
    fi
    # The datacenter switch also turns on this host's own firewall: keep that off, so only
    # guests with firewall=1 on a NIC (this one) are affected.
    [ -f "$HOSTFW" ] || printf '[OPTIONS]\nenable: 0\n' | rewrite "$HOSTFW"
    if [ ! -f "$FW/cluster.fw" ]; then
      printf '[OPTIONS]\nenable: 1\npolicy_in: ACCEPT\npolicy_out: ACCEPT\n' | rewrite "$FW/cluster.fw"
    elif [ "$(opt "$FW/cluster.fw" enable)" != 1 ]; then
      die "$FW/cluster.fw exists with the firewall off; enable it yourself after checking what else it turns on"
    fi
    if [ -f "$CTFW" ]; then set_enable 1; else template | rewrite "$CTFW"; fi
    n="$(net0)"
    if [[ $n != *firewall=1* ]]; then
      echo "setting firewall=1 on net0 (the container's network drops for a moment)"
      pct set "$CTID" -net0 "${n//,firewall=0/},firewall=1"
    fi
    log enabled
    status
    ;;
  disable)
    need_ctfw
    red "WARNING: this turns off the egress firewall for CT $CTID."
    cat <<EOF
Any Claude session on the gateway, and anyone who controls its claude.ai account, Anthropic's
relay or the Claude Code npm package, will be able to reach every host on your LAN, this
Proxmox host's web UI and SSH, and any port on the internet. See docs/design.md,
"If Anthropic, the account or Claude Code is compromised". Re-enable with: $0 enable $CTID
EOF
    if [ "${3:-}" != --confirm ] || [ "${4:-}" != "$CTID" ]; then
      read -r -p "Type $CTID to disable: " a || true
      [ "${a:-}" = "$CTID" ] || die "not disabled"
    fi
    set_enable 0
    log DISABLED
    status
    ;;
  allow)
    need_ctfw
    cidr="${3:?allow <CTID> <ipv4|cidr> [comment]}"; shift 3
    comment="$*"; comment="${comment//[^A-Za-z0-9 ._:-]/}"
    valid "$cidr" 16 || die "not an IPv4 address or a /16 to /32 range: $cidr"
    for h in $(ip -o -4 addr show | awk '{print $4}'); do
      if in_cidr "${h%/*}" "$cidr" && [ "${FORCE:-}" != 1 ]; then
        die "$cidr includes this Proxmox host ($h); rerun with FORCE=1 to allow it anyway"
      fi
    done
    list | awk -v c="$cidr" '$1 == c {f=1} END {exit !f}' && die "$cidr is already allowed"
    awk -v line="$cidr${comment:+ # $comment}" '{print} /^\[IPSET lab_allow\]/{print line}' "$CTFW" | rewrite "$CTFW"
    log "allowed $cidr${comment:+ ($comment)}"
    list
    ;;
  remove)
    need_ctfw
    cidr="${3:?remove <CTID> <ipv4|cidr>}"
    list | awk -v c="$cidr" '$1 == c {f=1} END {exit !f}' || die "$cidr is not in lab_allow"
    awk -v c="$cidr" '/^\[/{s=($0 ~ /^\[IPSET lab_allow\]/)} !(s && $1 == c)' "$CTFW" | rewrite "$CTFW"
    log "removed $cidr"
    list
    ;;
  *) die "unknown command $cmd" ;;
esac
