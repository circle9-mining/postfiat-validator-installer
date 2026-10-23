#!/usr/bin/env bash
# pft-watchdog: dead-man's switch for a Post Fiat validator, run on a second host (e.g. the sentry).
#
# The validator pushes signed heartbeats (pft-heartbeat) over SSH to a forced-command account whose only
# possible command is `pft-watchdog receive`: it stores the raw message (<=4 KiB) in a spool directory and
# never sees the HMAC key. `check` (root, every 60s from pft-watchdog.timer) verifies every spooled message
# and decides one state:
#   BADSIG     a message failed verification this run (bad/missing HMAC, malformed, replayed ts, or ts more
#              than SKEW_TOL_SEC in the future)
#   STALE      no valid heartbeat for STALE_AFTER_SEC (measured on the signed ts, so skew counts too)
#   LAGGING    the heartbeat's validated ledger closed more than LAG_MAX_SEC before the heartbeat was taken,
#              per the PUBLIC_RPC ledger close_time; if the public RPC is unreachable lag is "unknown" and
#              the state can never be LAGGING
#   OK         none of the above;  RECOVERED  the first OK after STALE/LAGGING/BADSIG
# ntfy: one message when an incident state is entered (per-state cooldown COOLDOWN_SEC suppresses flapping
# repeats) and one RECOVERED when it ends (only if the incident message was sent). No reminders.
# Maintenance windows (../maint): a signed {"type":"maint"} message in the spool is handed to
# `pft-maint apply-remote` (sentry copy of the validator's window). While `pft-maint active` says a valid,
# unexpired window exists, STALE/LAGGING alerts are suppressed and counted (BADSIG never is). After the
# window closes, STALE/LAGGING stay held for POST_MAINT_GRACE_SEC while the node resyncs; an OK in that
# time ends the grace silently, otherwise the first run after the grace alerts once, even if the state
# did not change. POST_MAINT_GRACE_SEC=0 alerts on the first run after the window.
#
# Usage: pft-watchdog receive                 (forced command; reads the message on stdin)
#        sudo pft-watchdog check [--notify] [--json]
#        sudo pft-watchdog status
# Exit codes (check): 0 OK/RECOVERED, 1 LAGGING, 2 STALE/BADSIG, 3 usage/config error.
# Env: CONF_DIR (/etc/pft-watchdog: hmac.key, ntfy.env, both 0600 root)  STATE_DIR (/var/lib/pft-watchdog)
#      SPOOL_DIR (/var/lib/pft-watchdog-spool)  PUBLIC_RPC (https://rpc.testnet.postfiat.org)
#      STALE_AFTER_SEC (180)  LAG_MAX_SEC (60)  SKEW_TOL_SEC (30)  COOLDOWN_SEC (3600)
#      POST_MAINT_GRACE_SEC (1800)
#      NTFY_OUTBOX (if set, messages are appended to this file instead of sent; used by the tests)
#      PFT_MAINT_BIN (/usr/local/bin/pft-maint; missing or failing = no window, alerting stays live)

set -uo pipefail
umask 077

CONF_DIR="${CONF_DIR:-/etc/pft-watchdog}"
STATE_DIR="${STATE_DIR:-/var/lib/pft-watchdog}"
SPOOL_DIR="${SPOOL_DIR:-/var/lib/pft-watchdog-spool}"
PUBLIC_RPC="${PUBLIC_RPC:-https://rpc.testnet.postfiat.org}"
STALE_AFTER_SEC="${STALE_AFTER_SEC:-180}"
LAG_MAX_SEC="${LAG_MAX_SEC:-60}"
SKEW_TOL_SEC="${SKEW_TOL_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-3600}"
POST_MAINT_GRACE_SEC="${POST_MAINT_GRACE_SEC:-1800}"
PFT_MAINT_BIN="${PFT_MAINT_BIN:-/usr/local/bin/pft-maint}"
RIPPLE_EPOCH=946684800
MAX_MSG=4096
MAX_SPOOL=200

CMD="${1:-}"; [ $# -gt 0 ] && shift
NOTIFY=0 JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notify) NOTIFY=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done

