#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cond && ok .. || bad ..` is safe here: ok() always returns 0
# Fake-clock unit tests for pft-maint and the three alerters that honour it (pft-watchdog, postfiat-monitor,
# pft-integrity). Runs in a temp dir: the clock is a file (PFT_MAINT_NOW_FILE), ntfy goes to NTFY_OUTBOX files,
# the node RPC and `docker restart` are stubs. Nothing on the host is changed.
# The pft-integrity cases need root (it reads docker/iptables) and use a throwaway STATE_DIR; they are
# skipped without passwordless sudo.  Needs: jq, openssl, flock.
# Usage: ./test-maint.sh 2>&1 | tee test.log
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PM="$HERE/pft-maint.sh" WD="$HERE/../watchdog/pft-watchdog.sh" MON="$HERE/../monitor/postfiat-monitor.sh"
INTEG="$HERE/../integrity/pft-integrity.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"; [ -n "${IT:-}" ] && sudo rm -rf "$IT"' EXIT
export PFT_MAINT_TEST=1 PFT_MAINT_BIN="$PM" MAINT_DIR="$T/maint" CONF_DIR="$T/maint-conf" WD_CONF_DIR="$T/none"
export PFT_MAINT_NOW_FILE="$T/clock" NTFY_OUTBOX="$T/outbox" POLL_SEC=5
date -u +%s > "$PFT_MAINT_NOW_FILE"; : > "$NTFY_OUTBOX"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  PASS $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
clock() { cat "$PFT_MAINT_NOW_FILE"; }
advance() { echo $(( $(clock) + $1 )) > "$PFT_MAINT_NOW_FILE"; echo "  (fake clock +$1s -> $(date -u -d "@$(clock)" +%FT%TZ))"; }
sends() { wc -l < "$NTFY_OUTBOX" | tr -d ' '; }
last_title() { tail -1 "$NTFY_OUTBOX" | jq -r .title; }
run() { echo "  \$ pft-maint $*"; "$PM" "$@" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}"; }
active_rc() { "$PM" active; echo $?; }

# --- watchdog sandbox (sentry side): own spool/state, signed with openssl as an independent HMAC ---
WDC="$T/wd-conf"; mkdir -p "$WDC" "$T/wd-spool"
openssl rand -hex 32 > "$WDC/hmac.key"; openssl rand -hex 32 > "$T/wrong.key"; chmod 600 "$WDC/hmac.key" "$T/wrong.key"
wd() { CONF_DIR="$WDC" STATE_DIR="$T/wd-state" SPOOL_DIR="$T/wd-spool" PFT_WATCHDOG_TEST=1 PUBLIC_RPC=http://127.0.0.1:9 "$WD" "$@"; }
sign() { printf '%s' "$1" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(cat "${2:-$WDC/hmac.key}")" | awk '{print $NF}'; }
wd_deliver() { printf '%s\n%s\n' "$1" "$(sign "$1" "${2:-}")" | wd receive; }
# a heartbeat 600s old -> STALE (no public RPC needed: STALE is decided on age alone)
old_hb() { jq -nc --argjson ts $(( $(date -u +%s) - 600 )) '{v:1,node:"validator",ts:$ts,server_state:"full",validated_ledger:1,peers:10,build_version:"t"}'; }
wd_check() { # prints the json line, returns exit code
  local out rc; out="$(wd check --notify --json 2>"$T/wd.err")"; rc=$?
  echo "    $out (exit $rc)"; [ -s "$T/wd.err" ] && sed 's/^/    stderr: /' "$T/wd.err"
  printf '%s' "$out" > "$T/wd.last"; return $rc
}
wd_reset() { rm -rf "$T/wd-state"; wd status >/dev/null; jq '.first_run = 0' "$T/wd-state/state.json" > "$T/x" && mv "$T/x" "$T/wd-state/state.json"; }

# --- monitor sandbox: failing health command ---
printf '#!/bin/sh\necho "  [FAIL] RPC not responding on localhost:5005"\nexit 1\n' > "$T/health-bad"; chmod +x "$T/health-bad"
mon() { POSTFIAT_MONITOR_ENV=/dev/null STATE_DIR="$T/mon-state" LOG_FILE="$T/mon.log" HEALTH_CMD="$T/health-bad" "$MON" | sed 's/^/    /'; }

# --- node RPC + restart stubs for restart-node ---
N="$T/node"; mkdir -p "$N"
node_set() { echo "$1" > "$N/state"; echo "$2" > "$N/peers"; echo "$3" > "$N/seq"; echo "$4" > "$N/sentry"; echo "${5:-0}" > "$N/countdown"; }
cat > "$T/rpc-stub" <<'EOF'
#!/usr/bin/env bash
N="$(dirname "$0")/node"
case "$1" in
  server_info)
    c="$(cat "$N/countdown")"
    if [ "$c" -gt 0 ]; then echo $((c - 1)) > "$N/countdown"; [ "$c" -eq 1 ] && echo full > "$N/state"; fi
    [ "$(cat "$N/state")" = full ] && echo $(( $(cat "$N/seq") + 3 )) > "$N/seq"
    jq -nc --arg s "$(cat "$N/state")" --argjson p "$(cat "$N/peers")" --argjson q "$(cat "$N/seq")" \
      '{info:{server_state:$s, peers:$p, validated_ledger:{seq:$q}}}' ;;
  peers)
    if [ "$(cat "$N/sentry")" = 1 ]; then echo '{"peers":[{"address":"192.0.2.10:2559"},{"address":"198.51.100.7:2559"}]}'
    else echo '{"peers":[{"address":"198.51.100.7:2559"}]}'; fi ;;
