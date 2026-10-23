#!/usr/bin/env bash
# Install / uninstall the pft-maint add-on on a validator or sentry host.
#
#   sudo ./install.sh install [--label validator|sentry] [--ntfy-env FILE]
#     installs /usr/local/bin/pft-maint, pft-maint-tick.{service,timer} (60s), /etc/pft-maint (0700) with
#     maint.conf (NODE_LABEL) and, if given, ntfy.env (0600 root; otherwise /etc/postfiat-monitor.env or
#     /etc/pft-integrity.env is used). Also installs the maintenance-aware versions of the alerters that are
#     already present on this host (pft-watchdog, postfiat-monitor, pft-integrity) from this repo checkout.
#   sudo ./install.sh uninstall [--purge]   (--purge also deletes /etc/pft-maint and /var/lib/pft-maint)
# After installing or upgrading, re-baseline the integrity monitor:
#   sudo pft-integrity accept --reason "pft-maint installed"
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }
cmd="${1:-}"; [ $# -gt 0 ] && shift
label="" ntfy="" purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="$2"; shift ;;
    --ntfy-env) ntfy="$2"; shift ;;
    --purge) purge=1 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done
case "$cmd" in
install)
  for b in jq flock curl sha256sum; do command -v "$b" >/dev/null || { echo "missing $b" >&2; exit 3; }; done
  install -d -m 700 /etc/pft-maint
  install -d -m 755 /var/lib/pft-maint /var/lib/pft-maint/locks
  if [ -n "$label" ] || [ ! -f /etc/pft-maint/maint.conf ]; then
    printf 'NODE_LABEL=%s\n' "${label:-$(hostname -s)}" > /etc/pft-maint/maint.conf; chmod 600 /etc/pft-maint/maint.conf
  fi
  if [ -n "$ntfy" ]; then
    grep -q '^NTFY_TOPIC=.' "$ntfy" || { echo "ntfy env needs NTFY_TOPIC=" >&2; exit 3; }
    install -m 600 -o root -g root "$ntfy" /etc/pft-maint/ntfy.env
  fi
  install -m 755 "$HERE/pft-maint.sh" /usr/local/bin/pft-maint
  # maintenance-aware alerters: only replace the ones this host already runs
  [ -e /usr/local/bin/pft-watchdog ] && install -m 755 "$HERE/../watchdog/pft-watchdog.sh" /usr/local/bin/pft-watchdog && echo "updated pft-watchdog"
  [ -e /usr/local/bin/postfiat-monitor ] && install -m 755 "$HERE/../monitor/postfiat-monitor.sh" /usr/local/bin/postfiat-monitor && echo "updated postfiat-monitor"
  [ -e /usr/local/bin/pft-integrity ] && install -m 755 "$HERE/../integrity/pft-integrity.sh" /usr/local/bin/pft-integrity && echo "updated pft-integrity"
  install -m 644 "$HERE/pft-maint-tick.service" "$HERE/pft-maint-tick.timer" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now pft-maint-tick.timer
  echo "installed. Try: sudo pft-maint status"
  ;;
uninstall)
  systemctl disable --now pft-maint-tick.timer 2>/dev/null || true
  rm -f /etc/systemd/system/pft-maint-tick.service /etc/systemd/system/pft-maint-tick.timer /usr/local/bin/pft-maint
  systemctl daemon-reload
  [ "$purge" -eq 1 ] && rm -rf /etc/pft-maint /var/lib/pft-maint
  echo "uninstalled (the alerters keep working: without pft-maint they never suppress)"
  ;;
*) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 3 ;;
esac
