#!/usr/bin/env bash
# pft-resync: measure how long a Post Fiat node takes to recover (RTO) when its ledger DB is lost and there is
# no backup, i.e. a cold resync from the network. Run it on a SENTRY first, never on a validator you rely on.
#
# Usage: pft-resync plan  [--container NAME]
#        sudo pft-resync drill --yes [--container NAME] [--timeout SEC] [--keep-old] [--out FILE]
#        pft-resync report FILE [--json]
#
#  plan    read-only preflight: container, DB path (the mount at /var/lib/postfiatd/db), DB size (= disk a drill
#          frees), server_state, peers, complete_ledgers, free disk, maintenance window, and whether `drill` would
#          be allowed right now. Changes nothing.
#  drill   refuses (exit 4) unless --yes is given, a valid pft-maint window is active with at least
#          TIMEOUT + 300 s left, no pft-maint data-collection lock is held, and the node is full. Then: stop the
#          container, rename the DB dir aside (same parent, so same filesystem), create an empty DB dir with the
#          same owner/mode, start the container and poll server_info every POLL_SEC s. Every event and poll is one
#          JSON line in FILE (default /var/lib/pft-resync/runs/<id>.jsonl) and on stdout.
#          PASS = server_state full AND a validated ledger above the pre-drill one, within TIMEOUT s of the start.
#          On PASS the old DB is deleted (kept with --keep-old). On timeout, or SIGINT/SIGTERM after the DB was
#          moved, it rolls back: stop, delete the fresh DB, rename the old DB back, start, wait for full.
#  report  per-phase seconds from a drill's JSONL file.
#
# Phases are seconds after `docker start`, timed when the server_info ANSWER arrived (rpc_s = how long it took). States are ranked disconnected < connected < syncing < tracking < full
# (validating/proposing count as full); "time to X" is the first poll whose state ranks >= X, so a node that
# jumps from connected straight to full gets the same time for syncing and full. `observed` lists the states
# actually seen, so a skipped state is visible.
# Exit codes: 0 PASS / ok, 1 timed out and rolled back, 3 usage/config error, 4 refused, 5 rollback failed,
#             6 interrupted (rolled back).
# Env: CONTAINER (postfiatd)  TIMEOUT (1800)  POLL_SEC (5)  RUN_DIR (/var/lib/pft-resync/runs)  MAINT_MARGIN (300)
#      Test hooks: PFT_RESYNC_TEST=1 (no root)  PFT_RESYNC_NOW_FILE (fake clock; sleeps advance it)
#      PFT_RESYNC_RPC_CMD (stub, prints the server_info .result JSON)  PFT_RESYNC_DOCKER_CMD (stub for docker)
#      PFT_RESYNC_MAINT_CMD (stub for pft-maint)

# jq programs are single-quoted on purpose ($t, $s ... are jq variables).
# "A && B || die/refuse" is intended: die and refuse always exit.
# shellcheck disable=SC2016,SC2015
set -uo pipefail
umask 022

CONTAINER="${CONTAINER:-postfiatd}"
TIMEOUT="${TIMEOUT:-1800}"
POLL_SEC="${POLL_SEC:-5}"
RUN_DIR="${RUN_DIR:-/var/lib/pft-resync/runs}"
MAINT_MARGIN="${MAINT_MARGIN:-300}"
DB_MOUNT=/var/lib/postfiatd/db
TEST="${PFT_RESYNC_TEST:-}"
DOCKER="${PFT_RESYNC_DOCKER_CMD:-docker}"
MAINT="${PFT_RESYNC_MAINT_CMD:-pft-maint}"

