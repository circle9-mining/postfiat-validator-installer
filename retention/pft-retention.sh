#!/usr/bin/env bash
# pft-retention: measure Post Fiat ledger-store growth and manage [node_db] online_delete.
#
# Modes (read-only unless noted):
#   sample          append one sample (sizes, complete_ledgers, free space) to SAMPLES
#   measure         report config, sizes, growth over the sampled window, days-to-full and a
#                   recommended online_delete. Exit 0 OK / 1 WARN (<30 days, or <6h of
#                   samples) / 2 FAIL (<7 days). --json for machine output.   [default]
#   watch-rotation  wait until the node finishes an online_delete rotation (complete_ledgers
#                   lower bound advances) and print the SHAMapStore log lines + before/after
#                   disk usage. --raise-log sets the SHAMapStore log partition to debug first
#                   (runtime only, reset by the next restart).
#   apply           WRITES: back up postfiatd.cfg (0600), set online_delete (and optionally
#                   advisory_delete) in [node_db], validate, restart the container once, wait
#                   for server_state full. No-op if the values are already set. Rolls back by
#                   itself if the node does not reach full within --timeout.
#   rollback        WRITES: restore the latest (or --from FILE) backup, restart, wait for full.
#   can-delete      pass-through to the can_delete admin RPC (advisory_delete=1 only).
#
# Usage: sudo ./pft-retention.sh [sample|measure|watch-rotation|apply|rollback|can-delete] [options]
#   measure:        [--json] [--window HOURS (24)] [--target-days N (7)] [--budget-pct P (50)]
#   watch-rotation: [--raise-log] [--max-wait SECONDS (3600)]
#   apply:          --online-delete N [--advisory-delete 0|1] [--timeout SECONDS (900)]
#   rollback:       [--from FILE] [--timeout SECONDS (900)]
#   can-delete:     [SEQ|now|always|never]
# Env: CONTAINER (postfiatd) CFG (/etc/postfiatd/postfiatd.cfg, inside the container)
#      RPC (http://127.0.0.1:5005/, inside the container) LOG_FILE (/opt/postfiatd/logs/debug.log)
#      STATE_DIR (/var/lib/pft-retention) BACKUP_DIR (/var/backups/pft-retention) DOCKER (docker)

set -euo pipefail

CONTAINER="${CONTAINER:-postfiatd}"
CFG="${CFG:-/etc/postfiatd/postfiatd.cfg}"
RPC="${RPC:-http://127.0.0.1:5005/}"
LOG_FILE="${LOG_FILE:-/opt/postfiatd/logs/debug.log}"
STATE_DIR="${STATE_DIR:-/var/lib/pft-retention}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pft-retention}"
SAMPLES="${SAMPLES:-$STATE_DIR/samples.csv}"
read -r -a DOCKER <<<"${DOCKER:-docker}"
MIN_ONLINE_DELETE=256
SAMPLE_HEADER="epoch,utc,server_state,validated_seq,complete_lo,complete_hi,nudb_bytes,sqlite_bytes,fs_avail_bytes,fs_size_bytes,nudb_dirs"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }
usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

dx() { "${DOCKER[@]}" exec "$CONTAINER" "$@"; }
dxi() { "${DOCKER[@]}" exec -i "$CONTAINER" "$@"; }

rpc() { # $1 = method, $2 = params object (optional)
  local body
  body=$(jq -cn --arg m "$1" --argjson p "${2:-{\}}" '{method:$m,params:[$p]}')
  dx curl -s --max-time 10 -H 'Content-Type: application/json' -d "$body" "$RPC"
}

server_info() { rpc server_info | jq -c '.result.info // {}'; }

