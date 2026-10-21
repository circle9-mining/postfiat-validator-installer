#!/usr/bin/env bash
# relay-setup: run on the disposable sentry/relay VPS (Ubuntu 22.04). Installs nginx (stream module)
# and forwards TCP 2559 to the private validator; opens 2559 in UFW (keeps SSH open).
# Usage: sudo VALIDATOR_ADDR=<validator-ip> ./relay-setup.sh
# Env:   VALIDATOR_PORT (2559)  LISTEN_PORT (2559)
#        UPSTREAM_ADDR/UPSTREAM_PORT override the forward target (e.g. 127.0.0.1:2560 for a local sentry
#        postfiatd, see sentry-node.sh); default is the validator, as on the task card.
set -euo pipefail
VALIDATOR_ADDR="${VALIDATOR_ADDR:-}"
VALIDATOR_PORT="${VALIDATOR_PORT:-2559}"
LISTEN_PORT="${LISTEN_PORT:-2559}"
UPSTREAM_ADDR="${UPSTREAM_ADDR:-$VALIDATOR_ADDR}"; UPSTREAM_PORT="${UPSTREAM_PORT:-$VALIDATOR_PORT}"
: "${UPSTREAM_ADDR:?set VALIDATOR_ADDR (or UPSTREAM_ADDR)}"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[[ "$UPSTREAM_ADDR" =~ ^[0-9A-Za-z.:-]+$ ]] || { echo "bad VALIDATOR_ADDR"; exit 1; }

grep ^PRETTY_NAME= /etc/os-release
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx libnginx-mod-stream ufw >/dev/null

mkdir -p /etc/nginx/streams.d
cat > /etc/nginx/streams.d/postfiat-sentry.conf <<CONF
# managed by postfiat-validator-installer/sentry/relay-setup.sh
server {
    listen ${LISTEN_PORT};
    proxy_pass ${UPSTREAM_ADDR}:${UPSTREAM_PORT};
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
}
CONF

if ! grep -q 'streams.d' /etc/nginx/nginx.conf; then
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.pre-sentry
  printf '\nstream {\n    include /etc/nginx/streams.d/*.conf;\n}\n' >> /etc/nginx/nginx.conf
fi
nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

ufw allow 22/tcp comment SSH >/dev/null
ufw allow "${LISTEN_PORT}/tcp" comment 'Post Fiat sentry relay' >/dev/null
ufw --force enable >/dev/null
ufw status verbose
ss -ltnp | grep ":${LISTEN_PORT} " || { echo "nginx not listening on ${LISTEN_PORT}"; exit 1; }
echo "relay OK: :${LISTEN_PORT} -> ${UPSTREAM_ADDR}:${UPSTREAM_PORT}"
