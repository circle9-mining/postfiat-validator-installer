#!/usr/bin/env bash
# pft-heartbeat: push an HMAC-SHA256-signed heartbeat from a Post Fiat validator host to the watchdog host.
#
# Reads server_info from the local admin RPC, builds one compact JSON line
#   {"v":1,"node":..,"ts":<unix>,"server_state":..,"validated_ledger":..,"peers":..,"build_version":..}
# signs it with the shared key, and sends "<json>\n<hex hmac>\n" over SSH to a forced-command account on
# the watchdog host (`pft-watchdog receive`). The key never appears in argv or the environment: the HMAC is
# computed with bash builtins + sha256sum reading stdin. Runs every 60s from pft-heartbeat.timer.
#
# Usage: sudo pft-heartbeat [--print]
#   --print   write the signed message to stdout instead of sending it (dry run / debugging)
# Exit codes: 0 sent (or printed), 1 local RPC unreachable (a heartbeat with server_state "rpc_down" is
#             still sent so the watchdog sees the node is down, not the host), 2 send failed, 3 config error.
# Files (CONF_DIR=/etc/pft-watchdog): hmac.key (0600, 64 hex chars), id_ed25519 (0600 SSH key),
#   known_hosts (pinned watchdog host key), heartbeat.conf (RELAY_TARGET=user@host, RELAY_PORT=22,
#   NODE_LABEL=validator, RPC_URL=http://127.0.0.1:5005). Env HMAC_KEY_FILE overrides the key path
#   (used by the drill to send a deliberately mis-signed heartbeat).

set -uo pipefail
umask 077

CONF_DIR="${CONF_DIR:-/etc/pft-watchdog}"
HMAC_KEY_FILE="${HMAC_KEY_FILE:-$CONF_DIR/hmac.key}"
PRINT=0
case "${1:-}" in
  --print) PRINT=1 ;;
  "") ;;
  -h|--help) sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 3 ;;
esac

RELAY_TARGET="" RELAY_PORT=22 NODE_LABEL=validator RPC_URL=http://127.0.0.1:5005
if [ -f "$CONF_DIR/heartbeat.conf" ]; then
  while IFS='=' read -r k v; do
    case "$k" in RELAY_TARGET|RELAY_PORT|NODE_LABEL|RPC_URL) printf -v "$k" '%s' "${v//\"/}" ;; esac
  done < <(grep -E '^(RELAY_TARGET|RELAY_PORT|NODE_LABEL|RPC_URL)=' "$CONF_DIR/heartbeat.conf")
fi

key_ok() { # key file must exist, not be group/other-readable and hold 64 hex chars
  [ -f "$1" ] || { echo "missing key file $1" >&2; return 1; }
  case "$(stat -c %a -- "$1")" in ?00) ;; *) echo "$1 must be mode 0600 or stricter" >&2; return 1 ;; esac
  grep -qxE '[0-9a-fA-F]{64}' "$1" || { echo "$1 must contain exactly 64 hex characters" >&2; return 1; }
}

# HMAC-SHA256 (RFC 2104) with bash builtins: key hex in $1 (<=64 bytes), message on stdin, hex digest out.
hmac_sha256_hex() {
  local key="$1" ip="" op="" i b inner esc
  while [ "${#key}" -lt 128 ]; do key+=0; done
  for ((i = 0; i < 128; i += 2)); do
    b=$((16#${key:i:2}))
    printf -v esc '\\x%02x' $((b ^ 0x36)); ip+=$esc
    printf -v esc '\\x%02x' $((b ^ 0x5c)); op+=$esc
  done
  inner="$({ printf '%b' "$ip"; cat; } | sha256sum)"; inner="${inner%% *}"
  esc=""; for ((i = 0; i < 64; i += 2)); do esc+="\\x${inner:i:2}"; done
  { printf '%b' "$op"; printf '%b' "$esc"; } | sha256sum | cut -c1-64
}

key_ok "$HMAC_KEY_FILE" || exit 3
KEY="$(tr -d '[:space:]' < "$HMAC_KEY_FILE")"

rc=0
info="$(curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
  -d '{"method":"server_info","params":[{}]}' "$RPC_URL" 2>/dev/null | jq -c '.result.info // empty' 2>/dev/null)"
if [ -z "$info" ]; then
  rc=1; info='{"server_state":"rpc_down","validated_ledger":{"seq":0},"peers":0,"build_version":"unknown"}'
fi
body="$(jq -c --arg node "$NODE_LABEL" --argjson ts "$(date -u +%s)" \
  '{v:1, node:$node, ts:$ts, server_state:(.server_state // "unknown"),
    validated_ledger:(.validated_ledger.seq // 0), peers:(.peers // 0), build_version:(.build_version // "unknown")}' \
  <<<"$info")"
sig="$(printf '%s' "$body" | hmac_sha256_hex "$KEY")"
unset KEY

if [ "$PRINT" -eq 1 ]; then printf '%s\n%s\n' "$body" "$sig"; exit "$rc"; fi

[ -n "$RELAY_TARGET" ] || { echo "RELAY_TARGET not set in $CONF_DIR/heartbeat.conf" >&2; exit 3; }
[ -f "$CONF_DIR/id_ed25519" ] || { echo "missing SSH key $CONF_DIR/id_ed25519" >&2; exit 3; }
if printf '%s\n%s\n' "$body" "$sig" | ssh -T -i "$CONF_DIR/id_ed25519" -p "$RELAY_PORT" \
     -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes \
     -o UserKnownHostsFile="$CONF_DIR/known_hosts" "$RELAY_TARGET" >/dev/null; then
  echo "heartbeat sent: $body"
else
  echo "heartbeat send failed (ssh exit $?)" >&2; exit 2
fi
exit "$rc"