esac
EOF
chmod +x "$T/rpc-stub"
# restart stub: node goes to "connected"; it becomes full after $(cat restart-countdown) server_info polls (0 = never)
# shellcheck disable=SC2016  # the stub expands $D itself
printf '#!/bin/sh\nD="%s"\necho restart >> "$D/restarts"\necho connected > "$D/node/state"\ncp "$D/restart-countdown" "$D/node/countdown"\n' "$T" > "$T/restart-stub"
chmod +x "$T/restart-stub"
mkdir -p "$CONF_DIR"; printf 'NODE_LABEL=validator\nSENTRY_ADDR=192.0.2.10\n' > "$CONF_DIR/maint.conf"   # documentation address (RFC 5737)
export PFT_MAINT_RPC_CMD="$T/rpc-stub" RESTART_CMD="$T/restart-stub"

echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "date: $(date -u +%FT%TZ)  fake clock starts at real time; ntfy -> outbox files, RPC/restart -> stubs"
echo "scripts: $(cd "$HERE/.." && sha256sum maint/pft-maint.sh watchdog/pft-watchdog.sh monitor/postfiat-monitor.sh integrity/pft-integrity.sh | awk '{print substr($1,1,12)"  "$2}' | paste -sd ' ')"

echo "== 1 start: flag format, exactly one [MAINT] start message"
[ "$(active_rc)" = 1 ] && ok "no flag -> active exit 1" || bad "no flag should be inactive"
run start --ttl 30m --reason "unit test window" && ok "start exit 0" || bad "start failed"
f="$MAINT_DIR/flag.json"
[ "$(stat -c %a "$f")" = 644 ] && ok "flag mode 0644" || bad "flag mode $(stat -c %a "$f")"
jq -e '.v==1 and .reason=="unit test window" and (.expiry-.start)==1800 and .origin=="local" and (.host|length>0) and (.id|length>0)' "$f" >/dev/null \
  && ok "flag JSON {v,id,reason,start,expiry,host,origin}: $(jq -c . "$f")" || bad "flag JSON wrong: $(cat "$f")"
[ "$(sends)" = 1 ] && [ "$(last_title)" = "[MAINT] start $(jq -r .host "$f")" ] && ok "one ntfy: $(tail -1 "$NTFY_OUTBOX")" || bad "start ntfy count $(sends)"
[ "$(active_rc)" = 0 ] && ok "active exit 0" || bad "active should be 0"
run start --ttl 10m --reason "second" ; rc=$?
[ "$rc" = 4 ] && [ "$(sends)" = 1 ] && ok "second start refused (exit 4), no message" || bad "second start rc=$rc sends=$(sends)"
run start --ttl 5h --reason x >/dev/null; [ $? = 3 ] && ok "ttl over MAX_TTL_SEC (4h) rejected" || bad "5h ttl accepted"

echo "== 2 suppress: watchdog STALE, monitor UNHEALTHY inside the window"
wd_reset; wd_deliver "$(old_hb)"
wd_check; jq -e '.state=="STALE" and .notified==null and .maint==true' "$T/wd.last" >/dev/null && [ "$(sends)" = 1 ] \
  && ok "watchdog STALE suppressed, no ntfy" || bad "watchdog not suppressed"
