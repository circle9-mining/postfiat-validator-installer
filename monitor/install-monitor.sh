#!/usr/bin/env bash
# Install / uninstall the Post Fiat ntfy health monitor (systemd service + 5-minute timer).
#
# Install:
#   curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/monitor/install-monitor.sh | sudo bash
#   (optional: sudo NTFY_TOPIC=my-long-random-topic NODE_LABEL=pft-01 bash)
# Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/monitor/install-monitor.sh | sudo bash -s -- --uninstall
#
# Requires the main installer (postfiat-health at /usr/local/bin/postfiat-health).

set -euo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/monitor}"
ENV_FILE=/etc/postfiat-monitor.env
FILES=(postfiat-monitor.sh postfiat-monitor.service postfiat-monitor.timer postfiat-monitor.env.example)

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (pipe into 'sudo bash')."

if [ "${1:-}" = "--uninstall" ]; then
  log "Uninstalling postfiat-monitor"
  systemctl disable --now postfiat-monitor.timer 2>/dev/null || true
  systemctl stop postfiat-monitor.service 2>/dev/null || true
  rm -f /etc/systemd/system/postfiat-monitor.service /etc/systemd/system/postfiat-monitor.timer \
        /usr/local/bin/postfiat-monitor
  systemctl daemon-reload
  rm -rf /var/lib/postfiat-monitor
  log "Removed units, script and state. Kept $ENV_FILE and /var/log/postfiat-monitor.log (delete manually if wanted)."
  exit 0
fi

[ -x /usr/local/bin/postfiat-health ] || die "postfiat-health not found - run the main install.sh first."
command -v curl >/dev/null || die "curl required."

# Use local copies when run from a cloned repo, otherwise fetch from GitHub.
SRC_DIR="$(mktemp -d)"
trap 'rm -rf "$SRC_DIR"' EXIT
script_dir=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
for f in "${FILES[@]}"; do
  if [ -n "$script_dir" ] && [ -f "$script_dir/$f" ]; then
    cp "$script_dir/$f" "$SRC_DIR/$f"
  else
    curl -fsSL "$RAW_BASE/$f" -o "$SRC_DIR/$f" || die "download failed: $f"
  fi
done

log "Installing /usr/local/bin/postfiat-monitor and systemd units"
install -m 755 "$SRC_DIR/postfiat-monitor.sh" /usr/local/bin/postfiat-monitor
install -m 644 "$SRC_DIR/postfiat-monitor.service" /etc/systemd/system/postfiat-monitor.service
install -m 644 "$SRC_DIR/postfiat-monitor.timer" /etc/systemd/system/postfiat-monitor.timer

if [ -f "$ENV_FILE" ]; then
  log "Keeping existing $ENV_FILE"
else
  install -m 600 "$SRC_DIR/postfiat-monitor.env.example" "$ENV_FILE"
  topic="${NTFY_TOPIC:-pft-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
  sed -i "s|^NTFY_TOPIC=.*|NTFY_TOPIC=$topic|" "$ENV_FILE"
  [ -n "${NODE_LABEL:-}" ] && sed -i "s|^NODE_LABEL=.*|NODE_LABEL=$NODE_LABEL|" "$ENV_FILE"
  log "Created $ENV_FILE (mode 600)"
fi

# shellcheck source=/dev/null
. "$ENV_FILE"
systemctl daemon-reload
systemctl enable --now postfiat-monitor.timer

log "Sending test notification to ${NTFY_SERVER:-https://ntfy.sh}/<topic>"
curl -fsS --max-time 15 -H "Title: [${NODE_LABEL:-postfiat-node}] postfiat-monitor installed" \
  -H "Tags: bell" -d "Monitoring active: health check every 5 min." \
  "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC" >/dev/null \
  && log "Test notification sent" || log "WARN: test notification failed - check network/topic"

log "Running first check"
systemctl start postfiat-monitor.service || true
systemctl list-timers postfiat-monitor.timer --no-pager
tail -n 3 /var/log/postfiat-monitor.log || true

cat <<EOF

Done. Subscribe to your topic in the ntfy app to receive alerts:
  topic: see NTFY_TOPIC in $ENV_FILE  (sudo grep NTFY_TOPIC $ENV_FILE)
Keep the topic private - anyone who knows it can read your alerts.
Logs:   /var/log/postfiat-monitor.log   |   journalctl -u postfiat-monitor
Run now: sudo systemctl start postfiat-monitor.service
EOF