# [section] key=value reader for a postfiatd.cfg on stdin; prints the value or nothing.
cfg_key() { # $1 = section, $2 = key
  awk -v sec="$1" -v key="$2" '
    /^[[:space:]]*#/ { next }
    /^\[/ { insec = (tolower($0) ~ "^\\[" tolower(sec) "\\][[:space:]]*$"); next }
    insec {
      line = $0; sub(/[[:space:]]+$/, "", line)
      split(line, kv, "=")
      k = kv[1]; gsub(/[[:space:]]/, "", k)
      if (tolower(k) == tolower(key)) { v = substr(line, index(line, "=") + 1); gsub(/^[[:space:]]+/, "", v); print v; exit }
    }'
}
# First non-comment line of a single-value section (e.g. [database_path], [ledger_history]).
cfg_section_value() { # $1 = section
  awk -v sec="$1" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^\[/ { insec = (tolower($0) ~ "^\\[" tolower(sec) "\\][[:space:]]*$"); next }
    insec { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }'
}

read_cfg() { dx cat "$CFG"; }

preflight() {
  for c in jq awk sha256sum; do command -v "$c" >/dev/null || die "$c required."; done
  "${DOCKER[@]}" inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found (DOCKER='${DOCKER[*]}')."
  dx sh -c 'command -v curl >/dev/null' || die "curl missing inside container '$CONTAINER'."
}

os_line() { log "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"; }

# ---------- sample ----------
take_sample() { # prints one CSV row
  local cfg info nudb_path db_path complete lo hi state seq nudb sqlite fs avail size dirs
  cfg="$(read_cfg)"
  nudb_path="$(cfg_key node_db path <<<"$cfg")"
  db_path="$(cfg_section_value database_path <<<"$cfg")"
  if [ -z "$nudb_path" ] || [ -z "$db_path" ]; then die "could not read [node_db] path / [database_path] from $CFG."; fi
  info="$(server_info)"
  state="$(jq -r '.server_state // "unknown"' <<<"$info")"
  seq="$(jq -r '.validated_ledger.seq // 0' <<<"$info")"
  complete="$(jq -r '.complete_ledgers // "empty"' <<<"$info")"
  if [[ "$complete" =~ ^[0-9] ]]; then
    lo="${complete%%[-,]*}"; hi="${complete##*[-,]}"
  else
    lo=0; hi=0
  fi
  nudb="$(dx du -sb "$nudb_path" | awk '{print $1}')"
  # SQLite stores incl. -wal/-shm; peerfinder/wallet are tiny but are part of the footprint.
  # shellcheck disable=SC2016  # $1 expands inside the container shell
  sqlite="$(dx sh -c 'du -cb "$1"/*.db "$1"/*.db-* "$1"/*.sqlite 2>/dev/null | tail -n1' sh "$db_path" | awk '{print $1}')"
  fs="$(dx df -B1 -P "$db_path" | awk 'NR==2 {print $4, $2}')"
  avail="${fs% *}"; size="${fs#* }"
  # shellcheck disable=SC2016
  dirs="$(dx sh -c 'ls -1 "$1" 2>/dev/null' sh "$nudb_path" | paste -sd+ -)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%s)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$state" "$seq" "$lo" "$hi" "$nudb" "${sqlite:-0}" "$avail" "$size" "${dirs:-none}"
}

cmd_sample() {
  preflight
  mkdir -p "$STATE_DIR"
  [ -s "$SAMPLES" ] || echo "$SAMPLE_HEADER" >"$SAMPLES"
  local row; row="$(take_sample)"
  echo "$row" >>"$SAMPLES"
  echo "$row"
}

# ---------- measure ----------
cmd_measure() {
  local json=0 window=24 target_days=7 budget=50
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;;
      --window) window="${2:?}"; shift ;;
      --target-days) target_days="${2:?}"; shift ;;
      --budget-pct) budget="${2:?}"; shift ;;
      *) die "measure: unknown option $1" ;;
    esac
    shift
  done
  [[ "$window" =~ ^[0-9]+$ && "$target_days" =~ ^[0-9]+$ && "$budget" =~ ^[0-9]+$ ]] || die "numeric options only."
  preflight
  local cfg od ad lh now cur since stats
  cfg="$(read_cfg)"
  od="$(cfg_key node_db online_delete <<<"$cfg")"
  ad="$(cfg_key node_db advisory_delete <<<"$cfg")"
  lh="$(cfg_section_value ledger_history <<<"$cfg")"
  cur="$(take_sample)"
  now="${cur%%,*}"
  since=$((now - window * 3600))
  # Least-squares slope of total DB bytes and of validated_seq over the window, plus the
  # bytes/ledger currently held (nudb bytes / complete_ledgers span).
  stats="$( { [ -s "$SAMPLES" ] && tail -n +2 "$SAMPLES"; echo "$cur"; } | awk -F, -v since="$since" '
    $1 >= since && $4 > 0 {
      n++; t = $1; y = $7 + $8; s = $4
      if (n == 1) { t0 = t; first_lo = $5 }
      x = t - t0; sx += x; sy += y; sxx += x*x; sxy += x*y; ss += s; sxs += x*s
      last_lo = $5; span = x
      if (y > maxy) maxy = y
      if (miny == "" || y < miny) miny = y
      if ($6 > $5) { bpl_sum += $7 / ($6 - $5 + 1); bpl_n++ }
    }
    END {
      d = n * sxx - sx * sx
      slope = (n > 1 && d > 0) ? (n * sxy - sx * sy) / d : 0
      lslope = (n > 1 && d > 0) ? (n * sxs - sx * ss) / d : 0
      printf "%d %.0f %.6f %.6f %.1f %s %s %s %s\n", n, span, slope * 86400, lslope, \
        (bpl_n ? bpl_sum / bpl_n : 0), (first_lo == "" ? 0 : first_lo), (last_lo == "" ? 0 : last_lo), \
        (miny == "" ? 0 : miny), (maxy == "" ? 0 : maxy)
    }')"
  local n span growth_day lps bpl first_lo last_lo miny maxy
  read -r n span growth_day lps bpl first_lo last_lo miny maxy <<<"$stats"
  local state seq lo hi nudb sqlite avail size dirs
  IFS=, read -r _ _ state seq lo hi nudb sqlite avail size dirs <<<"$cur"

  local verdict=OK code=0 reasons=() days_to_full="null"
  local interval="null" rec="null" target_ledgers="null" budget_ledgers="null" steady="null"
  # Project only from >= 6h of samples: rotation makes the store a sawtooth, short spans mislead.
  if [ "$span" -ge 21600 ] && awk -v g="$growth_day" 'BEGIN{exit !(g > 0)}'; then
    days_to_full="$(awk -v a="$avail" -v g="$growth_day" 'BEGIN{printf "%.1f", a / g}')"
  fi
  if awk -v l="$lps" 'BEGIN{exit !(l > 0)}'; then
    interval="$(awk -v l="$lps" 'BEGIN{printf "%.3f", 1 / l}')"
    target_ledgers="$(awk -v d="$target_days" -v i="$interval" 'BEGIN{printf "%d", d * 86400 / i}')"
  fi
  if awk -v b="$bpl" 'BEGIN{exit !(b > 0)}'; then
    # nudb holds up to two backends (writable + archive) = up to 2 x online_delete ledgers.
    budget_ledgers="$(awk -v a="$avail" -v db="$((nudb + sqlite))" -v p="$budget" -v b="$bpl" \
      'BEGIN{printf "%d", (a + db) * p / 100 / (2 * b)}')"
    [[ "$od" =~ ^[0-9]+$ ]] && steady="$(awk -v o="$od" -v b="$bpl" -v s="$sqlite" 'BEGIN{printf "%.0f", 2 * o * b + s}')"
  fi
  if [ "$target_ledgers" != null ] && [ "$budget_ledgers" != null ]; then
    rec=$(( target_ledgers < budget_ledgers ? target_ledgers : budget_ledgers ))
    [ "$rec" -lt "$MIN_ONLINE_DELETE" ] && rec=$MIN_ONLINE_DELETE
  fi

  if [ "$days_to_full" != null ]; then
    if awk -v d="$days_to_full" 'BEGIN{exit !(d < 7)}'; then verdict=FAIL; code=2; reasons+=("disk full in ${days_to_full} days (<7)")
    elif awk -v d="$days_to_full" 'BEGIN{exit !(d < 30)}'; then verdict=WARN; code=1; reasons+=("disk full in ${days_to_full} days (<30)"); fi
  fi
  if [ "$span" -lt 21600 ]; then
    [ "$code" -lt 1 ] && { verdict=WARN; code=1; }
    reasons+=("only $((span / 60)) min of samples in window (need >= 360 for a growth rate)")
  fi
  if [ -z "$od" ]; then reasons+=("online_delete not set: full history is kept, store grows without bound"); fi
  if [ "$state" != full ]; then [ "$code" -lt 1 ] && { verdict=WARN; code=1; }; reasons+=("server_state=$state"); fi

  if [ "$json" -eq 1 ]; then
    jq -n --arg verdict "$verdict" --argjson code "$code" --arg state "$state" \
      --arg od "$od" --arg ad "$ad" --arg lh "$lh" --argjson seq "$seq" --argjson lo "$lo" --argjson hi "$hi" \
      --argjson nudb "$nudb" --argjson sqlite "$sqlite" --argjson avail "$avail" --argjson size "$size" \
      --arg dirs "$dirs" --argjson n "$n" --argjson span "$span" --argjson growth "$growth_day" \
      --argjson dtf "$days_to_full" --argjson interval "$interval" --argjson bpl "$bpl" \
      --argjson rec "$rec" --argjson tl "$target_ledgers" --argjson bl "$budget_ledgers" --argjson steady "$steady" \
      --argjson td "$target_days" --argjson bp "$budget" --argjson flo "$first_lo" --argjson llo "$last_lo" \
      --argjson miny "$miny" --argjson maxy "$maxy" \
      --arg reasons "$(printf '%s\n' "${reasons[@]+"${reasons[@]}"}")" '{
        verdict: $verdict, exit_code: $code, server_state: $state,
        config: {online_delete: ($od | if . == "" then null else tonumber end),
                 advisory_delete: ($ad | if . == "" then null else tonumber end),
                 ledger_history: (if $lh == "" then null else $lh end)},
        ledgers: {validated: $seq, complete_lo: $lo, complete_hi: $hi, held: (if $hi > 0 then $hi - $lo + 1 else 0 end),
                  lower_bound_first_sample: $flo, lower_bound_now: $llo, seconds_per_ledger: $interval},
        disk: {nudb_bytes: $nudb, sqlite_bytes: $sqlite, fs_avail_bytes: $avail, fs_size_bytes: $size,
               nudb_backends: ($dirs | split("+")), db_bytes_min_in_window: $miny, db_bytes_max_in_window: $maxy},
        growth: {samples: $n, span_seconds: $span, bytes_per_day: $growth, days_to_full: $dtf,
                 nudb_bytes_per_ledger: $bpl, steady_state_bytes_at_current_online_delete: $steady},
        recommendation: {online_delete: $rec, target_days: $td, ledgers_for_target_days: $tl,
                         budget_pct_of_free_plus_db: $bp, ledgers_fitting_budget: $bl},
        reasons: ($reasons | split("\n") | map(select(. != "")))}'
  else
    printf 'pft-retention measure  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  config        [node_db] online_delete=%s advisory_delete=%s  [ledger_history]=%s\n' "${od:-unset}" "${ad:-unset}" "${lh:-unset}"
    printf '  node          server_state=%s validated=%s complete_ledgers=%s-%s (%s held)\n' "$state" "$seq" "$lo" "$hi" "$((hi > 0 ? hi - lo + 1 : 0))"
    printf '  disk          nudb=%s B sqlite=%s B fs_avail=%s B of %s B  backends=%s\n' "$nudb" "$sqlite" "$avail" "$size" "$dirs"
    printf '  window        %s samples over %s min (window %sh); db bytes min=%s max=%s; lower bound %s -> %s\n' \
      "$n" "$((span / 60))" "$window" "$miny" "$maxy" "$first_lo" "$last_lo"
    printf '  growth        %s B/day (least squares, nudb+sqlite)  days_to_full=%s\n' "$growth_day" "$days_to_full"
    printf '  sizing        %s s/ledger, ~%s nudb B/ledger, steady state at current online_delete ~%s B\n' "$interval" "$bpl" "$steady"
    printf '  recommend     online_delete=%s (min of %s ledgers for %s days and %s ledgers fitting %s%% of free+db; floor %s)\n' \
      "$rec" "$target_ledgers" "$target_days" "$budget_ledgers" "$budget" "$MIN_ONLINE_DELETE"
    local r; for r in "${reasons[@]+"${reasons[@]}"}"; do printf '  note          %s\n' "$r"; done
    printf 'RESULT: %s\n' "$verdict"
  fi
  return "$code"
}

