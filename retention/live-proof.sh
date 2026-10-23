#!/usr/bin/env bash
# Live proof for pft-retention.sh on the validator host (run as a sudo-capable user; sentry reachable as `relay`).
# Runs inside a pft-maint window, and every alert target that can fire is pointed at a throwaway ntfy topic:
#   validator: /etc/pft-maint/ntfy.env + /etc/postfiat-monitor.env    sentry: /etc/pft-watchdog/ntfy.env
# Steps: 0 disk/config before | 1 pft-maint start | 2 apply --online-delete N | 3 watch-rotation (>= 1 rotation,
# complete_ledgers lower bound advancing) | 4 rollback (config sha256 back to the original) | 5 pft-maint end
# | 6 topic JSON (expect exactly [MAINT] start + [MAINT] end) | restore alert targets (sha256 compared).
#
# Usage: ./live-proof.sh [online_delete (256)] [ttl (45m)]     CAPTURE: file for the topic JSON (topic redacted)
set -uo pipefail
OD="${1:-256}"; TTL="${2:-45m}"
HERE="$(cd "$(dirname "$0")" && pwd)"; RET="$HERE/pft-retention.sh"
R() { ssh -o LogLevel=ERROR relay "$@"; }
ts() { date -u +%FT%TZ; }
T="pftret-proof-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
red() { sed -e "s/$T/pftret-proof-<redacted>/g"; }
poll() { curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$1" "$START"); }
cfg_sha() { sudo docker exec postfiatd sha256sum /etc/postfiatd/postfiatd.cfg | cut -c1-64; }
disk() { # sizes of the ledger store on the host side of the volume
  local db; db="$(sudo docker inspect postfiatd --format '{{range .Mounts}}{{if eq .Destination "/var/lib/postfiatd/db"}}{{.Source}}{{end}}{{end}}')"
  [ -n "$db" ] || { echo "  (db volume not found)"; return; }
  sudo sh -c 'du -s --block-size=1 "$1"/*' sh "$db" | awk '{ n=$2; sub(/.*\//, "db/", n); printf "  du %-24s %12d B\n", n, $1 }'
  sudo du -s --block-size=1 "$db" | awk '{ printf "  du %-24s %12d B\n", "(total)", $1 }'
  sudo df -B1 --output=avail,size "$db" | tail -1 | awk '{ printf "  fs avail %d B of %d B\n", $1, $2 }'
}
restore() {
  [ "${RESTORED:-0}" = 1 ] && return; RESTORED=1
  sudo pft-maint active >/dev/null 2>&1 && sudo pft-maint end --reason "live-proof restore" >/dev/null
  sudo rm -f /etc/pft-maint/ntfy.env
  sudo mv /etc/postfiat-monitor.env.pre-proof /etc/postfiat-monitor.env
  R "mv /etc/pft-watchdog/ntfy.env.pre-proof /etc/pft-watchdog/ntfy.env"
  echo "$(ts) restored: validator monitor env, sentry watchdog ntfy.env; removed proof /etc/pft-maint/ntfy.env"
}
START="$(date +%s)" rc=0
echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "$(ts) retention live proof start; online_delete under test $OD; ttl $TTL"
sudo pft-maint status | sed 's/^/  pft-maint: /'
sudo pft-maint lock list | sed 's/^/  locks: /'
sudo test -e /etc/pft-maint/ntfy.env && { echo "abort: /etc/pft-maint/ntfy.env already exists"; exit 3; }
sudo pft-maint active >/dev/null 2>&1 && { echo "abort: a maintenance window is already active"; exit 3; }
trap restore EXIT
pre_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; pre_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
sudo cp -p /etc/postfiat-monitor.env /etc/postfiat-monitor.env.pre-proof
sudo sh -c "grep -vE '^(NTFY_TOPIC|NTFY_TOKEN)=' /etc/postfiat-monitor.env.pre-proof > /etc/postfiat-monitor.env.new \
  && echo 'NTFY_TOPIC=$T' >> /etc/postfiat-monitor.env.new && chmod 600 /etc/postfiat-monitor.env.new \
  && mv /etc/postfiat-monitor.env.new /etc/postfiat-monitor.env"
sudo sh -c "umask 077; printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$T' > /etc/pft-maint/ntfy.env"
R "cp -p /etc/pft-watchdog/ntfy.env /etc/pft-watchdog/ntfy.env.pre-proof && umask 077 && \
   printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$T' > /etc/pft-watchdog/ntfy.env"
echo "$(ts) ntfy targets -> throwaway topic (validator: pft-maint, postfiat-monitor; sentry: pft-watchdog)"

echo "== 0. before"
orig_sha="$(cfg_sha)"; echo "  postfiatd.cfg sha256 ${orig_sha:0:16}..."
sudo docker exec postfiatd sed -n '/^\[node_db\]/,/^\[/p' /etc/postfiatd/postfiatd.cfg | sed '$ { /^\[/d }' | sed 's/^/  /'
disk

echo "== 1. maintenance window"
sudo pft-maint start --ttl "$TTL" --reason "[DRILL] pft-retention live proof" | red | sed 's/^/  /'

echo "== 2. apply --online-delete $OD"
echo "\$ sudo pft-retention.sh apply --online-delete $OD"
sudo "$RET" apply --online-delete "$OD" 2>&1 | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || { rc=1; echo "  apply FAILED"; }
echo "  postfiatd.cfg sha256 $(cfg_sha | cut -c1-16)... (changed: $([ "$(cfg_sha)" != "$orig_sha" ] && echo yes || echo no))"
echo "\$ sudo pft-retention.sh apply --online-delete $OD   (idempotency: second run must be a no-op)"
sudo "$RET" apply --online-delete "$OD" 2>&1 | sed 's/^/  /'
disk

echo "== 3. rotation under online_delete=$OD"
echo "\$ sudo pft-retention.sh watch-rotation --raise-log --max-wait 1800"
sudo "$RET" watch-rotation --raise-log --max-wait 1800 2>&1 | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || { rc=1; echo "  no rotation"; }
disk

echo "== 4. rollback"
echo "\$ sudo pft-retention.sh rollback"
sudo "$RET" rollback 2>&1 | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || { rc=1; echo "  rollback FAILED"; }
now_sha="$(cfg_sha)"
if [ "$now_sha" = "$orig_sha" ]; then echo "  postfiatd.cfg sha256 ${now_sha:0:16}... identical to before apply"
else echo "  postfiatd.cfg sha256 ${now_sha:0:16}... DIFFERS from before apply"; rc=1; fi
sudo docker exec postfiatd sed -n '/^\[node_db\]/,/^\[/p' /etc/postfiatd/postfiatd.cfg | sed '$ { /^\[/d }' | sed 's/^/  /'
sudo ls -l /var/backups/pft-retention | awk 'NR>1 { print "  backup: " $1, $NF }'
echo "  server_state: $(sudo docker exec postfiatd curl -s -d '{"method":"server_info"}' http://127.0.0.1:5005/ | jq -r '.result.info.server_state + " complete_ledgers " + .result.info.complete_ledgers')"
disk

echo "== 5. end window"
sudo pft-maint end --reason "pft-retention live proof done" | red | sed 's/^/  /'

echo "== 6. messages on the throwaway topic (ntfy poll JSON, topic redacted; expect [MAINT] start + [MAINT] end only)"
sleep 10
J="$(poll "$T")"; red <<<"$J" | tee "${CAPTURE:-/dev/null}"
titles="$(jq -r '.title // empty' <<<"$J" | tr '\n' '|')"
if [ "$titles" = "[MAINT] start validator|[MAINT] end validator|" ]; then echo "  topic check: PASS ($titles)"
else echo "  topic check: FAIL ($titles)"; rc=1; fi

restore
post_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; post_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
if [ "$pre_v" = "$post_v" ]; then echo "  validator /etc/postfiat-monitor.env: identical to pre-proof (sha256)"; else echo "  validator monitor env DIFFERS"; rc=1; fi
if [ "$pre_s" = "$post_s" ]; then echo "  sentry /etc/pft-watchdog/ntfy.env: identical to pre-proof (sha256)"; else echo "  sentry ntfy.env DIFFERS"; rc=1; fi
echo "$(ts) retention live proof end: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