wd_check; [ "$(sends)" = 1 ] && ok "watchdog repeat run: still silent" || bad "watchdog repeat sent"
mon; [ "$(sends)" = 1 ] && grep -q 'MAINT: alert suppressed' "$T/mon.log" && [ "$(cat "$T/mon-state/state" 2>/dev/null || echo ok)" = ok ] \
  && ok "monitor UNHEALTHY suppressed, stored state left ok" || bad "monitor not suppressed (sends $(sends))"
run status
"$PM" status --json | jq -e '.window=="active" and .suppressed=="watchdog=1 monitor=1 integrity=0"' >/dev/null \
  && ok "status --json counts watchdog=1 monitor=1" || bad "counts wrong: $("$PM" status --json)"
echo "  BADSIG is never suppressed:"
wd_deliver "$(old_hb)" "$T/wrong.key"
wd_check; [ "$(last_title)" = "pft-watchdog BADSIG" ] && [ "$(sends)" = 2 ] && ok "BADSIG sent during the window" || bad "BADSIG suppressed"
wd_check >/dev/null   # back to STALE (suppressed again: state changed BADSIG -> STALE inside the window)
[ "$(sends)" = 2 ] && ok "STALE after BADSIG suppressed" || bad "STALE after BADSIG sent"

echo "== 3 end: exactly one [MAINT] end message with counts; alerting live again"
run end && ok "end exit 0" || bad "end failed"
[ "$(sends)" = 3 ] && [ "$(last_title)" = "[MAINT] end validator" ] && ok "one ntfy: $(tail -1 "$NTFY_OUTBOX")" || bad "end ntfy $(sends)"
tail -1 "$NTFY_OUTBOX" | grep -q 'watchdog=2 monitor=1 integrity=0' && ok "end message carries suppressed counts" || bad "counts missing"
[ ! -e "$f" ] && [ "$(active_rc)" = 1 ] && [ "$(wc -l < "$MAINT_DIR/history.jsonl")" = 1 ] && ok "flag archived to history.jsonl" || bad "flag not archived"
run end; [ "$(sends)" = 3 ] && ok "second end: no message" || bad "second end sent"
run tick; [ "$(sends)" = 3 ] && ok "tick with no flag: no message" || bad "tick sent"

echo "== 4 TTL expiry: alerts pass right after expiry, exactly one [MAINT] end from tick"
: > "$NTFY_OUTBOX"; wd_reset; rm -rf "$T/mon-state"
run start --ttl 10m --reason "expiry test" >/dev/null
wd_deliver "$(old_hb)"; wd_check >/dev/null; mon >/dev/null
[ "$(sends)" = 1 ] && ok "inside window: only the start message" || bad "inside window sends $(sends)"
advance 599; [ "$(active_rc)" = 0 ] && ok "1s before expiry still active" || bad "inactive before expiry"
advance 1;   [ "$(active_rc)" = 1 ] && ok "at expiry: active exit 1 (inactive)" || bad "still active at expiry"
wd_check; [ "$(last_title)" = "pft-watchdog STALE" ] && grep -q 'maintenance window closed' <<<"$(tail -1 "$NTFY_OUTBOX")" \
  && ok "watchdog: STALE alerted on first run after expiry (same state, not a transition)" || bad "watchdog no post-expiry alert"
wd_check; [ "$(sends)" = 2 ] && ok "watchdog: no repeat on the next run" || bad "watchdog repeated"
mon; [ "$(last_title)" = "[postfiat-node] Post Fiat node UNHEALTHY" ] && [ "$(sends)" = 3 ] && ok "monitor: UNHEALTHY alerted after expiry" || bad "monitor no alert"
run tick; [ "$(sends)" = 4 ] && [[ "$(last_title)" == "[MAINT] end"* ]] && grep -q expired <<<"$(tail -1 "$NTFY_OUTBOX")" \
  && ok "tick: one [MAINT] end (expired): $(tail -1 "$NTFY_OUTBOX")" || bad "tick end message"
run tick >/dev/null; [ "$(sends)" = 4 ] && ok "second tick: no message" || bad "second tick sent"
echo "  outbox for this scenario:"; sed 's/^/    /' "$NTFY_OUTBOX"

