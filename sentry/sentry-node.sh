#!/usr/bin/env bash
# sentry-node: run on the relay VPS (Ubuntu 22.04). Runs a public postfiatd full node (the actual "sentry")
# in Docker, bound to 127.0.0.1:2560 only; nginx (relay-setup.sh, UPSTREAM_ADDR=127.0.0.1 UPSTREAM_PORT=2560)
# exposes it on :2559. Uses the rolling agtipft/postfiatd:<network>-light-latest tag per Post Fiat's guide.
# Usage: sudo ./sentry-node.sh        Env: NETWORK (testnet)  SENTRY_DIR (/opt/postfiatd-sentry)
set -euo pipefail
NETWORK="${NETWORK:-testnet}"; SENTRY_DIR="${SENTRY_DIR:-/opt/postfiatd-sentry}"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
grep ^PRETTY_NAME= /etc/os-release
command -v jq >/dev/null || { apt-get update -qq; apt-get install -y -qq jq >/dev/null; }
command -v docker >/dev/null || { apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null; }
systemctl enable --now docker >/dev/null 2>&1
mkdir -p "$SENTRY_DIR"
docker rm -f postfiatd-sentry >/dev/null 2>&1 || true
docker run -d --name postfiatd-sentry --restart unless-stopped --user 0:0 \
  -p 127.0.0.1:2560:2559 \
  -v pft-sentry-config:/etc/postfiatd -v pft-sentry-data:/var/lib/postfiatd/db \
  "agtipft/postfiatd:${NETWORK}-light-latest" >/dev/null
for _ in $(seq 60); do
  s=$(docker exec postfiatd-sentry curl -s --max-time 5 -X POST -H 'Content-Type: application/json' http://127.0.0.1:5005 -d '{"method":"server_info","params":[{}]}' | jq -r '.result.info.server_state // empty' 2>/dev/null || true)
  echo "server_state=${s:-starting}"; [ "$s" = full ] && break; sleep 10
done
