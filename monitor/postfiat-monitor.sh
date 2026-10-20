#!/usr/bin/env bash
# postfiat-monitor: runs postfiat-health, alerts via ntfy on failure, once on recovery.
# Installed to /usr/local/bin/postfiat-monitor and run by postfiat-monitor.timer.
#
# Unhealthy = postfiat-health exits non-zero OR server_state is not full/proposing.
# Alerts are de-duplicated: one alert when the node goes unhealthy, one recovery
# notice when it returns to healthy. Optional REMIND_MINUTES re-sends while down.

set -uo pipefail

ENV_FILE="${POSTFIAT_MONITOR_ENV:-/etc/postfiat-monitor.env}"
# shellcheck source=/dev/null
[ -r "$ENV_FILE" ] && . "$ENV_FILE"

NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
NODE_LABEL="${NODE_LABEL:-postfiat-node}"
HEALTHY_STATES="${HEALTHY_STATES:-full proposing}"
REMIND_MINUTES="${REMIND_MINUTES:-0}"
HEALTH_CMD="${HEALTH_CMD:-/usr/local/bin/postfiat-health}"
STATE_DIR="${STATE_DIR:-/var/lib/postfiat-monitor}"
LOG_FILE="${LOG_FILE:-/var/log/postfiat-monitor.log}"

STATE_FILE="$STATE_DIR/state"        # "ok" or "fail"
SINCE_FILE="$STATE_DIR/fail_since"   # epoch of first failure
LAST_ALERT_FILE="$STATE_DIR/last_alert"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"; }

notify() { # title priority tags message
  if [ -z "$NTFY_TOPIC" ]; then
    log "WARN: NTFY_TOPIC not set in $ENV_FILE - alert not sent: $1"
    return 1
  fi
  local args=(-fsS --max-time 15 -H "Title: $1" -H "Priority: $2" -H "Tags: $3" -d "$4")
  [ -n "$NTFY_TOKEN" ] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  if curl "${args[@]}" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null; then
    log "ntfy sent: $1"
  else
    log "ERROR: ntfy delivery failed: $1"
    return 1
  fi
}

# ---- run health check ----
output="$("$HEALTH_CMD" 2>&1)"
rc=$?
server_state="$(printf '%s\n' "$output" | sed -n 's/.*server_state: \([a-z_]*\).*/\1/p' | head -n1)"
server_state="${server_state:-unknown}"
failed_checks="$(printf '%s\n' "$output" | grep '\[FAIL\]' | sed 's/^ *\[FAIL\] *//' | paste -sd ';' -)"

healthy=1
reason=""
if [ "$rc" -ne 0 ]; then
  healthy=0
  reason="health check failed: ${failed_checks:-exit $rc}"
elif ! printf ' %s ' "$HEALTHY_STATES" | grep -q " $server_state "; then
  healthy=0
  reason="server_state is '$server_state' (expected: $HEALTHY_STATES)"
fi

prev="$(cat "$STATE_FILE" 2>/dev/null || echo ok)"
now="$(date +%s)"

if [ "$healthy" -eq 1 ]; then
  if [ "$prev" = "fail" ]; then
    since="$(cat "$SINCE_FILE" 2>/dev/null || echo "$now")"
    mins=$(( (now - since) / 60 ))
    log "RECOVERED: server_state=$server_state (down ~${mins}m)"
    notify "[$NODE_LABEL] Post Fiat node RECOVERED" "default" "white_check_mark" \
      "Healthy again. server_state=$server_state. Was unhealthy for ~${mins} min."
    rm -f "$SINCE_FILE" "$LAST_ALERT_FILE"
  else
    log "OK: server_state=$server_state"
  fi
  echo ok > "$STATE_FILE"
  exit 0
fi

# ---- unhealthy ----
if [ "$prev" != "fail" ]; then
  log "ALERT: $reason"
  echo "$now" > "$SINCE_FILE"
  notify "[$NODE_LABEL] Post Fiat node UNHEALTHY" "high" "rotating_light" \
    "$reason. Check: sudo postfiat-health" && echo "$now" > "$LAST_ALERT_FILE"
  echo fail > "$STATE_FILE"
  exit 1
fi

# already failing: de-duplicate, optionally remind
last="$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)"
if [ "$REMIND_MINUTES" -gt 0 ] && [ $(( now - last )) -ge $(( REMIND_MINUTES * 60 )) ]; then
  log "REMINDER: still unhealthy - $reason"
  notify "[$NODE_LABEL] Post Fiat node STILL UNHEALTHY" "high" "warning" \
    "$reason. Check: sudo postfiat-health" && echo "$now" > "$LAST_ALERT_FILE"
else
  log "STILL UNHEALTHY (alert suppressed, already notified): $reason"
fi
exit 1
