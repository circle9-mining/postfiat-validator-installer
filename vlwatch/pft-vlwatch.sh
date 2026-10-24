#!/usr/bin/env bash
# pft-vlwatch - read-only validator-list (UNL) health check for a postfiatd node.
#
# Queries validator_list_sites, validators and server_info on the node's local admin RPC
# (through `docker exec <container> curl`, the admin port is bound inside the container) and checks:
#   rpc               all three methods answered with status=success
#   sites             at least one validator-list site is configured
#   site_status:<uri> last_refresh_status is accepted|same_sequence (FAIL otherwise, WARN if never refreshed)
#   site_fresh:<uri>  last_refresh_time within REFRESH_MULT x refresh_interval (WARN), 2x that (FAIL)
#   site_cover:<pub>  every publisher list is fetched from a configured site (WARN if not)
#   available:<pub>   publisher list available=true
#   expiry:<pub>      days to expiration >= WARN_DAYS (PASS), >= CRIT_DAYS (WARN), else FAIL; expired = FAIL
#   seq:<pub>         sequence never decreases vs the saved state file (rollback = FAIL)
#   list_status       validator_list.status is active
#   trusted_keys      trusted key count == sum of list lengths (WARN if fewer, FAIL if 0 or < quorum)
#   amendment_blocked server_info.amendment_blocked absent/false
#
# Usage: sudo pft-vlwatch [--container NAME] [--json] [--notify] [--state FILE] [--no-state-update]
#                         [--warn-days N] [--crit-days N] [--refresh-mult N] [--fixtures DIR] [--now EPOCH]
#   --fixtures DIR  read validator_list_sites.json, validators.json, server_info.json from DIR (offline tests)
#   --notify        change-only ntfy: send when the overall verdict or the set of non-PASS checks changes
#                   (incl. recovery). Target from $CONF_DIR/ntfy.env (root 0600: NTFY_SERVER, NTFY_TOPIC,
#                   optional NTFY_TOKEN). NTFY_OUTBOX=FILE appends messages to FILE instead (tests).
# Exit: 0 all PASS, 1 any WARN, 2 any FAIL (incl. RPC unreachable). 3 = usage error.
set -euo pipefail

CONTAINER=postfiatd
RPC_URL=http://127.0.0.1:5005
JSON=false
NOTIFY=false
FIXTURES=""
NOW=""
STATE=/var/lib/pft-vlwatch/state.json
UPDATE_STATE=true
WARN_DAYS=30
CRIT_DAYS=7
REFRESH_MULT=3
CONF_DIR="${PFT_VLWATCH_CONF:-/etc/pft-vlwatch}"

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 3; }
while [ $# -gt 0 ]; do
  case "$1" in
    --container) CONTAINER="$2"; shift ;;
    --url) RPC_URL="$2"; shift ;;
    --json) JSON=true ;;
    --notify) NOTIFY=true ;;
    --fixtures) FIXTURES="$2"; shift ;;
    --now) NOW="$2"; shift ;;
    --state) STATE="$2"; shift ;;
    --no-state-update) UPDATE_STATE=false ;;
    --warn-days) WARN_DAYS="$2"; shift ;;
    --crit-days) CRIT_DAYS="$2"; shift ;;
    --refresh-mult) REFRESH_MULT="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
  shift
done
for n in "$WARN_DAYS" "$CRIT_DAYS" "$REFRESH_MULT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "thresholds must be non-negative integers" >&2; exit 3; }
done
[ -z "$NOW" ] || [[ "$NOW" =~ ^[0-9]+$ ]] || { echo "--now must be a unix epoch" >&2; exit 3; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 3; }
[ -n "$NOW" ] || NOW="$(date -u +%s)"

