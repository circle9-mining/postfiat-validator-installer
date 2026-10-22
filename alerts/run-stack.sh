#!/usr/bin/env bash
# Start/stop a loopback-only Prometheus + Alertmanager (+ webhook->ntfy bridge) for a Post Fiat node.
#
# Usage: run-stack.sh up|down|status|check
#   up      validate configs with promtool/amtool, start 3 containers, verify loopback-only listeners
#   down    stop and remove the containers (Prometheus data volume is kept)
#   status  container state, target health, active alerts
#   check   promtool check rules + promtool test rules + amtool check-config only
#
# Env:
#   DOCKER          docker command (default "docker"; e.g. DOCKER="sudo docker")
#   NTFY_ENV_FILE   optional file containing NTFY_URL=https://ntfy.sh/<topic> (mode 600 recommended);
#                   without it the bridge only logs notifications
#   EXPORTER        exporter address to preflight (default 127.0.0.1:9877)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read -r -a DOCKER <<< "${DOCKER:-docker}"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.5.0}"
AM_IMAGE="${AM_IMAGE:-prom/alertmanager:v0.28.1}"
PY_IMAGE="${PY_IMAGE:-python:3.12-alpine}"
EXPORTER="${EXPORTER:-127.0.0.1:9877}"
PORTS="9090 9093 9094 9095"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

check() {
  log "promtool check rules"
  "${DOCKER[@]}" run --rm -v "$HERE:/w:ro" -w /w --entrypoint promtool "$PROM_IMAGE" check rules postfiat.rules.yml
  log "promtool test rules"
  "${DOCKER[@]}" run --rm -v "$HERE:/w:ro" -w /w --entrypoint promtool "$PROM_IMAGE" test rules tests.yml
  log "promtool check config (prometheus.yml)"
  "${DOCKER[@]}" run --rm -v "$HERE:/etc/pft-alerts:ro" --entrypoint promtool "$PROM_IMAGE" \
    check config /etc/pft-alerts/prometheus.yml
  log "amtool check-config"
  "${DOCKER[@]}" run --rm -v "$HERE:/w:ro" --entrypoint amtool "$AM_IMAGE" check-config /w/alertmanager.yml
}

preflight() {
  command -v "${DOCKER[-1]}" >/dev/null || die "docker not found"
  "${DOCKER[@]}" info >/dev/null 2>&1 || die "cannot talk to docker (try DOCKER=\"sudo docker\")"
  command -v ss >/dev/null || die "ss (iproute2) not found"
  curl -fsS --max-time 5 "http://$EXPORTER/metrics" | grep -q '^pft_up ' \
    || die "exporter not answering on $EXPORTER (install ../exporter first)"
  if [ -n "${NTFY_ENV_FILE:-}" ]; then
    [ -r "$NTFY_ENV_FILE" ] || die "NTFY_ENV_FILE $NTFY_ENV_FILE not readable"
    grep -q '^NTFY_URL=https://' "$NTFY_ENV_FILE" || die "NTFY_ENV_FILE must contain NTFY_URL=https://..."
  fi
}

# Fail if anything listens on our ports on a non-loopback address.
verify_loopback() {
  local p bad=0 lines
  for p in $PORTS; do
    lines="$(ss -Htln "sport = :$p" || true)"
    [ -z "$lines" ] && continue
    printf '%s\n' "$lines" | awk -v p="$p" '{print "  listen :" p " -> " $4}'
    if printf '%s\n' "$lines" | awk '{print $4}' | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
      log "NON-LOOPBACK listener on port $p"; bad=1
    fi
  done
  [ "$bad" -eq 0 ] || die "a stack port is exposed beyond loopback; run '$0 down'"
  log "all stack listeners are loopback-only"
}

up() {
  preflight
  check
  local ntfy_args=()
  local ntfy_state=off
  if [ -n "${NTFY_ENV_FILE:-}" ]; then ntfy_args=(--env-file "$NTFY_ENV_FILE"); ntfy_state=on; fi
  down quiet
  log "starting pft-alert-bridge (ntfy: $ntfy_state)"
  "${DOCKER[@]}" run -d --name pft-alert-bridge --restart unless-stopped --network host --read-only \
    --security-opt no-new-privileges --cap-drop ALL --user 65534:65534 "${ntfy_args[@]}" \
    -v "$HERE/ntfy_bridge.py:/app/ntfy_bridge.py:ro" "$PY_IMAGE" python3 -u /app/ntfy_bridge.py >/dev/null
  log "starting pft-alertmanager"
  "${DOCKER[@]}" run -d --name pft-alertmanager --restart unless-stopped --network host \
    --security-opt no-new-privileges --cap-drop ALL -v "$HERE/alertmanager.yml:/etc/pft-alerts/alertmanager.yml:ro" \
    "$AM_IMAGE" --config.file=/etc/pft-alerts/alertmanager.yml --web.listen-address=127.0.0.1:9093 \
    --cluster.listen-address= --storage.path=/alertmanager >/dev/null
  log "starting pft-prometheus"
  "${DOCKER[@]}" run -d --name pft-prometheus --restart unless-stopped --network host \
    --security-opt no-new-privileges --cap-drop ALL -v "$HERE:/etc/pft-alerts:ro" -v pft-prometheus-data:/prometheus \
    "$PROM_IMAGE" --config.file=/etc/pft-alerts/prometheus.yml --web.listen-address=127.0.0.1:9090 \
    --storage.tsdb.path=/prometheus --storage.tsdb.retention.time=15d >/dev/null
  local i ready=0
  for i in $(seq 1 30); do
    if curl -fsS --max-time 2 http://127.0.0.1:9090/-/ready >/dev/null 2>&1 \
      && curl -fsS --max-time 2 http://127.0.0.1:9093/-/ready >/dev/null 2>&1; then
      ready=1; break
    fi
    sleep 2
  done
  [ "$ready" -eq 1 ] || die "Prometheus/Alertmanager not ready after $((i * 2))s"
  verify_loopback
  status
}

down() {
  local c
  for c in pft-prometheus pft-alertmanager pft-alert-bridge; do
    "${DOCKER[@]}" rm -f "$c" >/dev/null 2>&1 && [ "${1:-}" != quiet ] && log "removed $c"
  done
  return 0
}

status() {
  "${DOCKER[@]}" ps --filter name=pft-prometheus --filter name=pft-alertmanager --filter name=pft-alert-bridge \
    --format '  {{.Names}}  {{.Status}}  {{.Image}}'
  log "scrape targets:"
  curl -fsS http://127.0.0.1:9090/api/v1/targets \
    | jq -r '.data.activeTargets[] | "  \(.labels.job) \(.scrapeUrl) health=\(.health)"'
  log "Prometheus alerts (pending/firing):"
  curl -fsS http://127.0.0.1:9090/api/v1/alerts \
    | jq -r '.data.alerts[] | "  \(.labels.alertname) state=\(.state) since=\(.activeAt)"'
  log "Alertmanager alerts:"
  curl -fsS http://127.0.0.1:9093/api/v2/alerts \
    | jq -r '.[] | "  \(.labels.alertname) state=\(.status.state) startsAt=\(.startsAt)"'
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  status) status ;;
  check) check ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
