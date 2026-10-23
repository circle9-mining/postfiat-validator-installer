#!/usr/bin/env bash
# Check a drill's topic-A capture (ntfy poll JSON): exactly 3 messages - [MAINT] start, [MAINT] end and one
# pft-watchdog STALE - and no STALE/LAGGING message timestamped before the window expiry.
# The end message comes from the 60s tick, so it can arrive after the first post-expiry alert; compare
# against the expiry, not the end message.   Usage: check-drill-json.sh capture.json EXPIRY_EPOCH
set -uo pipefail
J="${1:?capture json}"; EXP="${2:?expiry epoch}"
msgs="$(jq -c 'select(.event=="message") | {time, title}' "$J")"
n="$(grep -c . <<<"$msgs")"
start="$(jq -r 'select(.title|startswith("[MAINT] start")) | .time' <<<"$msgs" | grep -c .)"
end="$(jq -r 'select(.title|startswith("[MAINT] end")) | .time' <<<"$msgs" | grep -c .)"
post="$(jq -r --argjson e "$EXP" 'select(.title=="pft-watchdog STALE" and .time >= $e) | .time' <<<"$msgs" | grep -c .)"
early="$(jq -r --argjson e "$EXP" 'select((.title|test("STALE|LAGGING")) and .time < $e) | "\(.time) \(.title)"' <<<"$msgs")"
jq -r --argjson e "$EXP" '"  \(.time|todate) (expiry\(if .time >= $e then "+" else "" end)\(.time - $e)s) \(.title)"' <<<"$msgs"
echo "messages $n | [MAINT] start $start | [MAINT] end $end | post-expiry STALE $post | STALE/LAGGING before expiry: ${early:-none}"
if [ "$n" -eq 3 ] && [ "$start" -eq 1 ] && [ "$end" -eq 1 ] && [ "$post" -eq 1 ] && [ -z "$early" ]; then
  echo "PASS"; exit 0
fi
echo "FAIL"; exit 1
