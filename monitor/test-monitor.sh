#!/usr/bin/env bash
# End-to-end test of postfiat-monitor on a live node:
#   baseline OK -> stop container -> failure alert -> repeat (suppressed) ->
#   start container -> wait for full -> recovery alert.
# Usage: sudo bash test-monitor.sh 2>&1 | tee monitor-test.log

set -uo pipefail
log() { printf '\n[%s] === %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
run_monitor() { systemctl start postfiat-monitor.service; tail -n 2 /var/log/postfiat-monitor.log; }

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

log "Environment"
. /etc/os-release && echo "OS: $PRETTY_NAME"
systemctl list-timers postfiat-monitor.timer --no-pager
grep -E '^(NTFY_SERVER|NODE_LABEL|HEALTHY_STATES|REMIND_MINUTES)=' /etc/postfiat-monitor.env
echo "NTFY_TOPIC=<redacted>"

log "1. Baseline check (expect OK, no alert)"
run_monitor

log "2. Deliberate failure: docker stop postfiatd"
docker stop postfiatd
run_monitor

log "3. Next cycle while still down (expect alert suppressed)"
run_monitor

log "4. Restore: docker start postfiatd"
docker start postfiatd

log "5. Waiting for server_state=full (up to 15 min)"
for _ in $(seq 1 90); do
  st="$(docker exec postfiatd curl -s --max-time 5 http://localhost:5005/ -X POST \
        -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' 2>/dev/null \
        | jq -r '.result.info.server_state // empty' 2>/dev/null)"
  echo "  server_state: ${st:-unavailable}"
  [ "$st" = "full" ] || [ "$st" = "proposing" ] && break
  sleep 10
done

log "6. Recovery check (expect RECOVERED + ntfy recovery alert)"
run_monitor

log "Monitor log (this test)"
tail -n 12 /var/log/postfiat-monitor.log

log "journalctl -u postfiat-monitor (last 20)"
journalctl -u postfiat-monitor --no-pager -n 20 -o short-iso