# ---------- watch-rotation ----------
cmd_watch_rotation() {
  local raise=0 max_wait=3600
  while [ $# -gt 0 ]; do
    case "$1" in
      --raise-log) raise=1 ;;
      --max-wait) max_wait="${2:?}"; shift ;;
      *) die "watch-rotation: unknown option $1" ;;
    esac
    shift
  done
  preflight
  [ -r "$LOG_FILE" ] || die "cannot read $LOG_FILE (set LOG_FILE)."
  if [ "$raise" -eq 1 ]; then
    rpc log_level '{"partition":"SHAMapStore","severity":"debug"}' | jq -c '.result.status' >&2
  fi
  log "log_level SHAMapStore=$(rpc log_level | jq -r '.result.levels.SHAMapStore // "?"')"
  local start_line before after b_lo deadline
  start_line=$(($(wc -l <"$LOG_FILE") + 1))
  before="$(take_sample)"; b_lo="$(cut -d, -f5 <<<"$before")"
  log "before: $before"
  deadline=$(( $(date +%s) + max_wait ))
  while :; do
    after="$(take_sample)"
    if [ "$(cut -d, -f5 <<<"$after")" -gt "$b_lo" ] && [ "$(cut -d, -f11 <<<"$after")" != "$(cut -d, -f11 <<<"$before")" ]; then
      break
    fi
    [ "$(date +%s)" -ge "$deadline" ] && { log "no rotation within ${max_wait}s"; log "after:  $after"; return 1; }
    sleep 15
  done
  sleep 5; after="$(take_sample)"
  log "after:  $after"
  log "SHAMapStore log lines since watch start:"
  local lines
  lines="$(tail -n +"$start_line" "$LOG_FILE" | grep -E 'SHAMapStore:(DBG|NFO|WRN|ERR|FTL)' || true)"
  if [ -n "$lines" ]; then echo "$lines"; else log "(none: SHAMapStore partition below debug? use --raise-log)"; fi
  grep -oE 'finished rotation [0-9]+' <<<"$lines" | sed 's/^/LOG: /' || log "LOG: no 'finished rotation' line captured"
  awk -F, -v b="$before" -v a="$after" 'BEGIN {
      split(b, x, ","); split(a, y, ",")
      printf "ROTATION: complete_lo %s -> %s (+%d)  nudb %s -> %s B  sqlite %s -> %s B  backends %s -> %s\n",
        x[5], y[5], y[5] - x[5], x[7], y[7], x[8], y[8], x[11], y[11] }'
}

