#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cond && ok .. || bad ..` is safe here: ok() always returns 0
# Sandbox tests for pft-watchdog / pft-heartbeat: every state transition, ntfy dedupe/cooldown/pairing,
# a forged-HMAC negative control, replay/future/malformed messages and the public-RPC-down case.
# Runs unprivileged in a temp dir; ntfy goes to NTFY_OUTBOX (a file), never to a real topic.
# Messages are signed here with `openssl dgst -hmac` (an independent HMAC implementation) so the
# watchdog's bash HMAC is cross-checked; one case uses the real pft-heartbeat --print on the local node.
# Needs: jq, curl, openssl, the public RPC reachable, and (case 2) a local node RPC on 127.0.0.1:5005.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/pft-watchdog.sh" HB="$HERE/pft-heartbeat.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PFT_WATCHDOG_TEST=1 CONF_DIR="$T/conf" STATE_DIR="$T/state" SPOOL_DIR="$T/spool" NTFY_OUTBOX="$T/outbox"
export PUBLIC_RPC="${PUBLIC_RPC:-https://rpc.testnet.postfiat.org}"
mkdir -p "$CONF_DIR" "$SPOOL_DIR"; : > "$NTFY_OUTBOX"
openssl rand -hex 32 > "$CONF_DIR/hmac.key"; chmod 600 "$CONF_DIR/hmac.key"
openssl rand -hex 32 > "$T/wrong.key"; chmod 600 "$T/wrong.key"
pass=0 fail=0 LAST_TS=0
ok()  { pass=$((pass + 1)); echo "  PASS $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
next_ts() { local t; t="$(date -u +%s)"; [ "$t" -le "$LAST_TS" ] && t=$((LAST_TS + 1)); LAST_TS=$t; echo "$t"; }
pub_seq() { curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d '{"method":"server_info"}' "$PUBLIC_RPC" | jq -r '.result.info.validated_ledger.seq'; }
sign() { printf '%s' "$1" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "$2")" | awk '{print $NF}'; }
deliver() { # body [keyfile]
  printf '%s\n%s\n' "$1" "$(sign "$1" "${2:-$CONF_DIR/hmac.key}")" | "$WD" receive
}
body() { # ts ledger [state]
  jq -nc --argjson ts "$1" --argjson l "$2" --arg s "${3:-full}" \
    '{v:1,node:"validator",ts:$ts,server_state:$s,validated_ledger:$l,peers:10,build_version:"1.0.9"}'
}
fresh() { body "$(next_ts)" "$(pub_seq)"; }
wait_past_last() { while [ "$(date -u +%s)" -le $((LAST_TS + 4)) ]; do sleep 1; done; }
sends() { wc -l < "$NTFY_OUTBOX" | tr -d ' '; }
check() { # expect_state expect_sends [env...]; runs check --notify --json
  local want="$1" want_n="$2"; shift 2
  local out rc; out="$(env "$@" "$WD" check --notify --json 2>"$T/err")"; rc=$?
  echo "    $out (exit $rc)"; [ -s "$T/err" ] && sed 's/^/    stderr: /' "$T/err"
  [ "$(jq -r .state <<<"$out")" = "$want" ] && [ "$(sends)" = "$want_n" ] \
    && ok "state=$want ntfy_total=$want_n" || bad "want state=$want ntfy_total=$want_n, got $(jq -r .state <<<"$out") $(sends)"
}

echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "date: $(date -u +%FT%TZ)  public RPC validated ledger: $(pub_seq)"
echo "== 1 bash HMAC == openssl HMAC (RFC 4231 test case 2 + random)"
src="$(sed -n '/^hmac_sha256_hex()/,/^}/p' "$WD")"
r="$(bash -c "$src"$'\n''printf %s "what do ya want for nothing?" | hmac_sha256_hex 4a656665')"
[ "$r" = 5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843 ] && ok "RFC 4231 TC2" || bad "RFC 4231 TC2 got $r"
r="$(bash -c "$src"$'\n''printf %s "$1" | hmac_sha256_hex "$2"' _ 'hello' "$(cat "$CONF_DIR/hmac.key")")"
[ "$r" = "$(sign hello "$CONF_DIR/hmac.key")" ] && ok "random 32-byte key" || bad "random key mismatch"

echo "== 2 first run, no heartbeat yet -> OK (grace), no ntfy"
check OK 0
echo "== 3 real pft-heartbeat --print from the local node -> OK"
K="$CONF_DIR/hmac.key"
if HMAC_KEY_FILE="$K" CONF_DIR="$T/none" "$HB" --print > "$T/hb.msg"; then
  head -1 "$T/hb.msg" | sed 's/^/    heartbeat: /'
  LAST_TS="$(head -1 "$T/hb.msg" | jq .ts)"
  "$WD" receive < "$T/hb.msg"; check OK 0
else bad "pft-heartbeat --print failed (local node RPC?)"; fi
echo "== 4 openssl-signed fresh heartbeat -> OK"
deliver "$(fresh)"; check OK 0
echo "== 5 no heartbeat for > STALE_AFTER -> STALE + 1 ntfy"
sleep 4; check STALE 1 STALE_AFTER_SEC=3
echo "== 6 still stale -> STALE, deduped (no new ntfy)"
check STALE 1 STALE_AFTER_SEC=3
echo "== 7 fresh heartbeat -> RECOVERED + 1 ntfy, then OK with no ntfy"
deliver "$(fresh)"; check RECOVERED 2; check OK 2
echo "== 8 forged HMAC (wrong key) -> BADSIG + 1 ntfy; forged ledger not accepted as last_good"
forged="$(body "$(next_ts)" 1 full)"; deliver "$forged" "$T/wrong.key"; check BADSIG 3
[ "$(jq .last_good.validated_ledger "$STATE_DIR/state.json")" != 1 ] && ok "forged heartbeat ignored" || bad "forged heartbeat used"
echo "== 9 valid heartbeat -> RECOVERED + 1 ntfy"
deliver "$(fresh)"; check RECOVERED 4
echo "== 10 replayed valid message -> BADSIG(replay), within cooldown -> suppressed; its recovery not sent"
old="$(body $((LAST_TS - 100)) "$(pub_seq)")"; deliver "$old"; check BADSIG 4
deliver "$(fresh)"; check RECOVERED 4
echo "== 11 ts 120s in the future (> SKEW_TOL 30s) -> BADSIG(ts_future) [cooldown 0 for the rest]"
export COOLDOWN_SEC=0
deliver "$(body $(( $(date -u +%s) + 120 )) "$(pub_seq)")"; check BADSIG 5
deliver "$(fresh)"; check RECOVERED 6
echo "== 12 ts 20s in the future (inside SKEW_TOL) -> accepted, OK"
LAST_TS=$(( $(date -u +%s) + 20 )); deliver "$(body "$LAST_TS" "$(pub_seq)")"; check OK 6
echo "== 13 malformed and oversize messages -> BADSIG"
printf 'not json\n' | "$WD" receive; head -c 5000 /dev/zero | tr '\0' a | "$WD" receive; check BADSIG 7
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" "$(pub_seq)")"; check RECOVERED 8
echo "== 14 public RPC down (https_proxy=http://127.0.0.1:9) + heartbeat 300 ledgers behind -> lag unknown, NOT LAGGING"
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" $(( $(pub_seq) - 300 )))"
check OK 8 https_proxy=http://127.0.0.1:9
grep -q 'public RPC unreachable' <<<"$("$WD" status)$(env https_proxy=http://127.0.0.1:9 "$WD" check --json)" && ok "detail says public RPC unreachable" || bad "no unreachable note"
echo "== 15 same lagging heartbeat with the RPC back -> LAGGING + 1 ntfy (priority default)"
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" $(( $(pub_seq) - 300 )))"; check LAGGING 9
[ "$(tail -1 "$NTFY_OUTBOX" | jq -r .priority)" = default ] && ok "LAGGING priority default" || bad "LAGGING priority"
echo "== 16 LAGGING -> BADSIG (state change between incidents) -> RECOVERED"
deliver "$(body $((LAST_TS + 1)) 5)" "$T/wrong.key"; check BADSIG 10
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" "$(pub_seq)")"; check RECOVERED 11
echo "== 17 heartbeat reporting server_state rpc_down (no validated ledger) -> LAGGING"
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" 0 rpc_down)"; check LAGGING 12
grep -q 'no validated ledger (server_state rpc_down)' <<<"$(tail -1 "$NTFY_OUTBOX")" && ok "rpc_down detail" || bad "rpc_down detail"
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" "$(pub_seq)")"; check RECOVERED 13
echo "== 18 cooldown: STALE again within COOLDOWN_SEC=3600 -> suppressed, RECOVERED not sent"
jq '.last_sent.STALE = (now|floor)' "$STATE_DIR/state.json" > "$T/s" && cp "$T/s" "$STATE_DIR/state.json"
wait_past_last; COOLDOWN_SEC=3600 check STALE 13 STALE_AFTER_SEC=3
grep -q 'suppressed (cooldown' "$T/err" && ! grep -q 'error' "$T/err" && ok "suppressed by cooldown, no shell error" || bad "cooldown path: $(cat "$T/err")"
LAST_TS=$(( $(date -u +%s) + 25 )); deliver "$(body "$LAST_TS" "$(pub_seq)")"; check RECOVERED 13
echo "== 19 key file group-readable -> refuses to run (exit 3)"
chmod 640 "$CONF_DIR/hmac.key"; "$WD" check >/dev/null 2>&1; rc=$?; chmod 600 "$CONF_DIR/hmac.key"
[ "$rc" = 3 ] && ok "exit 3 on 0640 key" || bad "exit $rc on 0640 key"
echo "== 20 exit codes: OK 0 / LAGGING 1 / BADSIG 2"
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" "$(pub_seq)")"; "$WD" check >/dev/null 2>&1; a=$?
LAST_TS=$((LAST_TS + 1)); deliver "$(body "$LAST_TS" $(( $(pub_seq) - 300 )))"; "$WD" check >/dev/null 2>&1; b=$?
deliver "$(body $((LAST_TS + 1)) 5)" "$T/wrong.key"; "$WD" check >/dev/null 2>&1; c=$?
[ "$a$b$c" = 012 ] && ok "exit codes 0/1/2" || bad "exit codes $a/$b/$c"

echo "== ntfy outbox (what would have been sent)"
sed 's/^/    /' "$NTFY_OUTBOX"
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
