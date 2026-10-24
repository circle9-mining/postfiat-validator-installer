#!/usr/bin/env bash
# Live cold-resync drill on a SENTRY host, with every alert path pointed at a throwaway ntfy topic.
#   sudo bash drill-sentry.sh [--container NAME] [--ttl 45m]      (run from the resync/ directory)
# 1  redirect: back up /etc/pft-watchdog/ntfy.env and /etc/pft-integrity.env, write a random throwaway topic
#    into both and into /etc/pft-maint/ntfy.env (created only for the drill). Restored on ANY exit (trap),
#    then compared by sha256 against the backup.
# 2  live guard proof: `plan` and `drill --yes` with NO maintenance window (expect REFUSE / exit 4).
# 3  pft-maint start --no-sentry -> plan -> drill --yes -> pft-maint end.
# 4  post state, restore, and read the throwaway topic back from ntfy.sh (only [MAINT] start/end expected).
# The topic is printed as <redacted>. Run it on the sentry, never on the validator.
set -euo pipefail
CONTAINER=postfiatd-sentry; TTL=45m
while [ $# -gt 0 ]; do
  case "$1" in --container) CONTAINER="$2"; shift 2 ;; --ttl) TTL="$2"; shift 2 ;; *) echo "unknown $1" >&2; exit 3 ;; esac
done
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 3; }
[ -f ./pft-resync.sh ] || { echo "run from the resync/ directory" >&2; exit 3; }
RS=./pft-resync.sh
ENVS="/etc/pft-watchdog/ntfy.env /etc/pft-integrity.env"
MENV=/etc/pft-maint/ntfy.env
topic="resyncdrill-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
since="$(date -u +%s)"; WINDOW=0; RESTORED=0
shafile() { echo "/run/resync-drill.$(basename "$(dirname "$1")").sha"; }

restore() {
  [ "$RESTORED" -eq 1 ] && return 0
  RESTORED=1
  if [ "$WINDOW" -eq 1 ]; then pft-maint end --reason "pft-resync drill finished (trap)" || true; fi
  local f
  for f in $ENVS; do
    [ -f "$f.pre-resync-drill" ] || continue
    mv -f "$f.pre-resync-drill" "$f"
    echo "restored $f: sha256 matches pre-drill copy: $([ "$(sha256sum < "$f")" = "$(cat "$(shafile "$f")")" ] && echo yes || echo NO) ($(stat -c '%U %a' "$f"))"
    rm -f "$(shafile "$f")"
  done
  if [ "${MENV_CREATED:-0}" -eq 1 ]; then rm -f "$MENV"; echo "removed drill-only $MENV: $([ -e "$MENV" ] && echo NO || echo yes)"; fi
}
trap restore EXIT

echo "pft-resync sentry drill - $(date -u +%FT%TZ) - $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2) - container $CONTAINER"
echo "script sha256: pft-resync.sh $(sha256sum "$RS" | cut -c1-64) | drill-sentry.sh $(sha256sum "$0" | cut -c1-64)"

echo; echo "== 1. redirect every notifier on this host to a throwaway topic"
for f in $ENVS; do
  [ -f "$f" ] || { echo "  $f: absent (nothing to redirect)"; continue; }
  sf="$(shafile "$f")"; sha256sum < "$f" > "$sf"
  cp -p "$f" "$f.pre-resync-drill"
  printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' "$topic" > "$f"; chmod 600 "$f"
  echo "  $f -> https://ntfy.sh/<redacted> (throwaway), original kept as $f.pre-resync-drill"
done
if [ -e "$MENV" ]; then echo "  $MENV already exists - refusing to overwrite it" >&2; exit 3; fi
MENV_CREATED=1
printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' "$topic" > "$MENV"; chmod 600 "$MENV"
echo "  $MENV created for the drill only -> https://ntfy.sh/<redacted> (throwaway)"
echo "  other notifiers on this host: $(systemctl list-timers --all --no-legend 2>/dev/null | grep -oE '(pft|postfiat)[a-z-]*\.timer' | sort -u | tr '\n' ' ')"

echo; echo "== 2. live guard proof: no maintenance window"
echo "\$ pft-resync plan --container $CONTAINER"
bash "$RS" plan --container "$CONTAINER"
echo "\$ pft-resync drill --yes --container $CONTAINER"
set +e; bash "$RS" drill --yes --container "$CONTAINER"; rc=$?; set -e
echo "exit $rc (expect 4)"; [ "$rc" -eq 4 ] || { echo "guard did not refuse - stopping"; exit 1; }

echo; echo "== 3. maintenance window + drill"
echo "\$ pft-maint start --ttl $TTL --reason \"pft-resync cold-resync drill\" --no-sentry"
pft-maint start --ttl "$TTL" --reason "pft-resync cold-resync drill" --no-sentry; WINDOW=1
pft-maint status
echo "\$ pft-resync plan --container $CONTAINER"
bash "$RS" plan --container "$CONTAINER"
echo "\$ pft-resync drill --yes --container $CONTAINER"
set +e; bash "$RS" drill --yes --container "$CONTAINER"; DRC=$?; set -e
echo "drill exit $DRC"
echo "\$ pft-maint end"
pft-maint end --reason "pft-resync drill done"; WINDOW=0

echo; echo "== 4. after the drill"
docker exec "$CONTAINER" curl -s -X POST -d '{"method":"server_info","params":[{}]}' http://127.0.0.1:5005 \
  | jq -c '.result.info | {server_state, peers, complete_ledgers, validated: .validated_ledger.seq}'
pft-maint status
restore
sleep 5
echo "throwaway topic read back from ntfy.sh (since drill start):"
curl -s --max-time 20 "https://ntfy.sh/$topic/json?poll=1&since=$since" | jq -c 'select(.event=="message") | {time: (.time|todate), title, message}'
echo "drill-sentry done: pft-resync drill exit $DRC"
exit "$DRC"