echo "== 5 malformed flags are ignored (fail-open)"
mal() { # description, then writes $f
  wd_reset; : > "$NTFY_OUTBOX"; wd_deliver "$(old_hb)"
  local rc; rc="$(active_rc)"
  wd_check >/dev/null
  [ "$rc" != 0 ] && [ "$(last_title)" = "pft-watchdog STALE" ] && ok "$1: active exit $rc, watchdog alerted" || bad "$1: rc=$rc sends=$(sends)"
  rm -f "$f"
}
t="$(clock)"
echo 'not json {' > "$f"; chmod 644 "$f"; mal "garbage"
jq -nc --argjson s "$t" '{v:1,id:"x",reason:"r",host:"h",start:$s}' > "$f"; mal "no expiry"
jq -nc --argjson s "$t" '{v:1,id:"x",reason:"r",host:"h",start:$s,expiry:($s+86400)}' > "$f"; mal "24h TTL (over 4h max)"
jq -nc --argjson s "$t" '{v:1,id:"x",reason:"r",host:"h",start:($s+3600),expiry:($s+5400)}' > "$f"; mal "start 1h in the future"
jq -nc --argjson s "$t" '{v:1,id:"x",reason:"r",host:"h",start:$s,expiry:($s+600)}' > "$f"; chmod 666 "$f"; mal "world-writable"
jq -nc --argjson s "$t" '{v:1,id:"x",reason:"r",host:"h",start:$s,expiry:($s+600)}' > "$T/real"; ln -s "$T/real" "$f"; mal "symlink"
echo '{"v":1}' > "$f"; chmod 644 "$f"; run status | grep -q IGNORED && ok "status reports IGNORED flag" || bad "status hides malformed"; rm -f "$f"
echo "  (root ownership is enforced outside test mode: PFT_MAINT_TEST=1 skips it so the tests run unprivileged)"

echo "== 6 restart-node guards: no window, lock held, node not full"
: > "$NTFY_OUTBOX"; rm -f "$T/restarts"; node_set full 10 1000 1
run restart-node; [ $? = 4 ] && [ ! -e "$T/restarts" ] && ok "no window -> REFUSED exit 4, restart not called" || bad "ran without window"
run start --ttl 30m --reason "restart test" >/dev/null
run lock add txmix --until $(( $(clock) + 3600 )) --reason "24h txmix window"
run lock list
run restart-node; [ $? = 4 ] && [ ! -e "$T/restarts" ] && ok "lock held -> REFUSED exit 4, restart not called" || bad "ran with lock held"
advance 3600; run lock list
run end >/dev/null; run start --ttl 30m --reason "restart test" >/dev/null
node_set connected 3 1000 0
run restart-node; [ $? = 4 ] && [ ! -e "$T/restarts" ] && ok "expired lock ignored; node not full -> REFUSED exit 4" || bad "ran while not full"
run end >/dev/null; run start --ttl 10m --reason "short window" >/dev/null
node_set full 10 1000 1
run restart-node; [ $? = 4 ] && [ ! -e "$T/restarts" ] && ok "window shorter than restart+post timeout -> REFUSED" || bad "ran in a too-short window"

echo "== 7 restart-node timeout (node never returns to full)"
run end >/dev/null; run start --ttl 30m --reason "timeout test" >/dev/null
echo 0 > "$T/restart-countdown"; node_set full 10 1000 1; t0="$(clock)"
run restart-node --timeout 120; rc=$?
[ "$rc" = 2 ] && [ "$(wc -l < "$T/restarts")" = 1 ] && [ $(( $(clock) - t0 )) -ge 120 ] && [ $(( $(clock) - t0 )) -le 130 ] \
  && ok "TIMEOUT exit 2 after $(( $(clock) - t0 ))s fake time, one restart" || bad "timeout rc=$rc elapsed $(( $(clock) - t0 ))"

echo "== 8 restart-node PASS and FAIL verdicts"
rm -f "$T/restarts"; echo 4 > "$T/restart-countdown"; node_set full 10 1000 1
run restart-node; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$T/restarts")" = 1 ] && ok "PASS exit 0" || bad "restart PASS rc=$rc"
echo 4 > "$T/restart-countdown"; node_set full 10 1000 1
cat > "$T/restart-stub2" <<EOF
#!/bin/sh
"$T/restart-stub"; echo 5 > "$T/node/peers"; echo 0 > "$T/node/sentry"
EOF
chmod +x "$T/restart-stub2"
RESTART_CMD="$T/restart-stub2" run restart-node; rc=$?
[ "$rc" = 1 ] && ok "FAIL exit 1 when peers 10->5 and sentry not re-peered (after POST_TIMEOUT)" || bad "expected FAIL, rc=$rc"
run end >/dev/null

