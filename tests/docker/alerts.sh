#!/usr/bin/env bash
# rc-alert (silence, journal record, failed send) and rc-health (state moves only once sent),
# with systemctl, sudo, pgrep, ntfy-send and logger stubbed.
# Run by `make test-docker` in a Debian 13 container with the repo at /r (read-only).
set -uo pipefail
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

for i in 1 2 3 4 5; do apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq jq >/dev/null 2>&1 && break; sleep 5; done
install -m 0755 /r/bin/rc-alert /r/bin/rc-health /usr/local/bin/
mkdir -p /var/lib/rcctl /var/lib/claude-rc /var/log/claude-rc /etc/systemd/system/multi-user.target.wants /stub
printf '#!/bin/sh\necho "$*" >> /tmp/sent; [ -z "$NTFY_FAIL" ]\n' > /usr/local/bin/ntfy-send
printf '#!/bin/sh\nshift 2; echo "$*" >> /tmp/journal\n' > /usr/local/bin/logger
chmod +x /usr/local/bin/ntfy-send /usr/local/bin/logger
export PROFILE=cc-home UNIT_FAILED_WAIT=0
# systemctl is-failed answers from $FAILED (default: the unit is failed).
printf '#!/bin/sh\ncase "$1" in is-failed) [ "${FAILED:-yes}" = yes ];; *) :;; esac\n' > /usr/local/bin/systemctl; chmod +x /usr/local/bin/systemctl
last() { tail -n1 /tmp/journal; }

echo $(( $(date +%s) + 600 )) > /var/lib/rcctl/silence-until
rc-alert down 2 >/dev/null; rc=$?
check "silenced alert exits 3" '[ $rc = 3 ]'
check "silenced alert not sent" '[ ! -s /tmp/sent ]'
check "silenced alert recorded" '[ "$(last)" = "profile=cc-home kind=down priority=high result=silenced what=unhealthy, 2 missed checks" ]'
FAILED=no rc-alert unit-failed >/dev/null; rc=$?
check "no urgent alert when the unit is running again (forced restart)" '[ $rc = 0 ] && ! grep -q "^urgent" /tmp/sent 2>/dev/null'
rc-alert unit-failed; rc=$?
check "urgent alert sends through a silence" '[ $rc = 0 ] && grep -q "^urgent claude-gw: cc-home DOWN" /tmp/sent'
check "urgent alert recorded as sent" '[ "$(last)" = "profile=cc-home kind=unit-failed priority=urgent result=sent what=DOWN, not restarting" ]'
check "urgent alert arms rc-health's recovery" '[ "$(jq -c .alerted /var/lib/claude-rc/health-cc-home.json)" = true ]'
echo '{"misses":3,"alerted":false,"degraded":""}' > /var/lib/claude-rc/health-cc-home.json
rc-alert unit-failed >/dev/null
check "urgent alert keeps the rest of the state" '[ "$(jq -c "[.misses, .alerted, .urgent]" /var/lib/claude-rc/health-cc-home.json)" = "[3,true,true]" ]'
n=$(grep -c "^urgent" /tmp/sent); rc-alert unit-failed >/dev/null
check "urgent alert sent once per outage" '[ "$(grep -c "^urgent" /tmp/sent)" = "$n" ]'
rm /var/lib/claude-rc/health-cc-home.json
rm /var/lib/rcctl/silence-until
NTFY_FAIL=1 rc-alert recovered; rc=$?
check "failed send exits non-zero and is recorded" '[ $rc = 1 ] && [ "$(last)" = "profile=cc-home kind=recovered priority=low result=failed what=recovered" ]'
rc-alert deployed "v0.6.3 (was v0.6.2)"; rc=$?
check "deploy notice sent low and recorded" '[ $rc = 0 ] && grep -q "^low claude-gw deployed v0.6.3 (was v0.6.2)" /tmp/sent && [ "$(last)" = "profile=cc-home kind=deployed priority=low result=sent what=deployed v0.6.3 (was v0.6.2), healthy" ]'
rc-alert deploy-unhealthy "v0.6.3 (was v0.6.2)"
check "unhealthy deploy notice is high and says so" 'grep -q "^high claude-gw deployed v0.6.3 (was v0.6.2): cc-home NOT healthy" /tmp/sent'
rm -f /var/lib/claude-rc/health-cc-home.json
rc-alert bogus 2>/dev/null; rc=$?
check "unknown kind exits 2" '[ $rc = 2 ]'

# rc-health: the alert flag is set only when rc-alert succeeds.
touch /etc/systemd/system/multi-user.target.wants/claude-rc@cc-home.service
cat > /stub/systemctl <<'X'
#!/bin/sh
case "$1" in is-active) echo "$ACTIVE"; [ "$ACTIVE" = active ];; show) echo /x;; *) :;; esac
X
printf '#!/bin/sh\ncase "$*" in *has-session*) [ "$ACTIVE" = active ];; *) :;; esac\n' > /stub/sudo
printf '#!/bin/sh\n[ "$ACTIVE" = active ]\n' > /stub/pgrep
printf '#!/bin/sh\necho "$1" >> /tmp/alerts; exit $ALERT_RC\n' > /stub/rc-alert
chmod +x /stub/*
state() { jq -c '[.misses, .alerted]' /var/lib/claude-rc/health-cc-home.json; }
health() { ACTIVE=$1 ALERT_RC=$2 rc-health >/dev/null; }
# rc-health puts /usr/local/bin first on PATH, so the stubs go there.
for c in systemctl sudo pgrep rc-alert; do cp /stub/$c /usr/local/bin/$c; done
health inactive 3; health inactive 3
check "silenced down alert leaves alerted false" '[ "$(state)" = "[2,false]" ]'
health inactive 0
check "sent down alert sets alerted" '[ "$(state)" = "[3,true]" ]'
health inactive 0
check "no repeat once sent" '[ "$(grep -c down /tmp/alerts)" = 2 ]'
health active 1
check "failed recovery keeps the state" '[ "$(state)" = "[4,true]" ]'
health active 0
check "sent recovery resets the state" '[ "$(state)" = "[0,false]" ]'

echo "$fails failure(s)"; exit $((fails > 0))
