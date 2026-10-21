#!/usr/bin/env bash
# postfiat-upgrade: pull the official rolling agtipft/postfiatd light image, restart the
# validator, and log old vs new image digest and build_version. Then compare build_version
# with the foundation RPC and run the post-restart health check.
#
# Note: uses the rolling "<network>-light-latest" tag (per Post Fiat's official validator
# guide) rather than a pinned digest; the digests before/after are logged instead.
#
# Usage: sudo ./postfiat-upgrade.sh
# Env:   COMPOSE_DIR (/opt/postfiatd)  NETWORK (testnet)  FOUNDATION_RPC (https://rpc.testnet.postfiat.org)
#        LOCAL_RPC (http://127.0.0.1:5005)  HEALTH_CMD (/usr/local/bin/postfiat-health)  WAIT_SECS (300)

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
NETWORK="${NETWORK:-testnet}"
IMAGE="agtipft/postfiatd:${NETWORK}-light-latest"
FOUNDATION_RPC="${FOUNDATION_RPC:-https://rpc.testnet.postfiat.org}"
LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:5005}"
HEALTH_CMD="${HEALTH_CMD:-/usr/local/bin/postfiat-health}"
WAIT_SECS="${WAIT_SECS:-300}"
CONTAINER=postfiatd

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
for c in docker curl jq; do command -v "$c" >/dev/null || die "$c required."; done
[ -f "$COMPOSE_DIR/docker-compose.yml" ] || die "no docker-compose.yml in $COMPOSE_DIR"

rpc_info() { # $1 = url ; prints compact JSON of server_info.info
  curl -s --max-time 10 "$1" -X POST -H 'Content-Type: application/json' \
    -d '{"method":"server_info","params":[{}]}' | jq -c '.result.info // empty'
}
local_image_id() { docker inspect --format '{{.Image}}' "$CONTAINER" 2>/dev/null || echo none; }
repo_digest() { docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo none; }

OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
log "OS: $OS_NAME"
log "Image: $IMAGE"

OLD_ID="$(local_image_id)"
OLD_DIGEST="$(repo_digest)"
OLD_BUILD="$(rpc_info "$LOCAL_RPC" | jq -r '.build_version // "unknown"')"
log "BEFORE container image id : $OLD_ID"
log "BEFORE repo digest        : $OLD_DIGEST"
log "BEFORE build_version      : $OLD_BUILD"

log "docker compose pull"
(cd "$COMPOSE_DIR" && NETWORK="$NETWORK" docker compose pull)

log "docker compose up -d (recreates the container only if the image changed)"
(cd "$COMPOSE_DIR" && NETWORK="$NETWORK" docker compose up -d)
log "docker compose restart"
(cd "$COMPOSE_DIR" && NETWORK="$NETWORK" docker compose restart)

log "waiting up to ${WAIT_SECS}s for server_state full/proposing"
state=unknown
for ((t = 0; t < WAIT_SECS; t += 5)); do
  state="$(rpc_info "$LOCAL_RPC" | jq -r '.server_state // "unknown"' 2>/dev/null || echo unknown)"
  case "$state" in full | proposing) break ;; esac
  sleep 5
done
log "server_state: $state"
case "$state" in full | proposing) ;; *) die "node did not reach full/proposing" ;; esac

NEW_ID="$(local_image_id)"
NEW_DIGEST="$(repo_digest)"
NEW_BUILD="$(rpc_info "$LOCAL_RPC" | jq -r '.build_version // "unknown"')"
log "AFTER  container image id : $NEW_ID"
log "AFTER  repo digest        : $NEW_DIGEST"
log "AFTER  build_version      : $NEW_BUILD"
if [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then log "RESULT: image digest unchanged (already latest)"; else log "RESULT: image digest CHANGED"; fi
if [ "$OLD_BUILD" = "$NEW_BUILD" ]; then log "RESULT: build_version unchanged ($NEW_BUILD)"; else log "RESULT: build_version $OLD_BUILD -> $NEW_BUILD"; fi

REF_BUILD="$(rpc_info "$FOUNDATION_RPC" | jq -r '.build_version // "unknown"')"
log "foundation RPC build_version: $REF_BUILD ($FOUNDATION_RPC)"
if [ "$REF_BUILD" = "$NEW_BUILD" ]; then
  log "PASS build_version matches foundation RPC"
else
  die "build_version mismatch: local $NEW_BUILD vs foundation $REF_BUILD"
fi

log "post-restart health check: $HEALTH_CMD"
if "$HEALTH_CMD"; then log "PASS post-restart health check"; else die "health check failed"; fi
log "upgrade complete"