rpc() { # method -> JSON on stdout ("" on failure)
  if [ -n "$FIXTURES" ]; then
    cat "$FIXTURES/$1.json" 2>/dev/null || true
  else
    docker exec "$CONTAINER" curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
      -d "{\"method\":\"$1\",\"params\":[{}]}" "$RPC_URL" 2>/dev/null || true
  fi
}
as_json() { if [ -n "$1" ] && jq -e . >/dev/null 2>&1 <<<"$1"; then printf '%s' "$1"; else printf 'null'; fi; }

sites="$(as_json "$(rpc validator_list_sites)")"
vals="$(as_json "$(rpc validators)")"
info="$(as_json "$(rpc server_info)")"
prev='{}'
[ -f "$STATE" ] && prev="$(as_json "$(cat "$STATE")")"
[ "$prev" = null ] && prev='{}'

# All verdicts are computed in one jq program; bash only formats, saves state and notifies.
# shellcheck disable=SC2016  # $vars below are jq variables
checks="$(jq -nc --argjson s "$sites" --argjson v "$vals" --argjson i "$info" --argjson prev "$prev" \
  --argjson now "$NOW" --argjson wd "$WARN_DAYS" --argjson cd "$CRIT_DAYS" --argjson rm "$REFRESH_MULT" '
  def ts: sub("\\.[0-9]+"; "") | sub(" UTC$"; "") | strptime("%Y-%b-%d %H:%M:%S") | mktime;
  def ok($x): ($x | type) == "object" and $x.result.status == "success";
  def c($n; $verdict; $d): {name: $n, verdict: $verdict, detail: $d};
  def short: if length > 16 then .[0:16] else . end;
  if (ok($s) and ok($v) and ok($i)) | not then
    [c("rpc"; "FAIL"; "no valid answer from: " + ([["validator_list_sites", $s], ["validators", $v], ["server_info", $i]]
        | map(select(ok(.[1]) | not) | .[0]) | join(", ")))]
  else
    ($s.result.validator_sites // []) as $sites
    | ($v.result.publisher_lists // []) as $pls
    | ($v.result.trusted_validator_keys // [] | length) as $tk
    | ($pls | map(select(.available == true) | .list // [] | length) | add // 0) as $listlen
    | ($v.result.validation_quorum // 0) as $q
    | [c("rpc"; "PASS"; "validator_list_sites, validators, server_info answered")]
    + (if ($sites | length) == 0 then [c("sites"; "FAIL"; "no validator list sites configured (no UNL source)")]
       else [c("sites"; "PASS"; "\($sites | length) site(s) configured")] end)
    + [$sites[] | . as $x
        | (if ($x.last_refresh_status // null) == null then
             c("site_status:\($x.uri)"; "WARN"; "never refreshed")
           elif ($x.last_refresh_status | IN("accepted", "same_sequence")) then
             c("site_status:\($x.uri)"; "PASS"; $x.last_refresh_status)
           else
             c("site_status:\($x.uri)"; "FAIL"; $x.last_refresh_status
               + (if $x.last_refresh_message then ": " + $x.last_refresh_message else "" end))
           end),
          (($x.refresh_interval_min // 5) * 60) as $ivl
        | (if ($x.last_refresh_time // null) == null then
             c("site_fresh:\($x.uri)"; "WARN"; "no last_refresh_time")
           else
             ($now - ($x.last_refresh_time | ts)) as $age
             | (if $age <= $rm * $ivl then "PASS" elif $age <= 2 * $rm * $ivl then "WARN" else "FAIL" end) as $vd
             | c("site_fresh:\($x.uri)"; $vd; "last refresh \($age)s ago (interval \($ivl)s, warn > \($rm * $ivl)s, fail > \(2 * $rm * $ivl)s)")
           end)]
    + [$pls[] | . as $p | ($p.pubkey_publisher | short) as $k
        | (if ($sites | map(.uri) | index($p.uri)) != null then
             c("site_cover:\($k)"; "PASS"; "fetched from \($p.uri)")
           else
             c("site_cover:\($k)"; "WARN"; "list uri \($p.uri // "none") is not a configured site")
           end),
          (if $p.available == true then c("available:\($k)"; "PASS"; "available=true")
           else c("available:\($k)"; "FAIL"; "available=\($p.available)") end),
          (if ($p.expiration // null) == null then c("expiry:\($k)"; "FAIL"; "no expiration reported")
           else
             (($p.expiration | ts) - $now) as $secs
             # whole days, rounded toward zero on both sides (floor of a negative would add a day)
             | (($secs | fabs) / 86400 | floor) as $days
             | (if $secs < 0 then "FAIL" elif $days < $cd then "FAIL" elif $days < $wd then "WARN" else "PASS" end) as $vd
             | c("expiry:\($k)"; $vd; (if $secs < 0 then "EXPIRED \($days) day(s) ago" else "\($days) day(s) left" end)
                 + " (\($p.expiration); warn < \($wd)d, fail < \($cd)d)")
           end),
          ($prev.seq[$p.pubkey_publisher] // null) as $old
        | (if ($p.seq // null) == null then c("seq:\($k)"; "WARN"; "no sequence reported")
           elif $old == null then c("seq:\($k)"; "PASS"; "seq \($p.seq) (no saved state, baseline recorded)")
           elif $p.seq < $old then c("seq:\($k)"; "FAIL"; "seq ROLLBACK \($old) -> \($p.seq)")
           else c("seq:\($k)"; "PASS"; "seq \($p.seq) (saved \($old))") end)]
    + [($v.result.validator_list.status // "missing") as $st
        | if $st == "active" then c("list_status"; "PASS"; "active, expires \($v.result.validator_list.expiration)")
          else c("list_status"; "FAIL"; "validator_list.status=\($st)") end]
    + [if $tk == 0 then c("trusted_keys"; "FAIL"; "0 trusted keys (list length \($listlen), quorum \($q))")
       elif $tk < $q then c("trusted_keys"; "FAIL"; "\($tk) trusted < quorum \($q)")
       elif $tk < $listlen then c("trusted_keys"; "WARN"; "\($tk) trusted < list length \($listlen) (quorum \($q))")
       else c("trusted_keys"; "PASS"; "\($tk) trusted = list length \($listlen) (quorum \($q))") end]
    + [if ($i.result.info.amendment_blocked // false) == true
       then c("amendment_blocked"; "FAIL"; "server is amendment blocked - upgrade postfiatd")
       else c("amendment_blocked"; "PASS"; "not amendment blocked") end]
  end')"

nfail="$(jq '[.[] | select(.verdict == "FAIL")] | length' <<<"$checks")"
nwarn="$(jq '[.[] | select(.verdict == "WARN")] | length' <<<"$checks")"
npass="$(jq '[.[] | select(.verdict == "PASS")] | length' <<<"$checks")"
if [ "$nfail" -gt 0 ]; then overall=FAIL; rc=2; elif [ "$nwarn" -gt 0 ]; then overall=WARN; rc=1; else overall=PASS; rc=0; fi
host_label="${NODE_LABEL:-$CONTAINER}"

# Save seq high-water marks (never lowered, so a rollback keeps failing until the list recovers).
if [ "$UPDATE_STATE" = true ] && [ "$vals" != null ]; then
  mkdir -p "$(dirname "$STATE")"
  jq -n --argjson prev "$prev" --argjson v "$vals" --argjson now "$NOW" '
    $prev + {updated: $now, seq: (($prev.seq // {}) as $o | reduce ($v.result.publisher_lists // [])[] as $p ($o;
      if ($p.seq // null) == null then . else .[$p.pubkey_publisher] = ([.[$p.pubkey_publisher] // 0, $p.seq] | max) end))}
  ' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
fi

send_ntfy() { # title, body, priority
  if [ -n "${NTFY_OUTBOX:-}" ]; then
    jq -nc --arg t "$1" --arg m "$2" --arg p "$3" '{title:$t, message:$m, priority:$p}' >> "$NTFY_OUTBOX"; return 0
  fi
  local env_file="$CONF_DIR/ntfy.env" k v NTFY_SERVER=https://ntfy.sh NTFY_TOPIC="" NTFY_TOKEN=""
  { [ -f "$env_file" ] && [ "$(stat -c %U -- "$env_file")" = root ] && [[ "$(stat -c %a -- "$env_file")" =~ ^[0-7]00$ ]]; } \
    || { echo "ntfy: $env_file missing or not 0600 root - not sent" >&2; return 1; }
  while IFS='=' read -r k v; do
    case "$k" in NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN) printf -v "$k" '%s' "${v//\"/}" ;; esac
  done < <(grep -E '^(NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN)=' "$env_file")
  [ -n "$NTFY_TOPIC" ] || { echo "ntfy: no NTFY_TOPIC - not sent" >&2; return 1; }
  # URL and token go to curl via a config on an fd, never argv or env
  curl -s --max-time 15 -o /dev/null -w '%{http_code}' -K <(
    printf 'url = "%s/%s"\n' "$NTFY_SERVER" "$NTFY_TOPIC"
    printf 'header = "Title: %s"\nheader = "Priority: %s"\nheader = "Tags: pft-vlwatch"\n' "$1" "$3"
    [ -n "$NTFY_TOKEN" ] && printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"
  ) --data-binary "$2" | grep -q '^2' || { echo "ntfy: send failed" >&2; return 1; }
}

notified=false
if [ "$NOTIFY" = true ]; then
  sig="$overall $(jq -r '[.[] | select(.verdict != "PASS") | .name + "=" + .verdict] | sort | join(",")' <<<"$checks")"
  last="$(jq -r '.notify_sig // empty' "$STATE" 2>/dev/null || true)"
  if [ "$sig" != "$last" ] && { [ -n "$last" ] || [ "$overall" != PASS ]; }; then
    body="$(jq -r '.[] | select(.verdict != "PASS") | "\(.verdict) \(.name): \(.detail)"' <<<"$checks")"
    [ -n "$body" ] || body="all $npass checks PASS"
    case "$overall" in FAIL) prio=high ;; WARN) prio=default ;; *) prio=low ;; esac
    title="pft-vlwatch $overall - $host_label"
    [ "$overall" = PASS ] && title="pft-vlwatch RECOVERED - $host_label"
    send_ntfy "$title" "$body" "$prio" && notified=true
  fi
  # record the signature only once delivered (or on the silent first PASS), so a failed send retries
  if [ "$notified" = true ] || [ "$sig" = "$last" ] || { [ -z "$last" ] && [ "$overall" = PASS ]; }; then
    mkdir -p "$(dirname "$STATE")"
    st='{}'; [ -f "$STATE" ] && st="$(as_json "$(cat "$STATE")")"; [ "$st" = null ] && st='{}'
    jq -n --argjson st "$st" --arg sig "$sig" '$st + {notify_sig: $sig}' > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  fi
fi

if [ "$JSON" = true ]; then
  jq -n --argjson c "$checks" --arg o "$overall" --argjson rc "$rc" --argjson now "$NOW" --arg h "$host_label" \
    --argjson n "$notified" '{tool: "pft-vlwatch", node: $h, time: ($now | todate), overall: $o, exit: $rc,
      pass: ([$c[] | select(.verdict == "PASS")] | length), warn: ([$c[] | select(.verdict == "WARN")] | length),
      fail: ([$c[] | select(.verdict == "FAIL")] | length), notified: $n, checks: $c}'
else
  echo "pft-vlwatch - $(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ) - node: $host_label"
  jq -r '.[] | "  [\(.verdict)] \(.name) - \(.detail)"' <<<"$checks"
  echo "RESULT: $overall - $npass pass, $nwarn warn, $nfail fail -> exit $rc"
  [ "$notified" = true ] && echo "ntfy: change notification sent"
fi
exit "$rc"
