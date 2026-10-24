#!/usr/bin/env bash
# pft-vlwatch fixture-injection drill: capture the node's live RPC answers, inject faults into a copy, and
# check that --notify sends exactly ONE change message to a THROWAWAY ntfy topic (never the operator's).
#   sudo bash vlwatch/drill.sh [--container NAME]
# Steps: 1 live capture -> 2 healthy run (silent, sets baseline) -> 3 injected FAIL (expired list + refresh error
#        + seq rollback) -> 1 message -> 4 same FAIL again (silent) -> 5 read the throwaway topic back from ntfy.sh.
# The topic is random, printed as <redacted>; the drill's ntfy.env lives in a temp dir, /etc/pft-vlwatch is not read.
set -euo pipefail
CONTAINER=postfiatd
[ "${1:-}" = --container ] && CONTAINER="$2"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLW="$HERE/pft-vlwatch.sh"
D="$(mktemp -d /tmp/vlw-drill.XXXXXX)"; chmod 700 "$D"
trap 'rm -rf "$D"' EXIT
topic="vlwdrill-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$D/conf"; chmod 700 "$D/conf"
printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' "$topic" > "$D/conf/ntfy.env"; chmod 600 "$D/conf/ntfy.env"
export PFT_VLWATCH_CONF="$D/conf" NODE_LABEL="[DRILL] $CONTAINER"
unset NTFY_OUTBOX
since="$(date -u +%s)"

echo "pft-vlwatch drill - $(date -u +%Y-%m-%dT%H:%M:%SZ) - $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2) - container $CONTAINER"
echo "script sha256: $(sha256sum "$VLW" | cut -c1-64)"
echo "ntfy target: https://ntfy.sh/<redacted> (random throwaway topic, env file $(stat -c '%U %a' "$D/conf/ntfy.env"))"
echo "operator config dir /etc/pft-vlwatch present: $([ -e /etc/pft-vlwatch ] && echo yes || echo no) (not used: PFT_VLWATCH_CONF points at the temp dir)"

echo; echo "== 1. capture live RPC answers"
mkdir -p "$D/live" "$D/bad"
for m in validator_list_sites validators server_info; do
  docker exec "$CONTAINER" curl -s --max-time 10 -X POST -d "{\"method\":\"$m\",\"params\":[{}]}" http://127.0.0.1:5005 > "$D/live/$m.json"
  echo "  $m: $(jq -r .result.status "$D/live/$m.json")"
done
seq_live="$(jq '.result.publisher_lists[0].seq' "$D/live/validators.json")"
pub="$(jq -r '.result.publisher_lists[0].pubkey_publisher' "$D/live/validators.json")"

echo; echo "== 2. healthy live answers (expect PASS, no message)"
set +e
bash "$VLW" --fixtures "$D/live" --notify --state "$D/state.json"; echo "exit $?"
set -e

echo; echo "== 3. inject: expiration 2 days ago, last_refresh_status=invalid, seq rollback (saved seq+5)"
jq --arg e "$(date -u -d '2 days ago' '+%Y-%b-%d %H:%M:%S.000000000 UTC')" \
  '.result.publisher_lists[0].expiration = $e | .result.validator_list.status = "expired"' "$D/live/validators.json" > "$D/bad/validators.json"
jq '.result.validator_sites[0].last_refresh_status = "invalid" | .result.validator_sites[0].last_refresh_message = "drill: injected"' \
  "$D/live/validator_list_sites.json" > "$D/bad/validator_list_sites.json"
cp "$D/live/server_info.json" "$D/bad/"
jq --arg k "$pub" --argjson s "$((seq_live + 5))" '.seq[$k] = $s' "$D/state.json" > "$D/s.tmp" && mv "$D/s.tmp" "$D/state.json"
set +e
bash "$VLW" --fixtures "$D/bad" --notify --state "$D/state.json"; echo "exit $?"
echo; echo "== 4. same injected FAIL again (expect no new message)"
bash "$VLW" --fixtures "$D/bad" --notify --state "$D/state.json"; echo "exit $?"
set -e

echo; echo "== 5. read back the throwaway topic (https://ntfy.sh/<redacted>/json?poll=1&since=$since)"
sleep 3
curl -s --max-time 15 "https://ntfy.sh/$topic/json?poll=1&since=$since" > "$D/received.jsonl"
n="$(jq -s '[.[] | select(.event == "message")] | length' "$D/received.jsonl")"
jq -c 'select(.event == "message") | {time: (.time | todate), title, priority, tags, message}' "$D/received.jsonl"
echo "messages received on throwaway topic: $n"
if [ "$n" = 1 ]; then echo "DRILL RESULT: PASS (exactly one change message, to the throwaway topic)"; else echo "DRILL RESULT: FAIL (expected 1 message, got $n)"; exit 1; fi
