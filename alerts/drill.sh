#!/usr/bin/env bash
# Live alert drill: stop postfiatd, watch alerts go pending -> firing (Prometheus + Alertmanager API),
# start it again, wait for server_state full, then wait until every drill alert has resolved.
# Requires the stack from run-stack.sh to be up. Always restarts the node on exit (trap).
#
# Usage: DOCKER="sudo docker" ./drill.sh [container]   (default container: postfiatd)
set -euo pipefail

CONTAINER="${1:-postfiatd}"
read -r -a DOCKER <<< "${DOCKER:-docker}"
PROM=http://127.0.0.1:9090
AM=http://127.0.0.1:9093
RESOLVE_WAIT_S="${RESOLVE_WAIT_S:-1500}"   # PFTContainerRestarted looks back 15m, so allow 25m

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

rpc_state() {
  "${DOCKER[@]}" exec "$CONTAINER" curl -s -m 5 -X POST -H 'Content-Type: application/json' \
    -d '{"method":"server_info","params":[{}]}' http://127.0.0.1:5005/ 2>/dev/null \
    | jq -r '.result.info.server_state // "unreachable"' 2>/dev/null || echo unreachable
}
prom_alerts() {
  curl -fsS "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | "\(.labels.alertname)=\(.state)"] | sort | join(" ") | if . == "" then "-" else . end'
}
am_alerts() {
  curl -fsS "$AM/api/v2/alerts" | jq -r '[.[] | "\(.labels.alertname)=\(.status.state)"] | sort | join(" ") | if . == "" then "-" else . end'
}
snapshot() { log "node=$(rpc_state) | prometheus: $(prom_alerts) | alertmanager: $(am_alerts)"; }

restore() {
  if [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    log "trap: starting $CONTAINER"
    "${DOCKER[@]}" start "$CONTAINER" >/dev/null || true
  fi
}
trap restore EXIT

START="$(date -u +%FT%TZ)"
log "== preflight"
curl -fsS "$PROM/-/ready" >/dev/null || die "Prometheus not ready (run-stack.sh up first)"
curl -fsS "$AM/-/ready" >/dev/null || die "Alertmanager not ready"
[ "$(rpc_state)" = full ] || die "node must be full before the drill"
snapshot

log "== stop: ${DOCKER[*]} stop $CONTAINER"
"${DOCKER[@]}" stop "$CONTAINER" >/dev/null
seen_pending=0 seen_firing=0 seen_am=0
for _ in $(seq 1 36); do   # up to 6 min
  sleep 10
  p="$(prom_alerts)" a="$(am_alerts)"
  log "node=$(rpc_state) | prometheus: $p | alertmanager: $a"
  [[ "$p" == *PFTNodeRPCDown=pending* ]] && seen_pending=1
  [[ "$p" == *PFTNodeRPCDown=firing* ]] && seen_firing=1
  [[ "$a" == *PFTNodeRPCDown=active* ]] && seen_am=1
  [ "$seen_firing" -eq 1 ] && [ "$seen_am" -eq 1 ] && break
done
log "RESULT pending_seen=$seen_pending firing_seen=$seen_firing alertmanager_active_seen=$seen_am"
log "Alertmanager API detail:"
curl -fsS "$AM/api/v2/alerts" | jq -c '.[] | {alertname: .labels.alertname, severity: .labels.severity, state: .status.state, startsAt, endsAt}'

log "== restore: ${DOCKER[*]} start $CONTAINER"
"${DOCKER[@]}" start "$CONTAINER" >/dev/null
full=0
for _ in $(seq 1 90); do   # up to 15 min
  sleep 10
  s="$(rpc_state)"
  log "server_state=$s"
  if [ "$s" = full ]; then full=1; break; fi
done
[ "$full" -eq 1 ] || die "node did not reach full within 15 min"
log "server_state returned to full"

log "== waiting for all alerts to resolve (max ${RESOLVE_WAIT_S}s)"
resolved=0 waited=0 last=""
while [ "$waited" -lt "$RESOLVE_WAIT_S" ]; do
  p="$(prom_alerts)" a="$(am_alerts)"
  if [ "prometheus: $p | alertmanager: $a" != "$last" ]; then
    log "prometheus: $p | alertmanager: $a"; last="prometheus: $p | alertmanager: $a"
  fi
  if [ "$p" = - ] && [ "$a" = - ]; then resolved=1; break; fi
  sleep 15; waited=$((waited + 15))
done
snapshot
log "== bridge (Alertmanager webhook) notifications since $START"
"${DOCKER[@]}" logs --since "$START" pft-alert-bridge 2>&1
log "RESULT resolved=$resolved node=$(rpc_state)"
[ "$resolved" -eq 1 ] && [ "$seen_firing" -eq 1 ] && [ "$seen_am" -eq 1 ] || exit 1
