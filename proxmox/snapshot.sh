#!/usr/bin/env bash
# Back up or roll back the claude-gw container. Run ON THE PROXMOX HOST.
# Uses vzdump, not pct snapshot: the /mnt/claude-gw bind mount makes pct snapshot unavailable.
# vzdump skips bind mounts, so lab data is never backed up or rolled back by this script.
#
#   ./snapshot.sh take  <CTID> <change-slug>      -> vzdump backup, notes pre-YYYYMMDD-HHMM-<slug>
#   ./snapshot.sh list  <CTID>
#   ./snapshot.sh back  <CTID> <volid>            -> stop, pct restore --force, start
#   ./snapshot.sh prune <CTID> [keep=5]           -> keep the newest <keep> backups of this CT
set -euo pipefail

cmd="${1:?take|list|back|prune}"; CTID="${2:?CTID}"
STORE="${BACKUP_STORAGE:-local}"

case "$cmd" in
  take)
    slug="${3:?change slug, e.g. claude-update}"
    name="pre-$(date +%Y%m%d-%H%M)-${slug//[^a-zA-Z0-9]/-}"
    vzdump "$CTID" --mode snapshot --storage "$STORE" --compress zstd --notes-template "$name"
    pvesm list "$STORE" --content backup --vmid "$CTID" | tail -n1
    ;;
  list)
    pvesh get "/nodes/$(hostname)/storage/$STORE/content" --content backup --vmid "$CTID" --output-format text
    ;;
  back)
    vol="${3:?backup volid from list, e.g. local:backup/vzdump-lxc-<ctid>-....tar.zst}"
    rootstore=$(pct config "$CTID" | sed -n 's/^rootfs: \([^:]*\):.*/\1/p')
    echo "Restoring CT $CTID from $vol (rootfs to $rootstore) in 5s (Ctrl-C to abort)"; sleep 5
    pct stop "$CTID" 2>/dev/null || true
    pct restore "$CTID" "$vol" --force 1 --storage "$rootstore"
    pct start "$CTID"
    ;;
  prune)
    # ponytail: prunes every backup of this CT on $STORE, including any from scheduled jobs
    pvesm prune-backups "$STORE" --vmid "$CTID" --keep-last "${3:-5}"
    ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
