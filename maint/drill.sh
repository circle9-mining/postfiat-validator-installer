#!/usr/bin/env bash
# Live two-host drill for pft-maint. Run on the validator host as a sudo-capable user that can `ssh relay`
# (root on the sentry host). Every alert target involved is pointed at throwaway ntfy topics for the drill:
#   topic A: /etc/pft-maint/ntfy.env + /etc/postfiat-monitor.env (validator), /etc/pft-watchdog/ntfy.env (sentry)
#   topic B: the sentry watchdog after the window, only to catch the RECOVERED that ends the drill
#   1. pft-maint start --ttl 20m; wait until the sentry's watchdog has applied the signed copy
#   2. pft-maint restart-node (guarded restart of postfiatd inside the window)
#   3. stop pft-heartbeat.timer -> the watchdog goes STALE inside the window: suppressed, counted
#   4. let the TTL expire -> tick sends [MAINT] end; first watchdog check after expiry sends STALE
#   5. capture topic A (expect exactly: [MAINT] start, [MAINT] end, pft-watchdog STALE after the end)
#   6. switch the watchdog to topic B, start pft-heartbeat.timer -> RECOVERED on topic B
#   7. restore every ntfy file (cmp against the backups), check server_state full and watchdog OK
# Usage: ./drill.sh [ttl]       CAPTURE_A / CAPTURE_B: files for the topic JSON (topics printed as <redacted>)
set -uo pipefail
TTL="${1:-20m}"
R() { ssh -o LogLevel=ERROR relay "$@"; }
ts() { date -u +%FT%TZ; }
rnd() { od -An -tx1 -N6 /dev/urandom | tr -d ' \n'; }
TA="pftmaint-drill-$(rnd)"; TB="pftmaint-drill-$(rnd)"
red() { sed -e "s/$TA/pftmaint-drill-A-<redacted>/g" -e "s/$TB/pftmaint-drill-B-<redacted>/g"; }
poll() { curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$1" "$START"); }
wd_line() { # wd_line REGEX timeout_sec -> first new watchdog log line matching REGEX
  local end=$(( $(date +%s) + $2 )) line
  while [ "$(date +%s)" -lt "$end" ]; do
    line="$(R "journalctl -u pft-watchdog.service --since '@$START' -o cat --no-pager | grep -E '$1' | tail -1")"
    if [ -n "$line" ] && ! grep -qxF "$line" <<<"$SEEN"; then SEEN+="$line"$'\n'; echo "  sentry watchdog: $line"; return 0; fi
    sleep 10
  done
  echo "  TIMEOUT waiting for /$1/"; return 1
}
restore() {
  [ "${RESTORED:-0}" = 1 ] && return; RESTORED=1
  sudo systemctl start pft-heartbeat.timer
  sudo rm -f /etc/pft-maint/ntfy.env
  sudo mv /etc/postfiat-monitor.env.pre-drill /etc/postfiat-monitor.env
  R "mv /etc/pft-watchdog/ntfy.env.pre-drill /etc/pft-watchdog/ntfy.env"
  echo "$(ts) restored: validator monitor env, sentry watchdog ntfy.env; removed drill /etc/pft-maint/ntfy.env; heartbeat timer started"
}
trap restore EXIT
SEEN="" START="$(date +%s)" rc=0
echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "remote OS: $(R 'grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d "\""')"
echo "$(ts) drill start; validator-host -> sentry-host; ttl $TTL"
sudo pft-maint status | sed 's/^/  validator pft-maint: /'
sudo pft-maint lock list | sed 's/^/  validator locks: /'

pre_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; pre_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
sudo test -e /etc/pft-maint/ntfy.env && { echo "abort: /etc/pft-maint/ntfy.env already exists"; trap - EXIT; exit 3; }
# --- point every alerter that can fire in this drill at topic A (backups kept, compared on restore)
sudo cp -p /etc/postfiat-monitor.env /etc/postfiat-monitor.env.pre-drill
sudo sh -c "grep -vE '^(NTFY_TOPIC|NTFY_TOKEN)=' /etc/postfiat-monitor.env.pre-drill > /etc/postfiat-monitor.env.new \
  && echo 'NTFY_TOPIC=$TA' >> /etc/postfiat-monitor.env.new && chmod 600 /etc/postfiat-monitor.env.new \
  && mv /etc/postfiat-monitor.env.new /etc/postfiat-monitor.env"
sudo sh -c "umask 077; printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$TA' > /etc/pft-maint/ntfy.env"
R "cp -p /etc/pft-watchdog/ntfy.env /etc/pft-watchdog/ntfy.env.pre-drill && umask 077 && \
   printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$TA' > /etc/pft-watchdog/ntfy.env"
echo "$(ts) ntfy targets -> throwaway topic A (validator: pft-maint, postfiat-monitor; sentry: pft-watchdog)" | red

echo "== 1. start window"
sudo pft-maint start --ttl "$TTL" --reason "[DRILL] pft-maint two-host drill" | red | sed 's/^/  /'
EXP="$(sudo pft-maint status --json | jq -r '.flag.expiry // empty')"
[[ "$EXP" =~ ^[0-9]+$ ]] || { echo "  FAIL no window expiry in status --json"; exit 1; }
echo "  window expiry $(date -u -d "@$EXP" +%FT%TZ)"
for _ in $(seq 1 18); do R "pft-maint active" >/dev/null 2>&1 && break; sleep 10; done
R "pft-maint status" | sed 's/^/  sentry pft-maint: /'
R "pft-maint active" >/dev/null 2>&1 || { echo "  FAIL sentry copy not active"; rc=1; }

echo "== 2. guarded restart inside the window"
sudo pft-maint restart-node 2>&1 | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1

echo "== 3. heartbeat stopped inside the window -> STALE must be suppressed"
sudo systemctl stop pft-heartbeat.timer; echo "$(ts) validator: systemctl stop pft-heartbeat.timer"
wd_line '^[0-9T:-]+Z state=STALE .* maint=true notified=none' 330 || rc=1

echo "== 4. wait for expiry, [MAINT] end and the first post-expiry watchdog check"
while [ "$(date +%s)" -lt "$((EXP + 5))" ]; do sleep 15; done
echo "$(ts) window expired"
wd_line '^[0-9T:-]+Z state=STALE .* maint=false notified=STALE' 240 || rc=1
for _ in $(seq 1 12); do sudo pft-maint status | grep -q '^no maintenance window' && break; sleep 10; done
sudo pft-maint status | sed 's/^/  validator pft-maint: /'
R "pft-maint status" | sed 's/^/  sentry pft-maint: /'
echo "  validator history (last window):"
sudo tail -1 /var/lib/pft-maint/history.jsonl | red | sed 's/^/    /'
echo "  sentry history (last window):"
R "tail -1 /var/lib/pft-maint/history.jsonl" | red | sed 's/^/    /'

echo "== 5. messages on topic A (ntfy poll JSON, topic redacted)"
sleep 5
T_A="$(mktemp)"
poll "$TA" | red | tee "${CAPTURE_A:-/dev/null}"
poll "$TA" > "$T_A"
"$(dirname "$0")/check-drill-json.sh" "$T_A" "$EXP" | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
rm -f "$T_A"

echo "== 6. recovery on topic B"
R "umask 077 && printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$TB' > /etc/pft-watchdog/ntfy.env"
echo "$(ts) sentry watchdog ntfy target -> throwaway topic B"
sudo systemctl start pft-heartbeat.timer; echo "$(ts) validator: systemctl start pft-heartbeat.timer"
wd_line '^[0-9T:-]+Z state=RECOVERED .* notified=RECOVERED' 240 || rc=1
sleep 5
poll "$TB" | red | tee "${CAPTURE_B:-/dev/null}"

echo "== 7. restore and final state"
restore
post_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; post_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
same() { if [ "$2" = "$3" ]; then echo "  $1: identical to pre-drill (sha256)"; else echo "  $1: DIFFERS from pre-drill"; rc=1; fi; }
same "validator /etc/postfiat-monitor.env" "$pre_v" "$post_v"
same "sentry /etc/pft-watchdog/ntfy.env" "$pre_s" "$post_s"
echo "  validator /etc/pft-maint/ntfy.env: $(sudo test -e /etc/pft-maint/ntfy.env && echo present || echo 'absent (as before)')"
st="$(sudo postfiat-health 2>/dev/null | grep -o 'server_state: [a-z]*' | head -1)"
echo "  validator $st"; grep -qE 'server_state: (full|proposing)' <<<"$st" || rc=1
sleep 70
R 'systemctl is-active pft-watchdog.timer; pft-watchdog status | jq -c "{state}"' | sed 's/^/  sentry-host: /'
echo "  validator-host: pft-heartbeat.timer $(systemctl is-active pft-heartbeat.timer)"
echo "RESULT: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL) ($(ts))"
exit "$rc"
