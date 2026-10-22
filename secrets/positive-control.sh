#!/usr/bin/env bash
# Positive control for pft-secrets-check.sh: plant dummy secrets, show each one is flagged, show the dummy
# values never appear in the checker output, then remove everything and show the checks are clean again.
#
# Plants (all random, generated here, never used anywhere):
#   1. a seed-format string in a temporary history file /root/.pftpc_history (mode 644)
#   2. a GitHub-token-format string in a world-readable file in the node dir
#   3. a throwaway container with a seed-format value in its environment
#   and probes 127.0.0.1, where the admin ports ARE open (loopback), to show probe.admin_ports can FAIL.
#
# Usage: sudo ./positive-control.sh        (needs docker and a local python:3.12-alpine or PC_IMAGE)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHK="$HERE/pft-secrets-check.sh"
NODE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
PC_IMAGE="${PC_IMAGE:-python:3.12-alpine}"
HIST=/root/.pftpc_history
PLANT="$NODE_DIR/pftpc-dummy.txt"
CTR=pftpc-dummy-env
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }

rnd() { tr -dc "$1" </dev/urandom | head -c "$2"; }
B58='1-9A-HJ-NP-Za-km-z'
FAKE_SEED="s$(rnd "$B58" 28)"
FAKE_GH="ghp_$(rnd 'A-Za-z0-9' 36)"
FAKE_SEED2="s$(rnd "$B58" 28)"
fp() { printf '%s' "$1" | sha256sum | cut -c1-12; }
echo "dummy values (only lengths and sha256 prefixes are shown):"
echo "  seed-format  len=${#FAKE_SEED} sha256=$(fp "$FAKE_SEED")"
echo "  gh-token     len=${#FAKE_GH} sha256=$(fp "$FAKE_GH")"
echo "  env seed     len=${#FAKE_SEED2} sha256=$(fp "$FAKE_SEED2")"

cleanup() {
  rm -f "$HIST" "$PLANT"
  docker rm -f "$CTR" >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
OUT="$(mktemp)"
rc_all=0
expect() {  # expect ID STATUS: run the checker for one id and compare
  local id="$1" want="$2" got
  "$CHK" --only "$id" | tee -a "$OUT" | sed -n '/\[/p'
  got="$("$CHK" --only "$id" --json | grep -oE "\"id\":\"$id\",\"status\":\"[A-Z]+\"" | grep -oE '[A-Z]+"$' | tr -d '"')"
  if [ "$got" = "$want" ]; then echo "  -> OK: $id is $got"; else echo "  -> UNEXPECTED: $id is ${got:-?}, wanted $want"; rc_all=1; fi
}

echo; echo "== plant"
echo "\$ printf 'curl ... \"secret\":\"<seed-format>\"' > $HIST; chmod 644 $HIST"
printf 'ls\ncurl -s localhost:5005 -d {"secret":"%s"}\n' "$FAKE_SEED" >"$HIST"; chmod 644 "$HIST"
echo "\$ printf 'GH_TOKEN=<gh-token>' > $PLANT; chmod 644 $PLANT"
printf 'GH_TOKEN=%s\n' "$FAKE_GH" >"$PLANT"; chmod 644 "$PLANT"
echo "\$ docker run -d --name $CTR --network none -e VALIDATION_SEED=<env seed> $PC_IMAGE sleep 300"
docker run -d --name "$CTR" --network none -e "VALIDATION_SEED=$FAKE_SEED2" "$PC_IMAGE" sleep 300 >/dev/null

echo; echo "== checker flags each plant"
expect leak.shell_history FAIL
expect leak.world_readable FAIL
expect leak.docker_env FAIL
echo "\$ ./pft-secrets-check.sh --probe 127.0.0.1 --label loopback   # admin ports are open on loopback"
"$CHK" --probe 127.0.0.1 --label loopback | tee -a "$OUT" | sed -n '/\[/p'

echo; echo "== dummy values never appear in checker output"
n=0; for v in "$FAKE_SEED" "$FAKE_GH" "$FAKE_SEED2"; do n=$((n + $(grep -cF -- "$v" "$OUT"))); done
echo "grep -cF <each dummy value> checker-output: total $n hits ($(wc -l <"$OUT") output lines scanned)"
[ "$n" -eq 0 ] || rc_all=1

echo; echo "== clean up and re-check"
cleanup
echo "\$ test -e $HIST / $PLANT; docker ps -a --filter name=$CTR -q | wc -l"
for f in "$HIST" "$PLANT"; do [ -e "$f" ] && echo "  still present: $f" || echo "  removed: $f"; done; echo "  containers: $(docker ps -a --filter "name=$CTR" -q | wc -l)"
expect leak.shell_history PASS
expect leak.world_readable PASS
expect leak.docker_env PASS
rm -f "$OUT"
echo "positive control: $([ "$rc_all" -eq 0 ] && echo PASSED || echo FAILED)"
exit "$rc_all"