# ---------- receive: forced command, unprivileged, no key ----------
if [ "$CMD" = receive ]; then
  [ -d "$SPOOL_DIR" ] || { echo "no spool dir" >&2; exit 3; }
  n=$(find "$SPOOL_DIR" -maxdepth 1 -name '*.msg' | wc -l)
  [ "$n" -lt "$MAX_SPOOL" ] || { echo "spool full" >&2; exit 3; }
  tmp="$(mktemp "$SPOOL_DIR/.in.XXXXXX")" || exit 3
  head -c $((MAX_MSG + 1)) > "$tmp"
  if [ "$(stat -c %s -- "$tmp")" -gt "$MAX_MSG" ]; then
    printf 'oversize\n' > "$tmp"   # kept so check reports it as BADSIG
  fi
  mv -- "$tmp" "$SPOOL_DIR/$(date -u +%s%N).msg"
  exit 0
fi

case "$CMD" in
  check|status) ;;
  *) sed -n '4,30p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$CMD" ] && exit 0; exit 3 ;;
esac
[ "$(id -u)" -eq 0 ] || [ -n "${PFT_WATCHDOG_TEST:-}" ] || { echo "run as root" >&2; exit 3; }
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
STATE="$STATE_DIR/state.json"
[ -f "$STATE" ] || jq -n --argjson t "$(date -u +%s)" \
  '{state:"OK", since:$t, first_run:$t, last_good:null, last_sent:{}, incident_notified:false}' > "$STATE"

if [ "$CMD" = status ]; then jq . "$STATE"; exit 0; fi

exec 9>"$STATE_DIR/.lock"
flock -w 50 9 || { echo "another check holds the lock" >&2; exit 3; }

key_ok() {
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
rpc() { curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d "$1" "$PUBLIC_RPC" 2>/dev/null; }

key_ok "$CONF_DIR/hmac.key" || exit 3
KEY="$(tr -d '[:space:]' < "$CONF_DIR/hmac.key")"
NOW="$(date -u +%s)"
last_good="$(jq -c '.last_good' "$STATE")"
last_ts="$(jq -r '.last_good.ts // 0' "$STATE")"
last_maint_ts="$(jq -r '.last_maint_ts // 0' "$STATE")"

# ---------- verify spooled messages, oldest first ----------
bad=0 bad_reasons="" good=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  reason=""
  mapfile -t lines < <(head -n 3 -- "$f")
  if [ "${#lines[@]}" -ne 2 ] || ! [[ "${lines[1]:-}" =~ ^[0-9a-f]{64}$ ]]; then
    reason=malformed
  elif [ "$(printf '%s' "${lines[0]}" | hmac_sha256_hex "$KEY")" != "${lines[1]}" ]; then
    reason=hmac_mismatch
  elif jq -e '.type? == "maint"' <<<"${lines[0]}" >/dev/null 2>&1; then
    ts="$(jq -r '.ts | if type=="number" then floor else 0 end' <<<"${lines[0]}" 2>/dev/null)"
    if [ "${ts:-0}" -le "$last_maint_ts" ]; then reason=maint_replay
    elif [ "$ts" -gt $((NOW + SKEW_TOL_SEC)) ]; then reason=ts_future
    else
      last_maint_ts="$ts"
      if [ -x "$PFT_MAINT_BIN" ]; then "$PFT_MAINT_BIN" apply-remote <<<"${lines[0]}" >&2 || echo "maint message not applied" >&2
      else echo "maint message received but $PFT_MAINT_BIN is not installed - ignored" >&2; fi
    fi
  elif ! hb="$(jq -ce 'select(.v==1 and (.ts|type)=="number" and (.validated_ledger|type)=="number"
                and (.peers|type)=="number" and (.server_state|type)=="string")' <<<"${lines[0]}" 2>/dev/null)"; then
    reason=bad_fields
  else
    ts="$(jq -r .ts <<<"$hb")"
    if [ "$ts" -le "$last_ts" ]; then reason=replay
    elif [ "$ts" -gt $((NOW + SKEW_TOL_SEC)) ]; then reason=ts_future
    else last_ts="$ts"; last_good="$hb"; good=$((good + 1))
    fi
  fi
  if [ -n "$reason" ]; then bad=$((bad + 1)); bad_reasons+="${reason} "; fi
  rm -f -- "$f"
done < <(find "$SPOOL_DIR" -maxdepth 1 -name '*.msg' 2>/dev/null | sort)
unset KEY

