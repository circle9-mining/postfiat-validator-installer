#!/usr/bin/env bash
# "cond && ok || bad" is intended: ok() always returns 0, so bad runs only when cond fails.
# shellcheck disable=SC2015
# Offline test suite for pft-vlwatch.sh - no node, no network, no ntfy (NTFY_OUTBOX captures messages).
# Positive control: fixtures/recorded-validator/ (real RPC answers recorded from the validator host, server_info
# trimmed to the fields the check reads). Every failure case is that recording plus ONE jq mutation (shown in
# each case below), so the case changes exactly the field under test.
# Usage: bash vlwatch/tests/run-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLW="$HERE/../pft-vlwatch.sh"
REC="$HERE/fixtures/recorded-validator"
NOW="$(cat "$REC/NOW")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

# mk NAME FILE JQ_FILTER [FILE JQ_FILTER ...] -> fixture dir = recording with the given mutations
mk() {
  local d="$WORK/$1"; shift
  mkdir -p "$d"; cp "$REC"/*.json "$d/"
  while [ $# -gt 0 ]; do
    jq "$2" "$REC/$1.json" > "$d/$1.json"; shift 2
  done
  echo "$d"
}
# run DIR [extra args] -> sets OUT (json) and RC; uses a per-case state file unless --state given
run() {
  local d="$1"; shift
  OUT="$(bash "$VLW" --fixtures "$d" --now "$NOW" --json --state "$d/state.json" "$@" 2>"$d/stderr")"; RC=$?
}
verdict() { jq -r --arg n "$1" '[.checks[] | select(.name | startswith($n)) | .verdict] | join(",")' <<<"$OUT"; }
# expect DESC RC CHECK_PREFIX VERDICT
expect() {
  local got; got="$(verdict "$3")"
  if [ "$RC" = "$2" ] && [ "$got" = "$4" ]; then ok "$1 (exit $RC, $3=$got)"; return 0; fi
  bad "$1: expected exit $2 $3=$4, got exit $RC $3=$got"; return 1
}

echo "pft-vlwatch offline tests - $(date -u +%Y-%m-%dT%H:%M:%SZ) - $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
echo "script sha256: $(sha256sum "$VLW" | cut -c1-64)"

# --- harness self-check (negative control for expect itself) ---
d="$(mk selfcheck)"; run "$d"
if expect "self-check: wrong expectation must be reported" 2 amendment_blocked FAIL >/dev/null; then
  bad "harness self-check: expect() accepted a wrong expectation"
else
  fail=$((fail - 1)); ok "harness self-check: expect() rejects a wrong expectation"
fi

# --- positive control ---
d="$(mk healthy)"; run "$d"
expect "recorded healthy validator" 0 rpc PASS
n_nonpass="$(jq '[.checks[] | select(.verdict != "PASS")] | length' <<<"$OUT")"
[ "$n_nonpass" = 0 ] && [ "$(jq -r .overall <<<"$OUT")" = PASS ] && [ "$(jq '.checks | length' <<<"$OUT")" = 11 ] \
  && ok "healthy: 11 checks, all PASS, overall PASS" || bad "healthy: expected 11 PASS checks, got $(jq -c '[.checks[].verdict]' <<<"$OUT")"
[ "$(jq -r '.seq | to_entries[0].value' "$d/state.json")" = 26 ] && ok "healthy: state file records seq 26" || bad "healthy: state seq"
# plain-text mode gives the same exit code and a RESULT line
txt="$(bash "$VLW" --fixtures "$d" --now "$NOW" --state "$d/state.json")"; trc=$?
[ "$trc" = 0 ] && grep -q '^RESULT: PASS - 11 pass, 0 warn, 0 fail -> exit 0$' <<<"$txt" && ok "healthy: text mode RESULT line" || bad "healthy text mode"

# --- expiry ---
d="$(mk expired validators '.result.publisher_lists[0].expiration = "2026-Oct-01 00:00:00.000000000 UTC" | .result.validator_list.status = "expired"')"
run "$d"; expect "expired publisher list" 2 expiry FAIL && expect "expired: list_status" 2 list_status FAIL
grep -q EXPIRED <<<"$(jq -r '.checks[] | select(.name | startswith("expiry")) | .detail' <<<"$OUT")" && ok "expired: detail says EXPIRED" || bad "expired detail"
# expired 2 days + 1 s / + 23 h before NOW must both read "2 day(s) ago" (regression: floor() of a negative said 3)
for off in 172801 255600; do
  d="$(mk "expired-$off" validators ".result.publisher_lists[0].expiration = \"$(date -u -d "@$((NOW - off))" '+%Y-%b-%d %H:%M:%S').000000000 UTC\"")"
  run "$d"; det="$(jq -r '.checks[] | select(.name | startswith("expiry")) | .detail' <<<"$OUT")"
  [ "$RC" = 2 ] && [[ "$det" == "EXPIRED 2 day(s) ago"* ]] && ok "expired $off s ago reads 2 day(s) ago" || bad "expired $off s: $det"
done
d="$(mk expires-in-1s validators ".result.publisher_lists[0].expiration = \"$(date -u -d "@$((NOW + 1))" '+%Y-%b-%d %H:%M:%S').000000000 UTC\"")"
run "$d"; expect "expires in 1 s (0 days left, not yet expired)" 2 expiry FAIL
[[ "$(jq -r '.checks[] | select(.name | startswith("expiry")) | .detail' <<<"$OUT")" == "0 day(s) left"* ]] && ok "expires in 1 s reads 0 day(s) left" || bad "expires-in-1s detail"
d="$(mk expiry-warn validators '.result.publisher_lists[0].expiration = "2026-Nov-13 18:00:00.000000000 UTC"')"
run "$d"; expect "list expires in 20 days (warn < 30)" 1 expiry WARN
d="$(mk expiry-crit validators '.result.publisher_lists[0].expiration = "2026-Oct-27 18:00:00.000000000 UTC"')"
run "$d"; expect "list expires in 3 days (fail < 7)" 2 expiry FAIL
run "$d" --warn-days 2 --crit-days 1; expect "thresholds are configurable (3 days, warn<2 crit<1)" 0 expiry PASS

# --- site refresh status / freshness ---
d="$(mk refresh-error validator_list_sites '.result.validator_sites[0].last_refresh_status = "invalid" | .result.validator_sites[0].last_refresh_message = "invalid signature"')"
run "$d"; expect "refresh error (invalid)" 2 site_status FAIL
d="$(mk never-refreshed validator_list_sites '.result.validator_sites[0] |= del(.last_refresh_status, .last_refresh_time)')"
run "$d"; expect "site never refreshed" 1 site_status WARN && expect "never refreshed: freshness" 1 site_fresh WARN
d="$(mk stale-warn validator_list_sites '.result.validator_sites[0].last_refresh_time = "2026-Oct-24 16:50:00.000000000 UTC"')"
run "$d"; expect "last refresh ~20 min ago (warn > 15 min)" 1 site_fresh WARN
d="$(mk stale-fail validator_list_sites '.result.validator_sites[0].last_refresh_time = "2026-Oct-24 15:00:00.000000000 UTC"')"
run "$d"; expect "last refresh ~2 h ago (fail > 30 min)" 2 site_fresh FAIL

# --- missing site ---
d="$(mk missing-site validator_list_sites '.result.validator_sites = []')"
run "$d"; expect "no validator list site" 2 sites FAIL && expect "missing site: list not covered" 2 site_cover WARN

# --- sequence vs saved state ---
d="$(mk seq-rollback)"; echo '{"seq":{"ED3F1E0DA736FCF99BE2880A60DBD470715C0E04DD793FB862236B070571FC09E2":27}}' > "$d/state.json"
run "$d"; expect "seq rollback 27 -> 26" 2 seq FAIL
[ "$(jq -r '.seq[]' "$d/state.json")" = 27 ] && ok "rollback: saved high-water mark stays 27" || bad "rollback lowered the state"
run "$d"; expect "rollback keeps failing on the next run" 2 seq FAIL
d="$(mk seq-advance)"; echo '{"seq":{"ED3F1E0DA736FCF99BE2880A60DBD470715C0E04DD793FB862236B070571FC09E2":25}}' > "$d/state.json"
run "$d"; expect "seq advanced 25 -> 26" 0 seq PASS
[ "$(jq -r '.seq[]' "$d/state.json")" = 26 ] && ok "advance: state updated to 26" || bad "advance state"
d="$(mk seq-nostate)"; echo '{"seq":{"ED3F1E0DA736FCF99BE2880A60DBD470715C0E04DD793FB862236B070571FC09E2":27}}' > "$d/state.json"
run "$d" --no-state-update; expect "--no-state-update still compares" 2 seq FAIL

# --- availability / trusted keys / amendment_blocked ---
d="$(mk unavailable validators '.result.publisher_lists[0].available = false')"
run "$d"; expect "publisher list unavailable" 2 available FAIL
d="$(mk trusted-short validators '.result.trusted_validator_keys |= .[3:]')"
run "$d"; expect "22 trusted keys vs list length 25" 1 trusted_keys WARN
d="$(mk trusted-below-quorum validators '.result.trusted_validator_keys |= .[0:10]')"
run "$d"; expect "10 trusted keys < quorum 17" 2 trusted_keys FAIL
d="$(mk trusted-zero validators '.result.trusted_validator_keys = []')"
run "$d"; expect "0 trusted keys" 2 trusted_keys FAIL
d="$(mk amendment-blocked server_info '.result.info.amendment_blocked = true')"
run "$d"; expect "amendment_blocked=true" 2 amendment_blocked FAIL

# --- RPC failures ---
d="$(mk rpc-missing)"; rm "$d/validators.json"
run "$d"; expect "validators RPC missing" 2 rpc FAIL
grep -q validators <<<"$(jq -r '.checks[0].detail' <<<"$OUT")" && ok "rpc-missing: names the failed method" || bad "rpc-missing detail"
d="$(mk rpc-garbage)"; echo 'Forbidden' > "$d/validator_list_sites.json"
run "$d"; expect "non-JSON answer (Forbidden)" 2 rpc FAIL
d="$(mk rpc-error server_info '.result.status = "error"')"
run "$d"; expect "status=error" 2 rpc FAIL

# --- change-only notifications (NTFY_OUTBOX, never a real topic) ---
export NTFY_OUTBOX="$WORK/outbox.jsonl"; : > "$NTFY_OUTBOX"
st="$WORK/notify-state.json"
nrun() { OUT="$(bash "$VLW" --fixtures "$1" --now "$NOW" --json --notify --state "$st" 2>/dev/null)"; RC=$?; }
msgs() { wc -l < "$NTFY_OUTBOX" | tr -d ' '; }
nrun "$WORK/healthy";       [ "$(msgs)" = 0 ] && ok "notify: first PASS run is silent" || bad "notify: first PASS sent"
nrun "$WORK/expired";       [ "$(msgs)" = 1 ] && [ "$(jq -r .title "$NTFY_OUTBOX")" = "pft-vlwatch FAIL - postfiatd" ] \
                              && ok "notify: PASS -> FAIL sends 1 (high)" || bad "notify: FAIL not sent"
[ "$(jq -r .priority "$NTFY_OUTBOX")" = high ] || bad "notify: FAIL priority"
nrun "$WORK/expired";       [ "$(msgs)" = 1 ] && ok "notify: unchanged FAIL is silent" || bad "notify: duplicate FAIL"
nrun "$WORK/expiry-warn";   [ "$(msgs)" = 2 ] && [ "$(tail -1 "$NTFY_OUTBOX" | jq -r .priority)" = default ] \
                              && ok "notify: FAIL -> WARN sends 1 (default)" || bad "notify: WARN change"
nrun "$WORK/stale-warn";    [ "$(msgs)" = 3 ] && ok "notify: different WARN check set sends 1" || bad "notify: WARN set change"
nrun "$WORK/healthy";       [ "$(msgs)" = 4 ] && [ "$(tail -1 "$NTFY_OUTBOX" | jq -r .title)" = "pft-vlwatch RECOVERED - postfiatd" ] \
                              && ok "notify: back to PASS sends RECOVERED" || bad "notify: recovery"
nrun "$WORK/healthy";       [ "$(msgs)" = 4 ] && ok "notify: steady PASS is silent" || bad "notify: PASS repeat"
rm -f "$st"; nrun "$WORK/missing-site"; [ "$(msgs)" = 5 ] && ok "notify: first run already failing sends 1" || bad "notify: first FAIL"
unset NTFY_OUTBOX
# no outbox + missing env file -> nothing sent, signature NOT recorded (retried next run)
rm -f "$st"; OUT="$(PFT_VLWATCH_CONF="$WORK/noconf" bash "$VLW" --fixtures "$WORK/expired" --now "$NOW" --json --notify --state "$st" 2>"$WORK/err")"; RC=$?
grep -q 'missing or not 0600 root - not sent' "$WORK/err" && [ "$(jq -r '.notify_sig // "none"' "$st")" = none ] \
  && [ "$(jq -r .notified <<<"$OUT")" = false ] && ok "notify: missing env file -> not sent, retried next run" || bad "notify: env guard"

# --- usage ---
bash "$VLW" --warn-days x >/dev/null 2>&1; [ $? = 3 ] && ok "bad threshold -> exit 3" || bad "usage exit"
bash "$VLW" --bogus >/dev/null 2>&1; [ $? = 3 ] && ok "unknown argument -> exit 3" || bad "unknown arg exit"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
