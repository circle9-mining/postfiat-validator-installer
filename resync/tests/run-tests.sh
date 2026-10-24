#!/usr/bin/env bash
# "cond && ok || bad" is intended: ok() always returns 0, so bad runs only when cond fails.
# shellcheck disable=SC2015
# Offline test suite for pft-resync.sh - no root, no node, no docker: docker, server_info and pft-maint are stubs,
# the clock is fake (PFT_RESYNC_NOW_FILE, every poll sleep advances it), and the "DB" is a temp dir holding a
# marker file OLD. The DB moves, rollback and deletion are the real mv/rm code paths on that temp dir.
# server_info stub: while the OLD marker sits in the DB dir (pre-drill, or after a rollback restored it) it answers
# "full, validated 100"; with a fresh DB it pops the next line of the case's sequence (the last line repeats).
# Usage: bash resync/tests/run-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS="$HERE/../pft-resync.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }
ind() { sed 's/^/    /'; }

# --- stubs ---
cat > "$WORK/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.log"
case "$1" in
  inspect) case "$3" in *Mounts*) echo "$STUB_DIR/vol/_data" ;; *) echo "running (restart policy unless-stopped)" ;; esac ;;
  start) [ -e "$STUB_DIR/fail-start" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK/rpc" <<'EOF'
#!/usr/bin/env bash
[ -e "$STUB_DIR/slow" ] && sleep 0.2
# lag: the RPC takes N fake seconds to answer (advances the fake clock)
[ -e "$STUB_DIR/lag" ] && echo $(( $(cat "$PFT_RESYNC_NOW_FILE") + $(cat "$STUB_DIR/lag") )) > "$PFT_RESYNC_NOW_FILE"
if [ -e "$STUB_DIR/vol/_data/OLD" ]; then
  echo '{"info":{"server_state":"full","peers":11,"validated_ledger":{"seq":100},"complete_ledgers":"90-100","pubkey_node":"n9TESTKEY0000"}}'
  exit 0
fi
n="$(cat "$STUB_DIR/rpc.n" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$STUB_DIR/rpc.n"
total="$(wc -l < "$STUB_DIR/seq")"; [ "$n" -gt "$total" ] && n="$total"
sed -n "${n}p" "$STUB_DIR/seq"
EOF
cat > "$WORK/maint" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_DIR/maint.json"
EOF
chmod +x "$WORK/docker" "$WORK/rpc" "$WORK/maint"

st() { # state peers validated -> server_info line
  if [ "$1" = down ]; then echo '{}'; return; fi
  jq -nc --arg s "$1" --argjson p "$2" --argjson v "$3" \
    '{info:({server_state:$s,peers:$p,complete_ledgers:(if $v>0 then "\($v)-\($v)" else "empty" end)}
            + (if $v>0 then {validated_ledger:{seq:$v}} else {} end))}'
}
WIN_OK='{"window":"active","remaining_sec":3600,"locks":[]}'