# ---------- lag against the public RPC ----------
lag="unknown" lag_note=""
age="null"
if [ "$last_good" != null ]; then
  age=$((NOW - $(jq -r .ts <<<"$last_good")))
  [ "$age" -lt 0 ] && age=0            # validator clock ahead (accepted only within SKEW_TOL_SEC)
  seq="$(jq -r .validated_ledger <<<"$last_good")"
  if [ "$seq" -gt 0 ]; then
    ct="$(rpc "{\"method\":\"ledger\",\"params\":[{\"ledger_index\":$seq}]}" | jq -r '.result.ledger.close_time // empty' 2>/dev/null)"
    if [[ "$ct" =~ ^[0-9]+$ ]]; then
      lag=$(( $(jq -r .ts <<<"$last_good") - (ct + RIPPLE_EPOCH) ))
      [ "$lag" -lt 0 ] && lag=0     # validator clock behind the network close time: within skew, not lag
    elif [ -n "$(rpc '{"method":"server_info"}' | jq -r '.result.info.validated_ledger.seq // empty' 2>/dev/null)" ]; then
      lag="unknown"; lag_note="ledger $seq not on public RPC"
    else
      lag="unknown"; lag_note="public RPC unreachable"
    fi
  else
    lag="none"; lag_note="no validated ledger (server_state $(jq -r .server_state <<<"$last_good"))"
  fi
fi

# ---------- decide state ----------
prev="$(jq -r .state "$STATE")"
first_run="$(jq -r .first_run "$STATE")"
if [ "$bad" -gt 0 ]; then cur=BADSIG; detail="$bad bad message(s): ${bad_reasons% }"
elif [ "$last_good" = null ] && [ $((NOW - first_run)) -le "$STALE_AFTER_SEC" ]; then cur=OK; detail="waiting for first heartbeat"
elif [ "$last_good" = null ] || [ "$age" -gt "$STALE_AFTER_SEC" ]; then
  cur=STALE; detail="no valid heartbeat for $([ "$last_good" = null ] && echo $((NOW - first_run)) || echo "$age")s (limit ${STALE_AFTER_SEC}s)"
elif [ "$lag" = none ]; then cur=LAGGING; detail="$lag_note"
elif [ "$lag" != unknown ] && [ "$lag" -gt "$LAG_MAX_SEC" ]; then cur=LAGGING; detail="validated ledger ${lag}s behind network close time (limit ${LAG_MAX_SEC}s) ${lag_note}"
else cur=OK; detail="heartbeat age ${age}s, lag ${lag}$([ "$lag" != unknown ] && echo s) ${lag_note}"
fi
detail="${detail% }"
shown="$cur"
[ "$cur" = OK ] && [ "$prev" != OK ] && shown=RECOVERED

