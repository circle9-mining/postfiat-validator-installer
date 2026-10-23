#!/usr/bin/env bash
# Install / uninstall the watchdog add-on.
#
# Validator host:  sudo ./install.sh heartbeat --relay HOST [--port 22] [--label validator]
#   installs pft-heartbeat + 60s timer; creates /etc/pft-watchdog (0700) with hmac.key (64 hex, 0600) and a
#   dedicated SSH key id_ed25519 if missing; pins the watchdog host key in /etc/pft-watchdog/known_hosts
#   (compare the printed fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on that host).
#   Then copy hmac.key and id_ed25519.pub to the watchdog host over an existing secure channel.
# Watchdog host:   sudo ./install.sh watchdog --pubkey FILE --hmac-key FILE --ntfy-env FILE
#   creates the system user pftwd (locked password) whose authorized_keys entry is
#   `restrict,command="/usr/local/bin/pft-watchdog receive"` - it can only drop a message into the spool;
#   installs hmac.key and ntfy.env (NTFY_SERVER/NTFY_TOPIC[/NTFY_TOKEN]) as 0600 root, pft-watchdog + 60s timer.
# Remove:          sudo ./install.sh uninstall heartbeat|watchdog [--purge]   (--purge also deletes keys/state)
set -euo pipefail
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR=/etc/pft-watchdog
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }
role="${1:-}"; [ $# -gt 0 ] && shift
relay="" port=22 label=validator pubkey="" hmac="" ntfy="" purge=0
while [ $# -gt 0 ]; do
  case "$1" in
    --relay) relay="$2"; shift ;;
    --port) port="$2"; shift ;;
    --label) label="$2"; shift ;;
    --pubkey) pubkey="$2"; shift ;;
    --hmac-key) hmac="$2"; shift ;;
    --ntfy-env) ntfy="$2"; shift ;;
    --purge) purge=1 ;;
    heartbeat|watchdog) target="$1" ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"

case "$role" in
heartbeat)
  [ -n "$relay" ] || { echo "--relay HOST required" >&2; exit 3; }
  for b in curl jq ssh ssh-keygen ssh-keyscan sha256sum; do command -v "$b" >/dev/null || { echo "missing $b" >&2; exit 3; }; done
  [ -f "$CONF_DIR/hmac.key" ] || { od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$CONF_DIR/hmac.key"; echo "created $CONF_DIR/hmac.key"; }
  [ -f "$CONF_DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C pft-heartbeat -f "$CONF_DIR/id_ed25519"
  if [ ! -s "$CONF_DIR/known_hosts" ]; then
    ssh-keyscan -T 10 -p "$port" -t ed25519 "$relay" 2>/dev/null > "$CONF_DIR/known_hosts"
    [ -s "$CONF_DIR/known_hosts" ] || { echo "ssh-keyscan of the watchdog host failed" >&2; exit 2; }
    echo "pinned watchdog host key: $(ssh-keygen -lf "$CONF_DIR/known_hosts" | awk '{print $2}')"
  fi
  printf 'RELAY_TARGET=pftwd@%s\nRELAY_PORT=%s\nNODE_LABEL=%s\nRPC_URL=http://127.0.0.1:5005\n' "$relay" "$port" "$label" > "$CONF_DIR/heartbeat.conf"
  chmod 600 "$CONF_DIR"/*
  install -m 755 "$HERE/pft-heartbeat.sh" /usr/local/bin/pft-heartbeat
  install -m 644 "$HERE/pft-heartbeat.service" "$HERE/pft-heartbeat.timer" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now pft-heartbeat.timer
  echo "installed. Copy $CONF_DIR/hmac.key and $CONF_DIR/id_ed25519.pub to the watchdog host."
  ;;
watchdog)
  for f in "$pubkey" "$hmac" "$ntfy"; do [ -f "$f" ] || { echo "--pubkey, --hmac-key and --ntfy-env files required" >&2; exit 3; }; done
  grep -qxE '[0-9a-fA-F]{64}' "$hmac" || { echo "hmac key must be 64 hex characters" >&2; exit 3; }
  grep -q '^NTFY_TOPIC=.' "$ntfy" || { echo "ntfy env needs NTFY_TOPIC=" >&2; exit 3; }
  for b in curl jq flock sha256sum; do command -v "$b" >/dev/null || { echo "missing $b" >&2; exit 3; }; done
  install -m 600 -o root -g root "$hmac" "$CONF_DIR/hmac.key"
  install -m 600 -o root -g root "$ntfy" "$CONF_DIR/ntfy.env"
  install -m 755 "$HERE/pft-watchdog.sh" /usr/local/bin/pft-watchdog
  id pftwd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pft-watchdog-spool --shell /bin/sh pftwd
  passwd -l pftwd >/dev/null
  install -d -m 700 -o pftwd -g pftwd /var/lib/pft-watchdog-spool /var/lib/pft-watchdog-spool/.ssh
  printf 'restrict,command="/usr/local/bin/pft-watchdog receive" %s\n' "$(head -1 "$pubkey")" > /var/lib/pft-watchdog-spool/.ssh/authorized_keys
  chown pftwd:pftwd /var/lib/pft-watchdog-spool/.ssh/authorized_keys; chmod 600 /var/lib/pft-watchdog-spool/.ssh/authorized_keys
  install -m 644 "$HERE/pft-watchdog.service" "$HERE/pft-watchdog.timer" /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now pft-watchdog.timer
  echo "installed. pft-watchdog status: sudo pft-watchdog status"
  ;;
uninstall)
  case "${target:-}" in
    heartbeat)
      systemctl disable --now pft-heartbeat.timer 2>/dev/null || true
      rm -f /etc/systemd/system/pft-heartbeat.service /etc/systemd/system/pft-heartbeat.timer /usr/local/bin/pft-heartbeat ;;
    watchdog)
      systemctl disable --now pft-watchdog.timer 2>/dev/null || true
      rm -f /etc/systemd/system/pft-watchdog.service /etc/systemd/system/pft-watchdog.timer /usr/local/bin/pft-watchdog
      id pftwd >/dev/null 2>&1 && userdel pftwd
      rm -rf /var/lib/pft-watchdog-spool
      [ "$purge" -eq 1 ] && rm -rf /var/lib/pft-watchdog ;;
    *) echo "uninstall heartbeat|watchdog" >&2; exit 3 ;;
  esac
  [ "$purge" -eq 1 ] && rm -rf "$CONF_DIR"
  systemctl daemon-reload; echo "uninstalled ${target}" ;;
*) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 3 ;;
esac