# setup NAME -> fresh case dir with DB + marker, window open, clock at 1800000000
setup() {
  C="$WORK/$1"; mkdir -p "$C/vol/_data/nudb"; echo old-ledger > "$C/vol/_data/OLD"; chmod 750 "$C/vol/_data"
  echo "$WIN_OK" > "$C/maint.json"; echo 1800000000 > "$C/now"; : > "$C/seq"
  export STUB_DIR="$C" PFT_RESYNC_TEST=1 PFT_RESYNC_NOW_FILE="$C/now" PFT_RESYNC_RPC_CMD="$WORK/rpc" \
         PFT_RESYNC_DOCKER_CMD="$WORK/docker" PFT_RESYNC_MAINT_CMD="$WORK/maint" RUN_DIR="$C/runs"
}
run() { OUT="$(bash "$RS" "$@" 2>&1)"; RC=$?; }
J() { jq -r "$1" "$C"/runs/*.jsonl 2>/dev/null; }
untouched() { [ "$(cat "$C/vol/_data/OLD" 2>/dev/null)" = old-ledger ] && ! grep -qE '^(stop|start)' "$C/docker.log" 2>/dev/null; }

echo "pft-resync tests - $(date -u +%FT%TZ) - script sha256 $(sha256sum "$RS" | cut -c1-64)"
echo
echo "# 1 passing cold resync: down -> disconnected -> connected -> syncing -> tracking -> full, then caught up"
setup pass
{ st down; st disconnected 0 0; st connected 3 0; st connected 6 0; st syncing 8 0; st syncing 9 95
  st tracking 10 99; st full 10 100; st full 11 101; } > "$C/seq"
run drill --yes --timeout 600
echo "$OUT" | sed -n '/^pft-resync report/,$p' | sed 's/^/    /'
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC"
[ "$(J 'select(.ev=="result") | .verdict')" = PASS ] && ok "verdict PASS" || bad "verdict"
ph="$(J 'select(.ev=="result") | .phases | [.connected,.syncing,.tracking,.full,.first_validated,.caught_up] | map(tostring) | join(",")')"
[ "$ph" = "10,20,30,35,25,40" ] && ok "phases connected,syncing,tracking,full,first_validated,caught_up = $ph s" || bad "phases $ph"
[ "$(J 'select(.ev=="result") | .peers_at_full')" = 11 ] && ok "peers at full = 11" || bad "peers at full"
[ ! -e "$C/vol/_data/OLD" ] && [ -d "$C/vol/_data" ] && [ "$(stat -c %a "$C/vol/_data")" = 750 ] \
  && ok "fresh DB dir in place, mode 750 copied from the old one" || bad "fresh DB dir"
ls -d "$C"/vol/_data.resync-* >/dev/null 2>&1 && bad "aside DB left behind" || ok "old DB deleted after PASS (no aside left)"
[ "$(J 'select(.ev=="cleanup") | .deleted')" = true ] && ok "cleanup event deleted=true" || bad "cleanup"
[ "$(grep -c '^stop' "$C/docker.log")" = 1 ] && [ "$(grep -c '^start' "$C/docker.log")" = 1 ] \
  && ok "exactly one docker stop and one docker start" || bad "docker calls: $(tr '\n' ';' < "$C/docker.log")"
run report "$(ls "$C"/runs/*.jsonl)" --json
[ "$(jq -r '.observed | join(">")' <<<"$OUT")" = "down>disconnected>connected>syncing>tracking>full" ] \
  && ok "report --json observed = $(jq -r '.observed | join(">")' <<<"$OUT")" || bad "report observed: $OUT"

echo
echo "# 2 skipped states: connected straight to full (syncing/tracking get the full time, observed shows the skip)"
setup skip
{ st connected 5 0; st full 9 101; } > "$C/seq"
run drill --yes --timeout 600 --keep-old
ph="$(J 'select(.ev=="result") | .phases | [.connected,.syncing,.tracking,.full] | map(tostring) | join(",")')"
[ "$RC" = 0 ] && [ "$ph" = "0,5,5,5" ] && ok "PASS, connected/syncing/tracking/full = $ph s" || bad "exit $RC phases $ph"
[ "$(J 'select(.ev=="poll") | .state' | uniq | paste -sd'>')" = "connected>full" ] && ok "observed connected>full" || bad "observed"
[ "$(cat "$C"/vol/_data.resync-aside-*/OLD 2>/dev/null)" = old-ledger ] && ok "--keep-old keeps the old DB aside" || bad "keep-old"

echo
echo "# 2b slow RPC: phases are timed at the answer, not the question (live run 1 found this)"
setup lag
{ st down; st connected 3 0; st full 9 101; } > "$C/seq"; echo 4 > "$C/lag"
run drill --yes --timeout 600
ph="$(J 'select(.ev=="result") | .phases | [.connected,.full] | map(tostring) | join(",")')"
els="$(J 'select(.ev=="poll") | "\(.el)/\(.rpc_s)"' | paste -sd' ')"
[ "$RC" = 0 ] && [ "$ph" = "13,22" ] && ok "4 s RPC lag: connected=13 full=22 (poll el/rpc_s: $els)" || bad "lag exit $RC phases $ph polls $els"

echo
echo "# 3 timeout -> rollback restores the old DB"
setup timeout
{ st down; st connected 2 0; } > "$C/seq"
run drill --yes --timeout 60
echo "$OUT" | grep -E '"ev":"(result|rollback)"|drill TIMEOUT' | sed 's/^/    /'
[ "$RC" = 1 ] && ok "exit 1" || bad "exit $RC"
[ "$(J 'select(.ev=="result") | .verdict')" = TIMEOUT ] && ok "verdict TIMEOUT" || bad "verdict"
[ "$(J 'select(.ev=="poll") | .el' | tail -1)" = 60 ] && ok "last poll at el=60 s (= --timeout)" || bad "last poll"
[ "$(cat "$C/vol/_data/OLD" 2>/dev/null)" = old-ledger ] && ok "old DB back in place (marker intact)" || bad "old DB not restored"
ls -d "$C"/vol/_data.resync-* >/dev/null 2>&1 && bad "aside/failed dir left behind" || ok "no aside or failed-fresh dir left"
[ "$(J 'select(.ev=="rollback") | "\(.ok) \(.state.state)"')" = "true full" ] && ok "rollback ok=true, node full again" || bad "rollback event"
[ "$(grep -c '^stop' "$C/docker.log") $(grep -c '^start' "$C/docker.log")" = "2 2" ] && ok "2 stops + 2 starts (drill + rollback)" || bad "docker calls"