# ---------- notify (dedupe per state, cooldown, paired recovery) ----------
send_ntfy() { # title, body, priority
  if [ -n "${NTFY_OUTBOX:-}" ]; then
    jq -nc --arg t "$1" --arg m "$2" --arg p "$3" '{title:$t, message:$m, priority:$p}' >> "$NTFY_OUTBOX"; return 0
  fi
  local env_file="$CONF_DIR/ntfy.env" k v NTFY_SERVER=https://ntfy.sh NTFY_TOPIC="" NTFY_TOKEN=""
  { [ -f "$env_file" ] && [ "$(stat -c %U -- "$env_file")" = root ] && [[ "$(stat -c %a -- "$env_file")" =~ ^[0-7]00$ ]]; } || { echo "ntfy: $env_file missing or not 0600 root - not sent" >&2; return 1; }
  while IFS='=' read -r k v; do
    case "$k" in NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN) printf -v "$k" '%s' "${v//\"/}" ;; esac
  done < <(grep -E '^(NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN)=' "$env_file")
  [ -n "$NTFY_TOPIC" ] || { echo "ntfy: no NTFY_TOPIC - not sent" >&2; return 1; }
  # URL and token go to curl via a config on an fd, never argv or env
  curl -s --max-time 15 -o /dev/null -w '%{http_code}' -K <(
    printf 'url = "%s/%s"\n' "$NTFY_SERVER" "$NTFY_TOPIC"
    printf 'header = "Title: %s"\nheader = "Priority: %s"\nheader = "Tags: pft-watchdog"\n' "$1" "$3"
    [ -n "$NTFY_TOKEN" ] && printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"
  ) --data-binary "$2" | grep -q '^2' || { echo "ntfy: send failed" >&2; return 1; }
}
notified=""
incident_notified="$(jq -r .incident_notified "$STATE")"
in_maint=false
[ -x "$PFT_MAINT_BIN" ] && "$PFT_MAINT_BIN" active >/dev/null 2>&1 && in_maint=true
was_maint="$(jq -r '.maint // false' "$STATE")"
# post-maintenance grace: 0 = none pending, else the epoch when it ends
grace_until="$(jq -r '.grace_until // 0 | floor' "$STATE")"
if [ "$in_maint" = true ]; then grace_until=0
elif [ "$was_maint" = true ]; then grace_until=$((NOW + POST_MAINT_GRACE_SEC)); fi
[ "$cur" = OK ] && grace_until=0
if [ "$NOTIFY" -eq 1 ]; then
  if [ "$in_maint" = true ] && { [ "$cur" = STALE ] || [ "$cur" = LAGGING ]; } \
     && { [ "$cur" != "$prev" ] || [ "$incident_notified" != true ]; }; then
    if [ "$cur" != "$prev" ]; then
      echo "ntfy: $cur suppressed (maintenance window)" >&2
      "$PFT_MAINT_BIN" suppressed watchdog "$cur $detail" >/dev/null 2>&1 || true
    fi
    incident_notified=false
  elif [ "$grace_until" -gt "$NOW" ] && { [ "$cur" = STALE ] || [ "$cur" = LAGGING ]; } && [ "$incident_notified" != true ]; then
    echo "ntfy: $cur held (post-maintenance grace, $((grace_until - NOW))s left)" >&2
    incident_notified=false
  elif [ "$grace_until" -gt 0 ] && [ "$grace_until" -le "$NOW" ] && [ "$cur" != OK ] && [ "$incident_notified" != true ]; then
    prio=high; [ "$cur" = LAGGING ] && prio=default
    send_ntfy "pft-watchdog $cur" "$detail (maintenance window closed, still not OK after ${POST_MAINT_GRACE_SEC}s grace)" "$prio" \
      && notified="$cur" && incident_notified=true && grace_until=0
  elif [ "$cur" != OK ] && [ "$cur" != "$prev" ]; then
    last_sent="$(jq -r --arg s "$cur" '.last_sent[$s] // 0 | floor' "$STATE")"
    if [ $((NOW - last_sent)) -ge "$COOLDOWN_SEC" ]; then
      prio=high; [ "$cur" = LAGGING ] && prio=default
      send_ntfy "pft-watchdog $cur" "$detail" "$prio" && notified="$cur" && incident_notified=true
    else
      echo "ntfy: $cur suppressed (cooldown, last sent $((NOW - last_sent))s ago)" >&2; incident_notified=false
    fi
  elif [ "$shown" = RECOVERED ]; then
    if [ "$incident_notified" = true ]; then
      send_ntfy "pft-watchdog RECOVERED" "was $prev; $detail" default && notified=RECOVERED
    else echo "ntfy: RECOVERED not sent (incident alert was not sent)" >&2
    fi
    incident_notified=false
  fi
fi

# ---------- persist and report ----------
since="$(jq -r .since "$STATE")"; [ "$cur" != "$prev" ] && since="$NOW"
jq --arg s "$cur" --argjson since "$since" --argjson lg "$last_good" --arg n "$notified" --argjson now "$NOW" \
   --argjson inc "$incident_notified" \
  --argjson mt "$last_maint_ts" --argjson im "$in_maint" --argjson gu "$grace_until" \
  '.state=$s | .since=$since | .last_good=$lg | .incident_notified=$inc | .last_maint_ts=$mt | .maint=$im | .grace_until=$gu
   | if $n != "" then .last_sent[$n]=$now else . end' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"

if [ "$JSON" -eq 1 ]; then
  jq -nc --arg st "$shown" --arg prev "$prev" --arg d "$detail" --argjson age "$age" --arg lag "$lag" \
    --argjson good "$good" --argjson bad "$bad" --arg n "$notified" --argjson now "$NOW" \
    --argjson im "$in_maint" --argjson gu "$grace_until" \
    '{time:($now|todate), state:$st, prev:$prev, detail:$d, heartbeat_age_sec:$age, lag_sec:$lag,
      good_msgs:$good, bad_msgs:$bad, maint:$im, grace_left_sec:([$gu - $now, 0]|max),
      notified:(if $n=="" then null else $n end)}'
else
  printf '%s state=%s prev=%s good=%s bad=%s maint=%s notified=%s | %s\n' "$(date -u -d "@$NOW" +%FT%TZ)" \
    "$shown" "$prev" "$good" "$bad" "$in_maint" "${notified:-none}" "$detail"
fi
case "$cur" in OK) exit 0 ;; LAGGING) exit 1 ;; *) exit 2 ;; esac
