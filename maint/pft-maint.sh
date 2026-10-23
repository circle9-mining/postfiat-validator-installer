#!/usr/bin/env bash
# pft-maint: time-boxed planned-maintenance windows for a Post Fiat validator + sentry setup.
#
# `start` writes a root-owned 0644 JSON flag {v,id,reason,start,expiry,host,origin} and pushes a signed copy to
# the sentry over the watchdog's restricted SSH channel (forced command `pft-watchdog receive`; the watchdog's
# root `check` verifies the HMAC and calls `pft-maint apply-remote`). While a VALID, UNEXPIRED flag exists,
# pft-watchdog (STALE/LAGGING), postfiat-monitor and pft-integrity suppress and count their alerts.
# An expired, malformed, wrongly-owned or over-long flag is ignored: alerting fails open.
# Exactly one ntfy message is sent at start, and exactly one at `end` or at expiry (from `tick`).
#
# Usage: sudo pft-maint start --ttl 30m|1h|SECONDS --reason "text" [--no-sentry]
#        sudo pft-maint end [--reason "text"]
#        pft-maint status [--json]          window, flag validity, suppressed counts, locks
#        pft-maint active                   exit 0 only for a valid unexpired flag (used by the alerters)
#        sudo pft-maint tick                expiry handling, run every 60s by pft-maint-tick.timer
#        sudo pft-maint restart-node [--timeout SEC]   guarded postfiatd restart inside an active window
#        sudo pft-maint lock add NAME --until ISO8601|EPOCH [--reason "text"] | lock rm NAME | lock list
#        sudo pft-maint suppressed CONSUMER "what"     record one suppressed alert (called by the alerters)
#        sudo pft-maint apply-remote        (sentry, called by pft-watchdog check) apply a verified start/end
# Exit codes: 0 ok / active, 1 no active window (active) or check failed (restart-node), 2 malformed flag
#   (active) or restart timeout, 3 usage/config error, 4 refused (no window, lock held, node not full).
# Env: MAINT_DIR (/var/lib/pft-maint)  CONF_DIR (/etc/pft-maint: ntfy.env, maint.conf)
#      WD_CONF_DIR (/etc/pft-watchdog: hmac.key, id_ed25519, known_hosts, heartbeat.conf)
#      MAX_TTL_SEC (14400)  CONTAINER (postfiatd)  RESTART_TIMEOUT (600)  POST_TIMEOUT (300)  POLL_SEC (5)
#      Test hooks: PFT_MAINT_TEST=1 (no root/owner checks)  PFT_MAINT_NOW_FILE (fake clock; sleeps advance it)
#      PFT_MAINT_RPC_CMD (stub: called with a method name, prints the JSON result)  RESTART_CMD  NTFY_OUTBOX

set -uo pipefail
umask 022

MAINT_DIR="${MAINT_DIR:-/var/lib/pft-maint}"
CONF_DIR="${CONF_DIR:-/etc/pft-maint}"
WD_CONF_DIR="${WD_CONF_DIR:-/etc/pft-watchdog}"
MAX_TTL_SEC="${MAX_TTL_SEC:-14400}"
CONTAINER="${CONTAINER:-postfiatd}"
RESTART_TIMEOUT="${RESTART_TIMEOUT:-600}"
POST_TIMEOUT="${POST_TIMEOUT:-300}"
POLL_SEC="${POLL_SEC:-5}"
FLAG="$MAINT_DIR/flag.json"
HIST="$MAINT_DIR/history.jsonl"
SUPP="$MAINT_DIR/suppressed.log"
LOCKS="$MAINT_DIR/locks"
TEST="${PFT_MAINT_TEST:-}"