usage() { sed -n '4,31p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "pft-resync: $1" >&2; exit "${2:-3}"; }

now() { if [ -n "${PFT_RESYNC_NOW_FILE:-}" ]; then cat "$PFT_RESYNC_NOW_FILE"; else date -u +%s; fi; }
nap() { if [ -n "${PFT_RESYNC_NOW_FILE:-}" ]; then echo $(( $(now) + $1 )) > "$PFT_RESYNC_NOW_FILE"; else sleep "$1"; fi; }
iso() { date -u -d "@$1" +%FT%TZ; }

server_info() { # -> .result.info JSON, or {} when the RPC does not answer
  local r
  if [ -n "${PFT_RESYNC_RPC_CMD:-}" ]; then r="$("$PFT_RESYNC_RPC_CMD" server_info)"
  else r="$("$DOCKER" exec "$CONTAINER" curl -s --max-time 5 http://127.0.0.1:5005/ -X POST \
              -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' 2>/dev/null \
            | jq -c '.result // empty' 2>/dev/null)"; fi
  [ -n "$r" ] || r='{}'
  jq -c '.info // {}' <<<"$r" 2>/dev/null || echo '{}'
}
# snap INFO -> {state,rank,peers,validated,complete}
snap() {
  jq -c '(.server_state // "down") as $s
    | {state:$s,
       rank:({"down":-1,"disconnected":0,"connected":1,"syncing":2,"tracking":3,"full":4,"validating":4,"proposing":4}[$s] // -1),
       peers:(.peers // 0), validated:(.validated_ledger.seq // 0), complete:(.complete_ledgers // "")}' <<<"$1"
}

db_dir() { # host path mounted at /var/lib/postfiatd/db
  "$DOCKER" inspect -f "{{range .Mounts}}{{if eq .Destination \"$DB_MOUNT\"}}{{.Source}}{{end}}{{end}}" "$CONTAINER" 2>/dev/null
}
db_dir_ok() { # refuse anything that is not an absolute, non-symlink directory at least 3 levels deep
  local d="$1"
  [[ "$d" == /* ]] && [ -d "$d" ] && [ ! -L "$d" ] || return 1
  [ "$(tr -cd / <<<"${d%/}" | wc -c)" -ge 3 ]
}
bytes() { du -sb "$1" 2>/dev/null | cut -f1; }

# maint_gate -> prints "ok <remaining>" or "refuse <reason>"
maint_gate() {
  local j w rem nl
  j="$("$MAINT" status --json 2>/dev/null)" || { echo "refuse pft-maint status failed (is pft-maint installed?)"; return; }
  w="$(jq -r '.window // "none"' <<<"$j" 2>/dev/null)"
  rem="$(jq -r '.remaining_sec // 0' <<<"$j" 2>/dev/null)"; [[ "$rem" =~ ^[0-9]+$ ]] || rem=0
  nl="$(jq -r '.locks | length' <<<"$j" 2>/dev/null)"; [[ "$nl" =~ ^[0-9]+$ ]] || nl=1
  if [ "$w" != active ]; then echo "refuse no active pft-maint window (window=$w); run: sudo pft-maint start --ttl 60m --reason ..."
  elif [ "$rem" -lt $((TIMEOUT + MAINT_MARGIN)) ]; then echo "refuse window has ${rem}s left, drill needs TIMEOUT+MAINT_MARGIN=$((TIMEOUT + MAINT_MARGIN))s"
  elif [ "$nl" -gt 0 ]; then echo "refuse $nl pft-maint data-collection lock(s) held: $(jq -r '.locks | join("; ")' <<<"$j")"
  else echo "ok $rem"; fi
}

CMD="${1:-}"; [ $# -gt 0 ] && shift
YES=0; KEEP=0; OUT=""; JSON=0; FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --keep-old) KEEP=1; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) FILE="$1"; shift ;;
  esac
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && [ "$TIMEOUT" -gt 0 ] || die "--timeout must be a positive integer"
[[ "$POLL_SEC" =~ ^[0-9]+$ ]] && [ "$POLL_SEC" -gt 0 ] || die "POLL_SEC must be a positive integer"

report() { # FILE
  local f="$1" r
  [ -r "$f" ] || die "cannot read $f"
  r="$(jq -sc '
    (map(select(.ev=="start"))[0]) as $s | (map(select(.ev=="result"))[-1]) as $r
    | (map(select(.ev=="poll"))) as $p
    | {id:$s.id, container:$s.container, verdict:($r.verdict // "INCOMPLETE"), timeout:$s.timeout, poll_sec:$s.poll_sec,
       db_bytes:$s.db_bytes, downtime_stop_to_start:$r.downtime_sec,
       phases:($r.phases // {}), observed:($p | map(.state) | reduce .[] as $x ([]; if .[-1]==$x then . else .+[$x] end)),
       polls:($p|length), peers_at_full:$r.peers_at_full, pre:$s.pre, post:$r.post,
       old_db:(map(select(.ev=="cleanup" or .ev=="rollback"))[-1] // null)}' "$f")" || die "not a pft-resync JSONL file: $f"
  if [ "$JSON" -eq 1 ]; then echo "$r"; return; fi
  jq -r '
    def s(x): if x==null then "never (timeout)" else "\(x) s" end;
    "pft-resync report - drill \(.id) on \(.container)",
    "verdict:               \(.verdict)",
    "DB size moved aside:   \(.db_bytes) bytes",
    "stop -> start:         \(.downtime_stop_to_start // "-") s (container down, DB swap)",
    "time to connected:     \(s(.phases.connected))",
    "time to syncing:       \(s(.phases.syncing))",
    "time to tracking:      \(s(.phases.tracking))",
    "time to full:          \(s(.phases.full))",
    "time to 1st validated: \(s(.phases.first_validated))",
    "time to caught up:     \(s(.phases.caught_up))  (validated seq above the pre-drill seq)",
    "states observed:       \(.observed | join(" -> "))  (\(.polls) polls, every \(.poll_sec) s, timeout \(.timeout) s)",
    "peers at full:         \(.peers_at_full // "-")",
    "pre-drill:             \(.pre.state), \(.pre.peers) peers, validated \(.pre.validated), complete \(.pre.complete)",
    "post-drill:            \(.post.state // "-"), \(.post.peers // "-") peers, validated \(.post.validated // "-"), complete \(.post.complete // "-")",
    "old DB:                \(if .old_db == null then "-" else (.old_db | del(.t) | tostring) end)"' <<<"$r"
}

case "$CMD" in
  report) [ -n "$FILE" ] || die "usage: pft-resync report FILE [--json]"; report "$FILE"; exit 0 ;;
  plan|drill) ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) die "unknown command '$CMD' (plan|drill|report)" ;;
esac

[ "$(id -u)" -eq 0 ] || [ -n "$TEST" ] || die "run as root (docker and the DB dir need it)"
command -v jq >/dev/null || die "jq is required"

DB="$(db_dir)"
INFO="$(server_info)"; PRE="$(snap "$INFO")"
GATE="$(maint_gate)"

if [ "$CMD" = plan ]; then
  echo "pft-resync plan - $(iso "$(now)") - container $CONTAINER (read-only, nothing is changed)"
  echo "container state:   $("$DOCKER" inspect -f '{{.State.Status}} (restart policy {{.HostConfig.RestartPolicy.Name}})' "$CONTAINER" 2>/dev/null || echo 'NOT FOUND')"
  if db_dir_ok "$DB"; then
    echo "DB path:           $DB (mounted at $DB_MOUNT)"
    echo "DB size:           $(bytes "$DB") bytes = disk freed when a PASSing drill deletes the old DB"
    echo "DB owner/mode:     $(stat -c '%U:%G %a' "$DB")"
    echo "free on DB fs:     $(df -B1 --output=avail "$(dirname "$DB")" | tail -1 | tr -d ' ') bytes"
    echo "aside path:        ${DB}.resync-aside-<id> (same parent dir -> rename, no copy)"
  else echo "DB path:           UNUSABLE ('$DB'): no absolute, non-symlink directory mounted at $DB_MOUNT"; fi
  jq -r '"server_state:      \(.state)", "peers:             \(.peers)", "validated ledger:  \(.validated)", "complete_ledgers:  \(.complete)"' <<<"$PRE"
  echo "pubkey_node:       $(jq -r '.pubkey_node // "-" | .[0:10]' <<<"$INFO")... (a cold resync also loses wallet.db, so the node identity changes)"
  echo "timeout/poll:      ${TIMEOUT}s / ${POLL_SEC}s"
  echo "maintenance gate:  $GATE"
  ready=1
  db_dir_ok "$DB" || ready=0
  [ "$(jq -r .rank <<<"$PRE")" -ge 4 ] || ready=0
  [ "${GATE%% *}" = ok ] || ready=0
  if [ "$ready" -eq 1 ]; then echo "drill would:       RUN (with --yes)"; else echo "drill would:       REFUSE"; fi
  exit 0
fi

# ---- drill ----
refuse() { echo "drill REFUSED: $1"; exit 4; }
[ "$YES" -eq 1 ] || refuse "--yes not given (this deletes the node's ledger DB; run 'plan' first)"
[ "${GATE%% *}" = ok ] || refuse "${GATE#refuse }"
db_dir_ok "$DB" || refuse "no usable DB dir mounted at $DB_MOUNT in $CONTAINER ('$DB')"
[ "$(jq -r .rank <<<"$PRE")" -ge 4 ] || refuse "node is $(jq -r .state <<<"$PRE"), not full: nothing to measure against"

ID="r$(now)-$$"
ASIDE="${DB}.resync-aside-$ID"
FRESH_FAILED="${DB}.resync-failed-$ID"
[ ! -e "$ASIDE" ] && [ ! -e "$FRESH_FAILED" ] || refuse "aside path already exists"
[ -n "$OUT" ] || { mkdir -p "$RUN_DIR" && OUT="$RUN_DIR/$ID.jsonl"; }
: > "$OUT" || die "cannot write $OUT"
ev() { local l; l="$(jq -nc --argjson t "$(now)" "$@")"; echo "$l" >> "$OUT"; echo "$l"; }

OWNER="$(stat -c '%u:%g' "$DB")"; MODE="$(stat -c '%a' "$DB")"; DBB="$(bytes "$DB")"
ev --arg id "$ID" --arg c "$CONTAINER" --arg db "$DB" --argjson b "${DBB:-0}" --argjson pre "$PRE" \
   --argjson to "$TIMEOUT" --argjson p "$POLL_SEC" --arg gate "$GATE" \
   '{ev:"start",t:$t,id:$id,container:$c,db:$db,db_bytes:$b,pre:$pre,timeout:$to,poll_sec:$p,maint:$gate}'

STAGE=pre
rollback() { # reason -> 0 ok, 1 failed
  local why="$1" rc=0 t0 s
  echo "rolling back ($why)"
  "$DOCKER" stop -t 60 "$CONTAINER" >/dev/null 2>&1
  if [ -d "$ASIDE" ]; then
    if [ -e "$DB" ]; then mv -T "$DB" "$FRESH_FAILED" || rc=1; fi
    [ "$rc" -eq 0 ] && { mv -T "$ASIDE" "$DB" || rc=1; }
    [ "$rc" -eq 0 ] && [ -d "$FRESH_FAILED" ] && rm -rf -- "$FRESH_FAILED"
  fi
  "$DOCKER" start "$CONTAINER" >/dev/null 2>&1 || rc=1
  t0="$(now)"; s='{"rank":-1}'
  while [ "$rc" -eq 0 ] && [ $(( $(now) - t0 )) -lt "$TIMEOUT" ]; do
    s="$(snap "$(server_info)")"; [ "$(jq -r .rank <<<"$s")" -ge 4 ] && break
    nap "$POLL_SEC"
  done
  [ "$(jq -r .rank <<<"$s")" -ge 4 ] || rc=1
  ev --arg why "$why" --argjson ok "$([ "$rc" -eq 0 ] && echo true || echo false)" --argjson s "$s" \
     --arg db "$DB" --argjson el $(( $(now) - t0 )) \
     '{ev:"rollback",t:$t,reason:$why,ok:$ok,old_db_restored_to:$db,secs_to_full_after_restore:$el,state:$s}'
  return "$rc"
}
on_signal() {
  trap '' INT TERM
  if [ "$STAGE" != pre ] && [ "$STAGE" != finished ]; then
    ev '{ev:"result",t:$t,verdict:"INTERRUPTED"}' >/dev/null
    if rollback "interrupted at stage $STAGE"; then exit 6; else exit 5; fi
  fi
  exit 6
}
trap on_signal INT TERM

"$DOCKER" stop -t 60 "$CONTAINER" >/dev/null || { ev '{ev:"error",t:$t,what:"docker stop failed"}'; exit 5; }
T_STOP="$(now)"; ev '{ev:"stopped",t:$t}' >/dev/null
STAGE=moving
mv -T "$DB" "$ASIDE" || { ev '{ev:"error",t:$t,what:"rename aside failed"}'; "$DOCKER" start "$CONTAINER"; exit 5; }
STAGE=moved
if ! { mkdir "$DB" && chown "$OWNER" "$DB" && chmod "$MODE" "$DB"; }; then rollback "could not create the empty DB dir"; exit 5; fi
ev --arg a "$ASIDE" '{ev:"moved",t:$t,aside:$a}' >/dev/null
"$DOCKER" start "$CONTAINER" >/dev/null || { rollback "docker start failed"; exit 5; }
T0="$(now)"; STAGE=started
ev --argjson d $(( T0 - T_STOP )) '{ev:"started",t:$t,downtime_sec:$d}'

PREV="$(jq -r .validated <<<"$PRE")"
PH='{}'; S='{}'
while :; do
  ASK="$(now)"
  S="$(snap "$(server_info)")"
  EL=$(( $(now) - T0 ))   # timed at the ANSWER: a slow RPC during startup must not make a phase look earlier
  ev --argjson el "$EL" --argjson s "$S" --argjson rpc $(( $(now) - ASK )) '{ev:"poll",t:$t,el:$el,rpc_s:$rpc} + $s'
  PH="$(jq -c --argjson el "$EL" --argjson s "$S" --argjson prev "$PREV" '
    . as $p
    | reduce (["connected",1],["syncing",2],["tracking",3],["full",4]) as $x ($p;
        if (.[$x[0]] == null) and ($s.rank >= $x[1]) then .[$x[0]] = $el else . end)
    | if .first_validated == null and $s.validated > 0 then .first_validated = $el else . end
    | if .caught_up == null and $s.validated > $prev then .caught_up = $el else . end' <<<"$PH")"
  if [ "$(jq -r '.full != null and .caught_up != null' <<<"$PH")" = true ] && [ "$(jq -r .rank <<<"$S")" -ge 4 ]; then
    break
  fi
  if [ "$EL" -ge "$TIMEOUT" ]; then
    ev --argjson ph "$PH" --argjson d $(( T0 - T_STOP )) '{ev:"result",t:$t,verdict:"TIMEOUT",phases:$ph,downtime_sec:$d}'
    STAGE=finished
    if rollback "not full + caught up after ${TIMEOUT}s"; then echo "drill TIMEOUT: rolled back to the old DB"; exit 1; fi
    echo "drill TIMEOUT and ROLLBACK FAILED - check $CONTAINER and $DB by hand (old DB: $ASIDE)"; exit 5
  fi
  nap "$POLL_SEC"
done
STAGE=finished
ev --argjson ph "$PH" --argjson d $(( T0 - T_STOP )) --argjson s "$S" \
   '{ev:"result",t:$t,verdict:"PASS",phases:$ph,downtime_sec:$d,peers_at_full:$s.peers,post:$s}'
if [ "$KEEP" -eq 1 ]; then
  ev --arg a "$ASIDE" '{ev:"cleanup",t:$t,old_db:"kept",path:$a}' >/dev/null
else
  rm -rf -- "$ASIDE"
  ev --argjson b "${DBB:-0}" --argjson gone "$([ -e "$ASIDE" ] && echo false || echo true)" \
     '{ev:"cleanup",t:$t,old_db:"deleted",deleted:$gone,freed_bytes:$b}' >/dev/null
fi
echo
report "$OUT"
exit 0
