#!/usr/bin/env bash
# shellcheck disable=SC2086
# validator-setup: run on the validator (Ubuntu 22.04, Docker deployment in /opt/postfiatd).
# Points postfiatd at the sentry only ([ips_fixed]), sets [peer_private]=1, and restricts inbound 2559
# to the sentry IP (UFW + DOCKER-USER, since Docker-published ports bypass UFW). Restarts postfiatd.
# Usage: sudo SENTRY_IP=<sentry-ip> ./validator-setup.sh apply|revert
# Env:   IFACE (default route NIC)  COMPOSE_DIR (/opt/postfiatd)  CONTAINER (postfiatd)  SENTRY_PORT (2559)  WAIT_SECS (300)
# Revert restores the saved config backup and the original UFW/DOCKER-USER rules.
set -euo pipefail
COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"; CONTAINER="${CONTAINER:-postfiatd}"
SENTRY_PORT="${SENTRY_PORT:-2559}"; WAIT_SECS="${WAIT_SECS:-300}"
CFG=/etc/postfiatd/postfiatd.cfg; BK=/etc/postfiatd/postfiatd.cfg.pre-sentry
MODE="${1:-}"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

du_rules() { # DOCKER-USER rules we manage are tagged with a comment
  iptables -S DOCKER-USER | grep -- 'pft-sentry' | sed 's/^-A /-D /' || true; }
wait_full() {
  local end=$((SECONDS+WAIT_SECS)) s
  while [ $SECONDS -lt $end ]; do
    s=$(docker exec "$CONTAINER" curl -s --max-time 5 -X POST -H 'Content-Type: application/json' http://127.0.0.1:5005 -d '{"method":"server_info","params":[{}]}' | jq -r '.result.info.server_state // empty' 2>/dev/null || true)
    [ "$s" = full ] || [ "$s" = proposing ] && { log "server_state=$s"; return 0; }
    sleep 5
  done; log "server_state not full after ${WAIT_SECS}s"; return 1; }

case "$MODE" in
apply)
  : "${SENTRY_IP:?set SENTRY_IP}"
  [[ "$SENTRY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "SENTRY_IP must be IPv4"; exit 1; }
  grep ^PRETTY_NAME= /etc/os-release
  cd "$COMPOSE_DIR"
  # match inbound on the external NIC only: outbound dials from the container to the sentry also hit DOCKER-USER
  IFACE="${IFACE:-$(ip -4 route show default | awk '{print $5; exit}')}"
  docker exec "$CONTAINER" sh -c "[ -f $BK ] || cp $CFG $BK"
  # rewrite: drop [ips]/[ips_fixed]/[peer_private] sections, then append ours
  docker exec "$CONTAINER" sh -c "awk '
    /^\[/ {skip = (\$0==\"[ips]\" || \$0==\"[ips_fixed]\" || \$0==\"[peer_private]\")}
    !skip {print}' $BK > $CFG.new && printf '\n[ips_fixed]\n%s %s\n\n[peer_private]\n1\n' '$SENTRY_IP' '$SENTRY_PORT' >> $CFG.new && mv $CFG.new $CFG"
  log "config sections now:"; docker exec "$CONTAINER" sh -c "sed -n '/^\[ips_fixed\]/,\$p' $CFG" | sed -E 's/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/<redacted-ip>/g'
  # firewall: sentry only
  ufw status numbered | grep -q '2559/tcp.*LIMIT IN' && { ufw --force delete limit 2559/tcp >/dev/null || true; }
  ufw allow from "$SENTRY_IP" to any port 2559 proto tcp comment 'pft-sentry' >/dev/null
  du_rules | while read -r r; do iptables $r; done  # rules are word-split on purpose
  iptables -I DOCKER-USER 1 -i "$IFACE" -p tcp --dport 2559 -m comment --comment pft-sentry-drop -j DROP
  iptables -I DOCKER-USER 1 -i "$IFACE" -p tcp --dport 2559 -s "$SENTRY_IP" -m comment --comment pft-sentry-allow -j ACCEPT
  iptables -I DOCKER-USER 1 -p tcp --dport 2559 -m state --state RELATED,ESTABLISHED -m comment --comment pft-sentry-est -j ACCEPT
  docker restart "$CONTAINER" >/dev/null; log "restarted $CONTAINER"
  wait_full ;;
revert)
  docker exec "$CONTAINER" sh -c "[ -f $BK ] && cp $BK $CFG" || { echo "no backup"; exit 1; }
  ufw status numbered | grep -q pft-sentry && ufw --force delete allow from "${SENTRY_IP:?set SENTRY_IP}" to any port 2559 proto tcp >/dev/null
  ufw limit 2559/tcp comment 'Post Fiat peer protocol (rate-limited)' >/dev/null
  du_rules | while read -r r; do iptables $r; done  # rules are word-split on purpose
  docker restart "$CONTAINER" >/dev/null; log "reverted and restarted"
  wait_full ;;
*) echo "usage: sudo SENTRY_IP=x.x.x.x $0 apply|revert"; exit 2 ;;
esac