# ---------- apply / rollback ----------
edit_node_db() { # stdin = cfg; $1 online_delete, $2 advisory_delete or ""
  awk -v od="$1" -v ad="$2" '
    function flush() { if (insec && !done) { if (!sod) print "online_delete=" od; if (ad != "" && !sad) print "advisory_delete=" ad; done = 1 } }
    /^\[/ { flush(); insec = (tolower($0) ~ /^\[node_db\][[:space:]]*$/); print; next }
    insec && /^[[:space:]]*online_delete[[:space:]]*=/ { print "online_delete=" od; sod = 1; next }
    insec && ad != "" && /^[[:space:]]*advisory_delete[[:space:]]*=/ { print "advisory_delete=" ad; sad = 1; next }
    { print }
    END { flush() }'
}

validate_cfg() { # $1 old file, $2 new file, $3 online_delete, $4 advisory_delete or ""
  local n lh changed
  n=$(grep -ciE '^\[node_db\][[:space:]]*$' "$2" || true)
  [ "$n" -eq 1 ] || die "validate: expected exactly one [node_db] section, found $n."
  [ "$(cfg_key node_db online_delete <"$2")" = "$3" ] || die "validate: online_delete not set to $3."
  [ -z "$4" ] || [ "$(cfg_key node_db advisory_delete <"$2")" = "$4" ] || die "validate: advisory_delete not set to $4."
  [ -n "$(cfg_key node_db path <"$2")" ] || die "validate: [node_db] path missing."
  lh="$(cfg_section_value ledger_history <"$2")"
  if [[ "$lh" =~ ^[0-9]+$ ]] && [ "$lh" -gt "$3" ]; then
    die "validate: [ledger_history] $lh > online_delete $3 (postfiatd refuses to start)."
  fi
  # Only online_delete/advisory_delete lines may differ.
  changed="$(diff "$1" "$2" | grep -E '^[<>]' | grep -vE '^[<>] *(online_delete|advisory_delete) *=' || true)"
  [ -z "$changed" ] || die "validate: unexpected changes outside online_delete/advisory_delete."
  log "validate: OK ([node_db] single section, online_delete=$3${4:+, advisory_delete=$4}, ledger_history=${lh:-unset}, only node_db keys changed)"
}

node_db_view() { sed -n '/^\[node_db\]/,/^\[/p' "$1" | sed '$ { /^\[/d }'; }

install_cfg() { # $1 = host file to install as $CFG
  local mode
  mode="$(dx stat -c %a "$CFG")"
  # shellcheck disable=SC2016  # $1/$2 expand inside the container shell
  dxi sh -c 'cat > "$1.pft-retention.new" && chmod "$2" "$1.pft-retention.new" && mv -f "$1.pft-retention.new" "$1"' sh "$CFG" "$mode" <"$1"
  [ "$(read_cfg | sha256sum | cut -d' ' -f1)" = "$(sha256sum <"$1" | cut -d' ' -f1)" ] || die "installed config does not match (sha256)."
  log "installed $CFG in $CONTAINER (mode $mode, sha256 $(sha256sum <"$1" | cut -c1-16)...)"
}

wait_full() { # $1 timeout seconds
  local deadline st last=""
  deadline=$(( $(date +%s) + $1 ))
  while :; do
    st="$(server_info 2>/dev/null | jq -r '.server_state // "starting"' 2>/dev/null || echo starting)"
    [ -n "$st" ] || st=starting
    [ "$st" != "$last" ] && { log "server_state=$st"; last="$st"; }
    [ "$st" = full ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 10
  done
}

restart_and_wait() { # $1 timeout
  log "restarting container $CONTAINER (once)"
  "${DOCKER[@]}" restart "$CONTAINER" >/dev/null
  wait_full "$1"
}

backup_cfg() { # $1 = source file; prints backup path
  local ts dst
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  ( umask 077; mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    dst="$BACKUP_DIR/postfiatd.cfg.$ts"; cp "$1" "$dst"; chmod 600 "$dst"; echo "$dst" >"$BACKUP_DIR/LATEST" )
  echo "$BACKUP_DIR/postfiatd.cfg.$ts"
}

cmd_apply() {
  local od="" ad="" timeout=900
  while [ $# -gt 0 ]; do
    case "$1" in
      --online-delete) od="${2:?}"; shift ;;
      --advisory-delete) ad="${2:?}"; shift ;;
      --timeout) timeout="${2:?}"; shift ;;
      *) die "apply: unknown option $1" ;;
    esac
    shift
  done
  if ! [[ "$od" =~ ^[0-9]+$ ]] || [ "$od" -lt "$MIN_ONLINE_DELETE" ]; then die "--online-delete must be an integer >= $MIN_ONLINE_DELETE."; fi
  [ -z "$ad" ] || [[ "$ad" =~ ^[01]$ ]] || die "--advisory-delete must be 0 or 1."
  [ "$(id -u)" -eq 0 ] || die "apply writes the node config: run as root (sudo)."
  preflight
  local work old new bak
  work="$(mktemp -d)"; trap 'rm -rf "$work"' RETURN
  old="$work/old.cfg"; new="$work/new.cfg"
  read_cfg >"$old"
  edit_node_db "$od" "$ad" <"$old" >"$new"
  if cmp -s "$old" "$new"; then
    log "no change: [node_db] already has online_delete=$od${ad:+ advisory_delete=$ad}; nothing to do (no restart)."
    node_db_view "$old"
    return 0
  fi
  validate_cfg "$old" "$new" "$od" "$ad"
  log "before -> after ([node_db] lines only):"
  diff <(node_db_view "$old") <(node_db_view "$new") || true
  bak="$(backup_cfg "$old")"
  log "backup: $bak ($(stat -c %a "$bak"), sha256 $(sha256sum <"$bak" | cut -c1-16)...)"
  install_cfg "$new"
  if restart_and_wait "$timeout"; then
    log "apply OK: server_state full with online_delete=$od${ad:+ advisory_delete=$ad}"
  else
    log "node not full within ${timeout}s: rolling back to $bak"
    install_cfg "$bak"
    restart_and_wait "$timeout" || die "rollback restart also did not reach full; check the node."
    die "apply failed and was rolled back."
  fi
}

