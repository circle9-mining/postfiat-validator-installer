#!/usr/bin/env bash
# Install / uninstall pft-vlwatch (+ optional 10-minute change-only ntfy timer).
#   sudo ./install.sh                         # script only: /usr/local/bin/pft-vlwatch
#   sudo ./install.sh --timer --ntfy-env FILE [--container NAME] [--label NAME]
#                                             # + units; FILE (NTFY_SERVER/NTFY_TOPIC[/NTFY_TOKEN]) installed root 0600
#   sudo ./install.sh --uninstall             # removes script, units and state; keeps /etc/pft-vlwatch
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR=/etc/pft-vlwatch
timer=false; ntfy=""; container=postfiatd; label=""
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --timer) timer=true ;;
    --ntfy-env) ntfy="$2"; shift ;;
    --container) container="$2"; shift ;;
    --label) label="$2"; shift ;;
    --uninstall)
      systemctl disable --now pft-vlwatch.timer 2>/dev/null || true
      rm -f /etc/systemd/system/pft-vlwatch.service /etc/systemd/system/pft-vlwatch.timer /usr/local/bin/pft-vlwatch
      systemctl daemon-reload; rm -rf /var/lib/pft-vlwatch
      echo "removed (kept $CONF_DIR)"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done
command -v jq >/dev/null || { echo "jq required (apt-get install jq)" >&2; exit 3; }
install -m 755 "$HERE/pft-vlwatch.sh" /usr/local/bin/pft-vlwatch
echo "installed /usr/local/bin/pft-vlwatch"
[ "$timer" = true ] || exit 0
[ -f "$ntfy" ] || { echo "--timer needs --ntfy-env FILE" >&2; exit 3; }
grep -q '^NTFY_TOPIC=.' "$ntfy" || { echo "ntfy env needs NTFY_TOPIC=" >&2; exit 3; }
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
install -m 600 -o root -g root "$ntfy" "$CONF_DIR/ntfy.env"
if [ ! -f "$CONF_DIR/vlwatch.env" ]; then
  sed -e "s/^VLWATCH_CONTAINER=.*/VLWATCH_CONTAINER=$container/" -e "s/^NODE_LABEL=.*/NODE_LABEL=${label:-$(hostname -s)}/" \
    "$HERE/vlwatch.env.example" > "$CONF_DIR/vlwatch.env"
  chmod 644 "$CONF_DIR/vlwatch.env"
fi
install -m 644 "$HERE/pft-vlwatch.service" "$HERE/pft-vlwatch.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pft-vlwatch.timer
echo "enabled pft-vlwatch.timer (first run in 5 min after boot, then every 10 min); first PASS run is silent"
echo "remember: sudo pft-integrity accept --reason 'pft-vlwatch installed'"