echo
echo "# 4 rollback whose restart fails -> exit 5 (operator must look)"
setup rbfail
{ st connected 2 0; } > "$C/seq"
OUT="$(STUB_DIR="$C" bash -c 'bash "$0" drill --yes --timeout 20 & p=$!; while ! grep -q "^start" "$STUB_DIR/docker.log" 2>/dev/null; do sleep 0.05; done; touch "$STUB_DIR/fail-start"; wait $p' "$RS" 2>&1)"; RC=$?
[ "$RC" = 5 ] && ok "exit 5 when the rollback cannot start the container" || bad "exit $RC"
[ "$(cat "$C/vol/_data/OLD" 2>/dev/null)" = old-ledger ] && ok "old DB still moved back before the failed start" || bad "old DB"

echo
echo "# 5 refusals - nothing is stopped or moved"
setup nowin; echo '{"window":"none","remaining_sec":null,"locks":[]}' > "$C/maint.json"
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && grep -q 'no active pft-maint window' <<<"$OUT" && untouched && ok "no maintenance window -> exit 4, untouched" || bad "nowin exit $RC"
setup noyes
run drill; echo "    $OUT"
[ "$RC" = 4 ] && grep -q -- '--yes not given' <<<"$OUT" && untouched && ok "no --yes -> exit 4, untouched" || bad "noyes exit $RC"
setup short; echo '{"window":"active","remaining_sec":1000,"locks":[]}' > "$C/maint.json"
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && grep -q '1000s left' <<<"$OUT" && untouched && ok "window shorter than TIMEOUT+300 -> exit 4" || bad "short exit $RC"
setup lock; echo '{"window":"active","remaining_sec":3600,"locks":["txmix 2026-10-25T00:00:00Z 24h run"]}' > "$C/maint.json"
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && grep -q 'lock' <<<"$OUT" && untouched && ok "data-collection lock held -> exit 4" || bad "lock exit $RC"
setup notfull; rm "$C/vol/_data/OLD"; st syncing 4 0 > "$C/seq"
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && grep -q 'not full' <<<"$OUT" && ! grep -qE '^(stop|start)' "$C/docker.log" 2>/dev/null && ok "node not full -> exit 4" || bad "notfull exit $RC"
setup maintmissing; export PFT_RESYNC_MAINT_CMD=/nonexistent/pft-maint
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && untouched && ok "pft-maint missing -> exit 4 (fails closed)" || bad "maintmissing exit $RC"

echo
echo "# 6 SIGTERM mid-drill -> rollback, exit 6"
setup sig; { st connected 2 0; } > "$C/seq"; touch "$C/slow"
OUT="$(STUB_DIR="$C" bash -c 'bash "$0" drill --yes --timeout 600 & p=$!; while ! grep -q "^start" "$STUB_DIR/docker.log" 2>/dev/null; do sleep 0.05; done; sleep 1; kill -TERM $p; wait $p' "$RS" 2>&1)"; RC=$?
[ "$RC" = 6 ] && ok "exit 6" || bad "exit $RC"
[ "$(cat "$C/vol/_data/OLD" 2>/dev/null)" = old-ledger ] && ! ls -d "$C"/vol/_data.resync-* >/dev/null 2>&1 \
  && ok "old DB restored, nothing left aside" || bad "sig restore"
[ "$(J 'select(.ev=="result") | .verdict')" = INTERRUPTED ] && ok "verdict INTERRUPTED recorded" || bad "sig verdict"

echo
echo "# 7 plan is read-only"
setup plan
run plan; grep -v "owner/mode" <<<"$OUT" | ind   # owner line omitted: it is the local test user
[ "$RC" = 0 ] && grep -q 'drill would:       RUN' <<<"$OUT" && untouched && ok "plan with window: RUN, nothing changed" || bad "plan rc $RC"
echo '{"window":"none","remaining_sec":null,"locks":[]}' > "$C/maint.json"
run plan
grep -q 'drill would:       REFUSE' <<<"$OUT" && untouched && ok "plan without window: REFUSE" || bad "plan nowin"
grep -qE '^(stop|start|exec)' "$C/docker.log" && bad "plan called docker stop/start/exec" || ok "plan made only docker inspect calls"

echo
echo "# 8 DB path guard"
setup guard; mv "$C/vol/_data" "$C/vol/real"; ln -s "$C/vol/real" "$C/vol/_data"
run drill --yes; echo "    $OUT"
[ "$RC" = 4 ] && [ -L "$C/vol/_data" ] && [ "$(cat "$C/vol/real/OLD")" = old-ledger ] && ok "symlinked DB dir -> exit 4" || bad "guard exit $RC"

echo
echo "# shellcheck"
if shellcheck "$RS" "$HERE/run-tests.sh" "$HERE/../drill-sentry.sh"; then ok "shellcheck clean ($(shellcheck --version | sed -n 's/^version: //p'))"; else bad "shellcheck"; fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