cmd_rollback() {
  local from="" timeout=900
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:?}"; shift ;;
      --timeout) timeout="${2:?}"; shift ;;
      *) die "rollback: unknown option $1" ;;
    esac
    shift
  done
  [ "$(id -u)" -eq 0 ] || die "rollback writes the node config: run as root (sudo)."
  preflight
  [ -n "$from" ] || from="$(cat "$BACKUP_DIR/LATEST" 2>/dev/null || true)"
  [ -s "$from" ] || die "no backup to roll back to (looked for ${from:-$BACKUP_DIR/LATEST})."
  local work cur
  work="$(mktemp -d)"; trap 'rm -rf "$work"' RETURN
  cur="$work/cur.cfg"; read_cfg >"$cur"
  if cmp -s "$cur" "$from"; then
    log "no change: running config already equals $from (no restart)."
    return 0
  fi
  log "rollback to $from; current -> restored ([node_db] lines only):"
  diff <(node_db_view "$cur") <(node_db_view "$from") || true
  local pre; pre="$BACKUP_DIR/postfiatd.cfg.pre-rollback.$(date -u +%Y%m%dT%H%M%SZ)"
  ( umask 077; mkdir -p "$BACKUP_DIR"; cp "$cur" "$pre" )
  log "pre-rollback copy: $pre ($(stat -c %a "$pre"))"
  install_cfg "$from"
  restart_and_wait "$timeout" || die "node not full within ${timeout}s after rollback."
  log "rollback OK: server_state full"
}

cmd_can_delete() {
  preflight
  if [ $# -gt 0 ]; then rpc can_delete "$(jq -cn --arg v "$1" '{can_delete: $v}')"
  else rpc can_delete; fi | jq '.result'
}

MODE="${1:-measure}"
[ $# -gt 0 ] && shift
case "$MODE" in
  sample) cmd_sample ;;
  measure) os_line; cmd_measure "$@" ;;
  watch-rotation) os_line; cmd_watch_rotation "$@" ;;
  apply) os_line; cmd_apply "$@" ;;
  rollback) os_line; cmd_rollback "$@" ;;
  can-delete) cmd_can_delete "$@" ;;
  -h|--help|help) usage 0 ;;
  *) log "unknown mode: $MODE"; usage 2 ;;
esac