CMD="${1:-}"; [ $# -gt 0 ] && shift
usage() { sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'; }

now() { if [ -n "${PFT_MAINT_NOW_FILE:-}" ]; then cat "$PFT_MAINT_NOW_FILE"; else date -u +%s; fi; }
nap() { # sleep, or advance the fake clock
  if [ -n "${PFT_MAINT_NOW_FILE:-}" ]; then echo $(( $(now) + $1 )) > "$PFT_MAINT_NOW_FILE"; else sleep "$1"; fi
}
iso() { date -u -d "@$1" +%FT%TZ; }
need_root() { [ "$(id -u)" -eq 0 ] || [ -n "$TEST" ] || { echo "run as root" >&2; exit 3; }; }
host_label() {
  local l=""
  [ -f "$CONF_DIR/maint.conf" ] && l="$(sed -n 's/^NODE_LABEL=//p' "$CONF_DIR/maint.conf" | tr -d '"' | head -1)"
  [ -z "$l" ] && [ -r "$WD_CONF_DIR/heartbeat.conf" ] && l="$(sed -n 's/^NODE_LABEL=//p' "$WD_CONF_DIR/heartbeat.conf" | tr -d '"' | head -1)"
  echo "${l:-$(hostname -s)}"
}
parse_ttl() {
  case "$1" in
    *[!0-9smh]*|"") return 1 ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *h) echo $(( ${1%h} * 3600 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}

# ---------- flag validation (shared by every consumer through `pft-maint active`) ----------
# Prints one of: active <json> | expired <json> | none | malformed <why>
flag_state() {
  local f="${1:-$FLAG}" t j
  [ -e "$f" ] || { echo none; return; }
  { [ -f "$f" ] && [ ! -L "$f" ]; } || { echo "malformed not a regular file"; return; }
  if [ -z "$TEST" ]; then
    [ "$(stat -c %u -- "$f")" = 0 ] || { echo "malformed not owned by root"; return; }
  fi
  [ $(( 8#$(stat -c %a -- "$f") & 8#022 )) -eq 0 ] || { echo "malformed group/other-writable"; return; }
  [ "$(stat -c %s -- "$f")" -le 4096 ] || { echo "malformed larger than 4 KiB"; return; }
  j="$(jq -ce --argjson max "$MAX_TTL_SEC" 'select(.v==1 and (.id|type)=="string" and (.reason|type)=="string"
        and (.host|type)=="string" and (.start|type)=="number" and (.expiry|type)=="number"
        and .expiry > .start and (.expiry - .start) <= $max)' "$f" 2>/dev/null)" \
    || { echo "malformed bad JSON, missing fields or TTL over ${MAX_TTL_SEC}s"; return; }
  t="$(now)"
  [ "$(jq -r '.start' <<<"$j")" -le $((t + 60)) ] || { echo "malformed start in the future"; return; }
  if [ "$t" -lt "$(jq -r '.expiry' <<<"$j")" ]; then echo "active $j"; else echo "expired $j"; fi
}

supp_counts() { # id -> "watchdog=N monitor=N integrity=N"
  local id="$1" c out=""
  for c in watchdog monitor integrity; do
    out+="$c=$(awk -v id="$id" -v c="$c" '$2==id && $3==c' "$SUPP" 2>/dev/null | wc -l) "
  done
  echo "${out% }"
}

send_ntfy() { # title message priority
  if [ -n "${NTFY_OUTBOX:-}" ]; then
    jq -nc --arg t "$1" --arg m "$2" --arg p "$3" '{title:$t, message:$m, priority:$p}' >> "$NTFY_OUTBOX"; return 0
  fi
  local env_file k v NTFY_SERVER=https://ntfy.sh NTFY_TOPIC="" NTFY_TOKEN=""
  for env_file in "$CONF_DIR/ntfy.env" /etc/postfiat-monitor.env /etc/pft-integrity.env ""; do
    [ -f "$env_file" ] && break
  done
  [ -n "$env_file" ] || { echo "ntfy: no ntfy.env found - not sent" >&2; return 1; }
  { [ "$(stat -c %u -- "$env_file")" = 0 ] && [ $(( 8#$(stat -c %a -- "$env_file") & 8#022 )) -eq 0 ]; } \
    || { echo "ntfy: $env_file must be root-owned and not group/other-writable - not sent" >&2; return 1; }
  while IFS='=' read -r k v; do   # data, never sourced
    case "$k" in NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN) printf -v "$k" '%s' "${v//\"/}" ;; esac
  done < <(grep -E '^(NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN)=' "$env_file")
  [ -n "$NTFY_TOPIC" ] || { echo "ntfy: no NTFY_TOPIC in $env_file - not sent" >&2; return 1; }
  # URL and token reach curl through a config on an fd, never argv
  curl -s --max-time 15 -o /dev/null -w '%{http_code}' -K <(
    printf 'url = "%s/%s"\n' "$NTFY_SERVER" "$NTFY_TOPIC"
    printf 'header = "Title: %s"\nheader = "Priority: %s"\nheader = "Tags: pft-maint"\n' "$1" "$3"
    [ -n "$NTFY_TOKEN" ] && printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"
  ) --data-binary "$2" | grep -q '^2' || { echo "ntfy: send failed" >&2; return 1; }
}

# HMAC-SHA256 with bash builtins (same as pft-heartbeat): key hex in $1, message on stdin. Key never in argv.
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
# Push a signed {"type":"maint"} message to the sentry's pft-watchdog spool. Prints pushed|skipped|failed.
push_sentry() { # action flag_json
  local conf="$WD_CONF_DIR/heartbeat.conf" target port=22 key body sig
  { [ -r "$conf" ] && [ -r "$WD_CONF_DIR/hmac.key" ] && [ -r "$WD_CONF_DIR/id_ed25519" ]; } || { echo skipped; return; }
  target="$(sed -n 's/^RELAY_TARGET=//p' "$conf" | tr -d '"')"
  port="$(sed -n 's/^RELAY_PORT=//p' "$conf" | tr -d '"')"
  [ -n "$target" ] || { echo skipped; return; }
  grep -qxE '[0-9a-fA-F]{64}' "$WD_CONF_DIR/hmac.key" || { echo failed; return; }
  key="$(tr -d '[:space:]' < "$WD_CONF_DIR/hmac.key")"
  body="$(jq -c --arg a "$1" --argjson ts "$(date -u +%s)" '{v:1, type:"maint", action:$a, ts:$ts, flag:.}' <<<"$2")"
  sig="$(printf '%s' "$body" | hmac_sha256_hex "$key")"; unset key
  if printf '%s\n%s\n' "$body" "$sig" | ssh -T -i "$WD_CONF_DIR/id_ed25519" -p "${port:-22}" -o BatchMode=yes \
       -o IdentitiesOnly=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes \
       -o UserKnownHostsFile="$WD_CONF_DIR/known_hosts" "$target" >/dev/null 2>&1; then
    echo pushed
  else
    echo failed
  fi
}

write_flag() { # json  (atomic, 0644 root)
  local tmp; tmp="$(mktemp "$MAINT_DIR/.flag.XXXXXX")" || return 1
  printf '%s\n' "$1" > "$tmp" && chmod 644 "$tmp" && mv -f -- "$tmp" "$FLAG"
}
archive_flag() { # flag_json how(end|expired|remote-end|remote-expired) note
  local j="$1"
  jq -c --arg how "$2" --arg note "$3" --argjson at "$(now)" --arg s "$(supp_counts "$(jq -r .id <<<"$j")")" \
    '. + {ended_at:$at, ended_how:$how, note:$note, suppressed:$s}' <<<"$j" >> "$HIST"
  rm -f -- "$FLAG"
}

lock_state() { # prints "NAME until reason" for every unexpired lock
  local f n u r t; t="$(now)"
  for f in "$LOCKS"/*.lock; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .lock)"; u="$(sed -n 's/^until=//p' "$f")"; r="$(sed -n 's/^reason=//p' "$f")"
    [[ "$u" =~ ^[0-9]+$ ]] || { echo "$n malformed-lock(treated-as-held) $r"; continue; }
    [ "$u" -gt "$t" ] && echo "$n $(iso "$u") $r"
  done
}

rpc() { # method -> JSON .result
  if [ -n "${PFT_MAINT_RPC_CMD:-}" ]; then "$PFT_MAINT_RPC_CMD" "$1"; return; fi
  docker exec "$CONTAINER" curl -s --max-time 10 http://localhost:5005/ -X POST \
    -H 'Content-Type: application/json' -d "{\"method\":\"$1\",\"params\":[{}]}" 2>/dev/null | jq -c '.result // empty' 2>/dev/null
}
node_snapshot() { # -> "state peers validated_seq sentry_up(0/1)"
  local info peers st n seq sentry=0 sip=""
  info="$(rpc server_info)"; peers="$(rpc peers)"
  [ -n "$info" ] || info='{}'; [ -n "$peers" ] || peers='{}'
  st="$(jq -r '.info.server_state // "down"' <<<"$info" 2>/dev/null)"; st="${st:-down}"
  n="$(jq -r '.info.peers // 0' <<<"$info" 2>/dev/null)"; n="${n:-0}"
  seq="$(jq -r '.info.validated_ledger.seq // 0' <<<"$info" 2>/dev/null)"; seq="${seq:-0}"
  sip="$(sentry_addr)"
  if [ -n "$sip" ] && jq -e --arg ip "$sip" '[.peers[]?.address | select(startswith($ip + ":"))] | length > 0' \
       <<<"$peers" >/dev/null 2>&1; then sentry=1; fi
  echo "$st $n $seq $sentry"
}
sentry_addr() {
  local a=""
  [ -f "$CONF_DIR/maint.conf" ] && a="$(sed -n 's/^SENTRY_ADDR=//p' "$CONF_DIR/maint.conf" | tr -d '"' | head -1)"
  [ -z "$a" ] && [ -r "$WD_CONF_DIR/heartbeat.conf" ] && a="$(sed -n 's/^RELAY_TARGET=.*@//p' "$WD_CONF_DIR/heartbeat.conf" | tr -d '"')"
  echo "$a"
}

case "$CMD" in
  active)
    s="$(flag_state)"; case "$s" in active*) exit 0 ;; malformed*) exit 2 ;; *) exit 1 ;; esac ;;
  status)
    JSON=0; [ "${1:-}" = --json ] && JSON=1
    s="$(flag_state)"; st="${s%% *}"; j=null; why=""
    case "$st" in active|expired) j="${s#* }" ;; malformed) why="${s#* }" ;; esac
    id="$(jq -r '.id // empty' <<<"$j" 2>/dev/null)"
    locks="$(lock_state)"
    if [ "$JSON" -eq 1 ]; then
      jq -nc --arg st "$st" --argjson f "$j" --arg why "$why" --arg sup "$([ -n "$id" ] && supp_counts "$id")" \
        --arg locks "$locks" --argjson now "$(now)" \
        '{time:($now|todate), window:$st, flag:$f, malformed_reason:(if $why=="" then null else $why end),
          remaining_sec:(if $f==null then null else ([$f.expiry - $now, 0]|max) end),
          suppressed:$sup, locks:($locks|split("\n")|map(select(.!="")))}'
    else
      case "$st" in
        active)  echo "window ACTIVE on $(jq -r .host <<<"$j"): $(jq -r .reason <<<"$j") | until $(iso "$(jq -r .expiry <<<"$j")") ($(( $(jq -r .expiry <<<"$j") - $(now) ))s left) | origin $(jq -r .origin <<<"$j") | suppressed: $(supp_counts "$id")" ;;
        expired) echo "window EXPIRED at $(iso "$(jq -r .expiry <<<"$j")") (alerting is live; tick will close it): $(jq -r .reason <<<"$j")" ;;
        none)    echo "no maintenance window (alerting is live)" ;;
        *)       echo "flag IGNORED ($why) - alerting is live" ;;
      esac
      if [ -n "$locks" ]; then echo "data-collection locks held:"; printf '  %s\n' "${locks//$'\n'/$'\n'  }"; else echo "no data-collection locks"; fi
    fi
    exit 0 ;;
esac

need_root
mkdir -p "$MAINT_DIR" "$LOCKS" && chmod 755 "$MAINT_DIR"
exec 9>"$MAINT_DIR/.lock"
flock -w 30 9 || { echo "another pft-maint run holds the lock" >&2; exit 3; }

case "$CMD" in
start)
  ttl="" reason="" sentry=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl) ttl="$(parse_ttl "${2:-}")" || { echo "bad --ttl" >&2; exit 3; }; shift ;;
      --reason) reason="${2:-}"; shift ;;
      --no-sentry) sentry=0 ;;
      *) echo "unknown argument: $1" >&2; exit 3 ;;
    esac; shift
  done
  { [ -n "$ttl" ] && [ -n "$reason" ]; } || { echo "start needs --ttl and --reason" >&2; exit 3; }
  { [ "$ttl" -gt 0 ] && [ "$ttl" -le "$MAX_TTL_SEC" ]; } || { echo "--ttl must be 1..${MAX_TTL_SEC}s" >&2; exit 3; }
  s="$(flag_state)"
  case "$s" in active*) echo "a window is already active: $(jq -r .reason <<<"${s#* }") - end it first" >&2; exit 4 ;; esac
  t="$(now)"
  j="$(jq -nc --arg id "m$t-$$" --arg r "$reason" --arg h "$(host_label)" --argjson s "$t" --argjson e $((t + ttl)) \
        '{v:1, id:$id, reason:$r, start:$s, expiry:$e, host:$h, origin:"local"}')"
  case "$s" in expired*|malformed*) rm -f -- "$FLAG" ;; esac   # stale or bad flag never blocks a new window
  write_flag "$j" || { echo "cannot write $FLAG" >&2; exit 3; }
  sp=skipped; [ "$sentry" -eq 1 ] && sp="$(push_sentry start "$j")"
  send_ntfy "[MAINT] start $(host_label)" "$reason | until $(iso $((t + ttl))) (ttl ${ttl}s) | sentry copy: $sp" default
  echo "window started: id $(jq -r .id <<<"$j") until $(iso $((t + ttl))) | sentry copy: $sp"
  [ "$sp" = failed ] && { echo "WARNING: sentry copy not pushed - the watchdog will still page" >&2; }
  exit 0 ;;
end)
  reason="ended by operator"
  [ "${1:-}" = --reason ] && reason="${2:-$reason}"
  s="$(flag_state)"
  case "$s" in
    active*|expired*)
      j="${s#* }"
      [ "$(jq -r .origin <<<"$j")" = local ] || { echo "this is a sentry copy; end the window on its origin host" >&2; exit 4; }
      sup="$(supp_counts "$(jq -r .id <<<"$j")")"
      sp="$(push_sentry end "$j")"
      how=end; [ "${s%% *}" = expired ] && how=expired
      archive_flag "$j" "$how" "$reason"
      send_ntfy "[MAINT] end $(host_label)" "$(jq -r .reason <<<"$j") | $reason after $(( $(now) - $(jq -r .start <<<"$j") ))s | suppressed here: $sup | sentry copy: $sp" default
      echo "window ended ($how): suppressed $sup | sentry copy: $sp"; exit 0 ;;
    malformed*) rm -f -- "$FLAG"; echo "removed malformed flag (${s#* })"; exit 0 ;;
    *) echo "no maintenance window"; exit 0 ;;
  esac ;;
tick)
  s="$(flag_state)"
  case "$s" in
    expired*)
      j="${s#* }"
      if [ "$(jq -r .origin <<<"$j")" = local ]; then
        sup="$(supp_counts "$(jq -r .id <<<"$j")")"
        archive_flag "$j" expired "TTL reached"
        send_ntfy "[MAINT] end $(host_label)" "$(jq -r .reason <<<"$j") | expired at $(iso "$(jq -r .expiry <<<"$j")") (TTL) - alerting is live | suppressed here: $sup" default
        echo "window expired and closed: suppressed $sup"
      else
        archive_flag "$j" remote-expired "TTL reached"; echo "sentry copy expired and closed (no message: the origin host reports)"
      fi ;;
    malformed*) echo "flag ignored: ${s#* } (alerting is live)" ;;
    active*) echo "window active, $(( $(jq -r .expiry <<<"${s#* }") - $(now) ))s left" ;;
    *) : ;;
  esac
  exit 0 ;;
suppressed)
  c="${1:-}"; what="${2:-}"
  case "$c" in watchdog|monitor|integrity) ;; *) echo "consumer must be watchdog|monitor|integrity" >&2; exit 3 ;; esac
  s="$(flag_state)"; case "$s" in active*) ;; *) echo "no active window - not recorded" >&2; exit 1 ;; esac
  printf '%s %s %s %s\n' "$(now)" "$(jq -r .id <<<"${s#* }")" "$c" "$(tr -d '\n' <<<"$what" | cut -c1-200)" >> "$SUPP"
  exit 0 ;;
apply-remote)
  body="$(head -c 4096)"
  a="$(jq -r '.action // empty' <<<"$body" 2>/dev/null)"
  f="$(jq -c '.flag | select(type=="object") | .origin="remote"' <<<"$body" 2>/dev/null)"
  [ -n "$f" ] || { echo "apply-remote: no flag object" >&2; exit 3; }
  case "$a" in
    start)
      tmpf="$(mktemp "$MAINT_DIR/.chk.XXXXXX")"; printf '%s\n' "$f" > "$tmpf"; chmod 644 "$tmpf"
      s="$(flag_state "$tmpf")"; rm -f -- "$tmpf"
      case "$s" in active*) write_flag "$f" && echo "sentry copy applied: $(jq -r .id <<<"$f") until $(iso "$(jq -r .expiry <<<"$f")")" ;;
                   *) echo "apply-remote: refused ($s)" >&2; exit 4 ;; esac ;;
    end)
      cur="$(flag_state)"
      if [ "${cur%% *}" = active ] || [ "${cur%% *}" = expired ]; then
        j="${cur#* }"
        if [ "$(jq -r .id <<<"$j")" = "$(jq -r .id <<<"$f")" ]; then archive_flag "$j" remote-end "ended on origin"; echo "sentry copy ended"; exit 0; fi
      fi
      echo "apply-remote: end for a window that is not the current copy - ignored" ;;
    *) echo "apply-remote: unknown action" >&2; exit 3 ;;
  esac
  exit 0 ;;
lock)
  sub="${1:-}"; [ $# -gt 0 ] && shift
  case "$sub" in
    add)
      n="${1:-}"; [ $# -gt 0 ] && shift; until_="" r=""
      while [ $# -gt 0 ]; do
        case "$1" in --until) until_="${2:-}"; shift ;; --reason) r="${2:-}"; shift ;; *) echo "unknown argument: $1" >&2; exit 3 ;; esac; shift
      done
      [[ "$n" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { echo "lock name: [A-Za-z0-9_.-]{1,64}" >&2; exit 3; }
      [[ "$until_" =~ ^[0-9]+$ ]] || until_="$(date -u -d "$until_" +%s 2>/dev/null)" || { echo "bad --until" >&2; exit 3; }
      printf 'until=%s\nreason=%s\n' "$until_" "$(tr -d '\n' <<<"$r")" > "$LOCKS/$n.lock"
      echo "lock $n held until $(iso "$until_")" ;;
    rm) rm -f -- "$LOCKS/${1:?lock rm NAME}.lock"; echo "lock ${1} removed" ;;
    list|"") l="$(lock_state)"; [ -n "$l" ] && echo "$l" || echo "no data-collection locks" ;;
    *) echo "lock add|rm|list" >&2; exit 3 ;;
  esac
  exit 0 ;;
restart-node)
  [ "${1:-}" = --timeout ] && RESTART_TIMEOUT="${2:?}"
  verdict() { echo "restart-node $1: $2"; exit "$3"; }
  s="$(flag_state)"
  case "$s" in active*) ;; *) verdict REFUSED "no active maintenance window (${s%% *}) - run: pft-maint start --ttl 30m --reason ..." 4 ;; esac
  left=$(( $(jq -r .expiry <<<"${s#* }") - $(now) ))
  [ "$left" -ge $((RESTART_TIMEOUT + POST_TIMEOUT)) ] \
    || verdict REFUSED "window has ${left}s left, restart may need up to $((RESTART_TIMEOUT + POST_TIMEOUT))s - extend it (end + start)" 4
  l="$(lock_state)"
  [ -z "$l" ] || verdict REFUSED "data-collection lock held: $(tr '\n' ';' <<<"$l")" 4
  read -r st0 p0 seq0 sen0 <<<"$(node_snapshot)"
  case "$st0" in full|proposing) ;; *) verdict REFUSED "server_state is $st0 before restart (need full)" 4 ;; esac
  echo "pre:  server_state=$st0 peers=$p0 validated=$seq0 sentry_peered=$sen0"
  t0="$(now)"
  if [ -n "${RESTART_CMD:-}" ]; then $RESTART_CMD >/dev/null 2>&1; else docker restart -t 60 "$CONTAINER" >/dev/null 2>&1; fi \
    || verdict FAIL "restart command failed" 1
  echo "restarted $CONTAINER at $(iso "$t0"); waiting up to ${RESTART_TIMEOUT}s for full"
  st=down
  while :; do
    read -r st p seq sen <<<"$(node_snapshot)"
    case "$st" in full|proposing) break ;; esac
    [ $(( $(now) - t0 )) -ge "$RESTART_TIMEOUT" ] && verdict TIMEOUT "server_state $st after ${RESTART_TIMEOUT}s (window still active; investigate: sudo postfiat-health)" 2
    nap "$POLL_SEC"
  done
  tfull=$(( $(now) - t0 )); echo "full after ${tfull}s"
  t1="$(now)"
  while :; do
    read -r st p seq sen <<<"$(node_snapshot)"
    d=$(( p - p0 )); d=${d#-}
    if [ "$d" -le 2 ] && { [ "$sen0" = 0 ] || [ "$sen" = 1 ]; } && [ "$seq" -gt "$seq0" ]; then break; fi
    [ $(( $(now) - t1 )) -ge "$POST_TIMEOUT" ] && break
    nap "$POLL_SEC"
  done
  fails=""
  [ "$d" -le 2 ] || fails+=" peers $p0->$p (outside +-2);"
  [ "$sen0" = 0 ] || [ "$sen" = 1 ] || fails+=" sentry not peered;"
  [ "$seq" -gt "$seq0" ] || fails+=" ledger not advancing ($seq0->$seq);"
  summary="server_state $st after ${tfull}s; peers $p0->$p; sentry $([ "$sen" = 1 ] && echo up || echo down)$([ "$sen0" = 0 ] && echo ' (not peered before)'); validated $seq0->$seq"
  [ -z "$fails" ] && verdict PASS "$summary" 0
  verdict FAIL "$summary |${fails%;}" 1 ;;
*) usage; [ -z "$CMD" ] && exit 0; exit 3 ;;
esac
