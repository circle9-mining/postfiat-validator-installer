#!/usr/bin/env bash
# Live two-host drill for the watchdog add-on. Run on the validator host as a sudo-capable user that can
# `ssh relay` (root on the watchdog/sentry host). Never touches postfiatd.
#   1. point the watchdog's ntfy.env at a throwaway test topic (file given as $1, already on the relay host)
#   2. STALE:     stop pft-heartbeat.timer until the watchdog reports STALE, then start it -> RECOVERED
#   3. BADSIG:    send one heartbeat signed with a random wrong key -> BADSIG, next good one -> RECOVERED
#   4. fetch every message on the test topic as JSON (ntfy poll API), restore the previous ntfy.env
# Usage: ./drill.sh /root/path/ntfy-drill.env     (prints the test topic only as <redacted>)
set -uo pipefail
DRILL_ENV="${1:?path of the drill ntfy env on the relay host}"
R() { ssh -o LogLevel=ERROR relay "$@"; }
ts() { date -u +%FT%TZ; }
wait_state() { # wait_state STATE timeout_sec
  local end=$(( $(date +%s) + $2 )) line
  while [ "$(date +%s)" -lt "$end" ]; do
    line="$(R "journalctl -u pft-watchdog.service --since '@$START' -o cat --no-pager | grep -E '^[0-9T:-]+Z state=$1 ' | tail -1")"
    if [ -n "$line" ] && ! grep -qxF "$line" <<<"$SEEN"; then SEEN+="$line"$'\n'; echo "  watchdog: $line"; return 0; fi
    sleep 10
  done
  echo "  TIMEOUT waiting for $1"; return 1
}
SEEN="" START="$(date +%s)" rc=0
echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "remote OS: $(R 'grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d "\""')"
echo "$(ts) drill start; validator-host -> sentry-host; postfiatd untouched"
TOPIC="$(R "grep '^NTFY_TOPIC=' '$DRILL_ENV' | cut -d= -f2")"
R "cp -p /etc/pft-watchdog/ntfy.env /etc/pft-watchdog/ntfy.env.pre-drill && install -m 600 '$DRILL_ENV' /etc/pft-watchdog/ntfy.env"
echo "$(ts) watchdog ntfy target -> throwaway test topic pftwd-drill-<redacted> (previous ntfy.env saved)"
R 'pft-watchdog status | jq -c "{state, last_good}"' | sed 's/^/  status: /'

echo "== STALE -> RECOVERED"
sudo systemctl stop pft-heartbeat.timer; echo "$(ts) validator: systemctl stop pft-heartbeat.timer"
wait_state STALE 330 || rc=1
sudo systemctl start pft-heartbeat.timer; echo "$(ts) validator: systemctl start pft-heartbeat.timer"
wait_state RECOVERED 180 || rc=1

echo "== BADSIG -> RECOVERED"
WK="$(mktemp)"; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$WK"; chmod 600 "$WK"
sudo HMAC_KEY_FILE="$WK" /usr/local/bin/pft-heartbeat | sed 's/^/  /'
echo "$(ts) validator: sent one heartbeat signed with a random wrong key (HMAC_KEY_FILE=<tmp>)"
rm -f "$WK"
wait_state BADSIG 150 || rc=1
wait_state RECOVERED 150 || rc=1

echo "== watchdog journal for the drill window (sentry-host)"
R "journalctl -u pft-watchdog.service --since '@$START' -o cat --no-pager | grep -E '^[0-9T:-]+Z state=|^ntfy:'" | sed 's/^/  /'
echo "== messages on the test topic (ntfy poll JSON, topic redacted)"
sleep 5
curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$TOPIC" "$START") \
  | sed "s/$TOPIC/pftwd-drill-<redacted>/g" | tee "${CAPTURE:-/dev/null}"
n=$(curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$TOPIC" "$START") | jq -s 'map(select(.event=="message")) | length')
titles="$(curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$TOPIC" "$START") | jq -r 'select(.event=="message") | .title' | tr '\n' ',')"
echo "test-topic messages: $n  titles: $titles"
if [ "$titles" = "pft-watchdog STALE,pft-watchdog RECOVERED,pft-watchdog BADSIG,pft-watchdog RECOVERED," ]; then
  echo "PASS one alert per incident + one recovery each"
else echo "FAIL unexpected message set"; rc=1
fi

R "mv /etc/pft-watchdog/ntfy.env.pre-drill /etc/pft-watchdog/ntfy.env"
echo "$(ts) watchdog ntfy target restored to the pre-drill file"
R 'systemctl is-active pft-watchdog.timer; pft-watchdog status | jq -c "{state}"' | sed 's/^/  sentry-host: /'
echo "  validator-host: pft-heartbeat.timer $(systemctl is-active pft-heartbeat.timer)"
echo "RESULT: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL) ($(ts))"
exit "$rc"