echo "== 9 sentry copy over the watchdog channel (signed maint message -> pft-watchdog check -> apply-remote)"
S="$T/sentry"; mkdir -p "$S"; : > "$NTFY_OUTBOX"
t="$(clock)"
flag="$(jq -nc --argjson s "$t" '{v:1,id:"m-sentry-test",reason:"sentry copy test",start:$s,expiry:($s+1800),host:"validator",origin:"local"}')"
msg() { jq -nc --arg a "$1" --argjson ts "$2" --argjson f "$flag" '{v:1,type:"maint",action:$a,ts:$ts,flag:$f}'; }
wd_reset; now_r="$(date -u +%s)"
wd_deliver "$(msg start "$now_r")"; MAINT_DIR="$S" wd_check >/dev/null
MAINT_DIR="$S" "$PM" active && jq -e '.origin=="remote" and .id=="m-sentry-test"' "$S/flag.json" >/dev/null \
  && ok "signed start applied on the sentry: $(jq -c . "$S/flag.json")" || bad "sentry copy not applied"
wd_deliver "$(msg start "$now_r")"; MAINT_DIR="$S" wd_check >/dev/null
jq -e '.state=="BADSIG"' "$T/wd.last" >/dev/null && grep -q maint_replay "$T/wd.last" && ok "replayed maint message -> BADSIG maint_replay" || bad "replay accepted"
rm -f "$S/flag.json"
wd_deliver "$(msg start $((now_r + 1)))" "$T/wrong.key"; MAINT_DIR="$S" wd_check >/dev/null
[ ! -e "$S/flag.json" ] && grep -q hmac_mismatch "$T/wd.last" && ok "forged maint message -> BADSIG, no flag" || bad "forged message applied"
wd_deliver "$(msg start $((now_r + 2)))"; MAINT_DIR="$S" wd_check >/dev/null
MAINT_DIR="$S" run end; [ $? = 4 ] && ok "end on a sentry copy refused (origin host ends it)" || bad "copy ended locally"
wd_deliver "$(msg end $((now_r + 3)))"; MAINT_DIR="$S" wd_check >/dev/null
[ ! -e "$S/flag.json" ] && ok "signed end removed the sentry copy" || bad "sentry copy still there"
wd_deliver "$(msg start $((now_r + 4)))"; MAINT_DIR="$S" wd_check >/dev/null; advance 1800
MAINT_DIR="$S" run tick; [ ! -e "$S/flag.json" ] && ! grep -q MAINT "$NTFY_OUTBOX" && ok "expired sentry copy closed by tick without a message" || bad "sentry tick"
echo "  sentry outbox (watchdog only):"; sed 's/^/    /' "$NTFY_OUTBOX"

echo "== 10 pft-integrity --notify honours the window (root, throwaway STATE_DIR)"
if sudo -n true 2>/dev/null; then
  IT="$(mktemp -d)"; : > "$NTFY_OUTBOX"
  ie() { sudo env STATE_DIR="$IT" REGISTRY_CHECK=0 PFT_MAINT_BIN="$PM" PFT_MAINT_TEST=1 MAINT_DIR="$MAINT_DIR" \
           CONF_DIR="$CONF_DIR" PFT_MAINT_NOW_FILE="$PFT_MAINT_NOW_FILE" NTFY_OUTBOX="$NTFY_OUTBOX" "$INTEG" "$@"; }
  ie baseline >/dev/null && ie verify --notify >/dev/null 2>&1
  sudo sed -i '0,/\tsha256\t/s/\tsha256\t[0-9a-f]*/\tsha256\t0000000000000000/' "$IT/manifest.tsv"   # simulate one changed item
  run start --ttl 30m --reason "integrity test" >/dev/null; : > "$NTFY_OUTBOX"
  ie verify --notify 2>"$T/ie.err" | tail -1 | sed 's/^/    /'; sed 's/^/    stderr: /' "$T/ie.err"
  [ "$(sends)" = 0 ] && grep -q 'suppressed (maintenance window' "$T/ie.err" && ok "integrity change (WARN/FAIL) suppressed inside the window" || bad "integrity sent in window"
  advance 1800
  ie verify --notify 2>"$T/ie.err" | tail -1 | sed 's/^/    /'; sed 's/^/    stderr: /' "$T/ie.err"
  [ "$(sends)" = 1 ] && ok "integrity change sent on the first run after expiry: $(tail -1 "$NTFY_OUTBOX")" || bad "integrity not sent after expiry"
  "$PM" tick >/dev/null
else
  echo "  SKIP (needs passwordless sudo)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
