#!/usr/bin/env bash
# Live proof for `validator-setup.sh fixed` (run on the validator as a sudo-capable user; sentry reachable as `relay`).
# Finding: after a sentry reboot the validator never re-peered with it. Both nodes sat at 10 peers = their outbound
# limit, so neither PeerFinder (nor an admin `connect`) had a free slot to dial the other. Fix: the sentry is an
# [ips_fixed] peer of the validator (fixed peers get their own slot); [ips], [peer_private]=0 and the firewall unchanged.
# Steps: 0 before | 1 alert targets -> throwaway topic, Alertmanager silence, pft-maint window | 2 fixed (config +
# validator restart) | 3 wait for sentry peering | 4 durability: restart the sentry container, wait for re-peering |
# 5 integrity (re-accept only postfiatd config changes) | 6 end window, topic JSON, restore targets, expire silence.
# Usage: ./fixed-peer-proof.sh [ttl (30m)]     CAPTURE: file for the topic JSON (topic redacted)
set -uo pipefail
TTL="${1:-30m}"; TASK=task_c1bc656865a9f3245d9c80b092a5ad1f
HERE="$(cd "$(dirname "$0")" && pwd)"
R() { ssh -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes relay "$@"; }
ts() { date -u +%FT%TZ; }
T="pftpeer-proof-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
red() { sed -E -e "s/$T/pftpeer-proof-<redacted>/g" -e 's/ by [a-z_][a-z0-9_-]*$/ by <redacted>/' -e 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<redacted-ip>/g'; }
AM=http://127.0.0.1:9093
SIP="$(sudo sed -n 's/^RELAY_TARGET=.*@//p' /etc/pft-watchdog/heartbeat.conf | tr -d '"')"
rpcq() { printf '{"method":"%s"}' "$1"; }
vrpc() { sudo docker exec postfiatd curl -s --max-time 10 -d "$(rpcq "$1")" http://127.0.0.1:5005/; }
srpc() { R "docker exec postfiatd-sentry curl -s --max-time 10 -d '$(rpcq "$1")' http://127.0.0.1:5005/" 2>/dev/null; }
health() { # sets V_ST V_P V_SEN S_ST S_P
  local vi vp si
  vi="$(vrpc server_info)"; vp="$(vrpc peers)"; si="$(srpc server_info)"
  V_ST="$(jq -r '.result.info.server_state // "down"' <<<"$vi" 2>/dev/null)"; V_ST="${V_ST:-down}"
  V_P="$(jq -r '.result.info.peers // 0' <<<"$vi" 2>/dev/null)"; V_P="${V_P:-0}"
  V_SEN="$(jq --arg a "$SIP" '[.result.peers[]?.address | select(startswith($a + ":"))] | length' <<<"$vp" 2>/dev/null)"; V_SEN="${V_SEN:-0}"
  S_ST="$(jq -r '.result.info.server_state // "down"' <<<"$si" 2>/dev/null)"; S_ST="${S_ST:-down}"
  S_P="$(jq -r '.result.info.peers // 0' <<<"$si" 2>/dev/null)"; S_P="${S_P:-0}"
  echo "  $(ts) health[$1]: validator server_state=$V_ST peers=$V_P sentry_peered=$V_SEN | sentry server_state=$S_ST peers=$S_P"
}
wait_peered() { # label max_polls(30s)
  local i
  for i in $(seq 1 "$2"); do
    health "$1 poll $i"
    if [ "$V_SEN" -ge 1 ] && [ "$V_ST" = full ] && [ "$S_ST" = full ]; then echo "  $1: PASS (sentry peered, both full)"; return 0; fi
    sleep 30
  done
  echo "  $1: FAIL (not peered/full after $2 polls)"; rc=1; return 1
}
RESTORED=0
restore() {
  [ "$RESTORED" = 1 ] && return; RESTORED=1
  sudo pft-maint active >/dev/null 2>&1 && sudo pft-maint end --reason "fixed-peer proof restore" >/dev/null
  sudo rm -f /etc/pft-maint/ntfy.env
  sudo test -f /etc/postfiat-monitor.env.pre-proof && sudo mv /etc/postfiat-monitor.env.pre-proof /etc/postfiat-monitor.env
  R "test -f /etc/pft-watchdog/ntfy.env.pre-proof && mv /etc/pft-watchdog/ntfy.env.pre-proof /etc/pft-watchdog/ntfy.env"
  echo "$(ts) restored: validator monitor env, sentry watchdog ntfy.env; removed proof /etc/pft-maint/ntfy.env"
}

START="$(date +%s)" rc=0
echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"') | validator-host"
echo "     $(R 'grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d "\""') | sentry-host"
echo "$(ts) fixed-peer live proof start; ttl $TTL"
echo "  script sha256 $(sha256sum "$HERE/validator-setup.sh" | cut -c1-64)  sentry/validator-setup.sh"
[ -n "$SIP" ] || { echo "abort: sentry address not found in heartbeat.conf"; exit 3; }
sudo test -e /etc/pft-maint/ntfy.env && { echo "abort: /etc/pft-maint/ntfy.env already exists"; exit 3; }
sudo pft-maint active >/dev/null 2>&1 && { echo "abort: a maintenance window is already active"; exit 3; }
sudo pft-maint lock list | sed 's/^/  locks: /'

echo "== 0. before"
health before
sudo docker exec postfiatd grep -n -A1 -E '^\[(ips_fixed|peer_private|peers_max)\]' /etc/postfiatd/postfiatd.cfg | red | sed 's/^/  validator cfg: /'
echo "  validator cfg: [ips_fixed] lines: $(sudo docker exec postfiatd grep -c -x '\[ips_fixed\]' /etc/postfiatd/postfiatd.cfg)"
if [ "$V_ST" != full ] || [ "$S_ST" != full ]; then echo "abort: not both full before"; exit 3; fi

echo "== 1. alert targets -> throwaway topic, Alertmanager silence, maintenance window"
trap restore EXIT
pre_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; pre_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
sudo cp -p /etc/postfiat-monitor.env /etc/postfiat-monitor.env.pre-proof
sudo sh -c "grep -vE '^(NTFY_TOPIC|NTFY_TOKEN)=' /etc/postfiat-monitor.env.pre-proof > /etc/postfiat-monitor.env.new \
  && echo 'NTFY_TOPIC=$T' >> /etc/postfiat-monitor.env.new && chmod 600 /etc/postfiat-monitor.env.new \
  && mv /etc/postfiat-monitor.env.new /etc/postfiat-monitor.env"
sudo sh -c "umask 077; printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$T' > /etc/pft-maint/ntfy.env"
R "cp -p /etc/pft-watchdog/ntfy.env /etc/pft-watchdog/ntfy.env.pre-proof && umask 077 && \
   printf 'NTFY_SERVER=https://ntfy.sh\nNTFY_TOPIC=%s\n' '$T' > /etc/pft-watchdog/ntfy.env"
echo "  $(ts) ntfy targets -> throwaway topic (validator: pft-maint, postfiat-monitor; sentry: pft-watchdog)"
ttl_min="${TTL%m}"
SIL="$(curl -s -X POST -H 'Content-Type: application/json' "$AM/api/v2/silences" -d "$(jq -nc --arg s "$(ts)" \
  --arg e "$(date -u -d "+$((ttl_min + 10)) min" +%FT%TZ)" '{matchers:[{name:"alertname",value:".+",isRegex:true,isEqual:true}],
  startsAt:$s, endsAt:$e, createdBy:"fixed-peer-proof", comment:"planned: validator + sentry container restart"}')" | jq -r '.silenceID // empty')"
if [ -n "$SIL" ]; then echo "  Alertmanager silence ${SIL:0:8} alertname=~.+ for $((ttl_min + 10))m"; else echo "abort: silence not created"; exit 3; fi
sudo pft-maint start --ttl "$TTL" --reason "[DRILL] sentry as [ips_fixed] peer: validator + sentry restart" | red | sed 's/^/  /'

echo "== 2. \$ sudo SENTRY_IP=<sentry> WAIT_SECS=900 sentry/validator-setup.sh fixed"
sudo SENTRY_IP="$SIP" WAIT_SECS=900 "$HERE/validator-setup.sh" fixed 2>&1 | red | sed 's/^/  /'; e="${PIPESTATUS[0]}"; echo "  exit=$e"; [ "$e" = 0 ] || rc=1
echo "== 3. sentry peering after the validator restart (poll 30s, max 15 min)"
wait_peered "after fixed" 30

echo "== 4. durability: \$ docker restart postfiatd-sentry   (sentry), then wait for re-peering (max 20 min)"
echo "  $(ts) restarting sentry container"; R 'docker restart postfiatd-sentry' >/dev/null
sleep 20; wait_peered "after sentry restart" 40
sudo docker exec postfiatd curl -s -d '{"method":"peers"}' http://127.0.0.1:5005/ | \
  jq -r --arg a "$SIP" '.result.peers[]? | select(.address | startswith($a + ":")) | "  sentry peer entry: address=\(.address) inbound=\(.inbound // false) uptime=\(.uptime)s"' | red

echo "== 5. integrity (re-accept only postfiatd config changes)"
out="$(sudo pft-integrity verify 2>&1)"; red <<<"$out" | grep -E '^\s+\[(WARN|FAIL)\]|^RESULT' | sed 's/^/  [validator] /'
bad="$(grep -E '^\s+\[(WARN|FAIL)\]' <<<"$out" | grep -v -E 'postfiatd\.cfg|cfg:' || true)"
if [ -n "$bad" ]; then echo "  [validator] NOT accepted: a changed item is not the postfiatd config"; rc=1
elif grep -qE '^\s+\[(WARN|FAIL)\]' <<<"$out"; then
  sudo pft-integrity accept --reason "$TASK: sentry added as [ips_fixed] peer (validator-setup.sh fixed)" 2>&1 | red | sed 's/^/  [validator] /'
  sudo pft-integrity verify 2>&1 | tail -1 | sed 's/^/  [validator] /'
else echo "  [validator] nothing changed in the integrity baseline - no accept needed"; fi
R 'pft-integrity verify 2>&1' | tail -1 | sed 's/^/  [sentry] /'

echo "== 6. end window"
sudo pft-maint end --reason "fixed-peer proof done" | red | sed 's/^/  /'
sleep 10
J="$(curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$T" "$START"))"
red <<<"$J" | tee "${CAPTURE:-/dev/null}" | jq -c '{time, title, message}' | sed 's/^/  /'
titles="$(jq -r '.title // empty' <<<"$J" | tr '\n' '|')"
if [ "$titles" = "[MAINT] start validator|[MAINT] end validator|" ]; then echo "  topic check: PASS ($titles)"
else echo "  topic check: FAIL ($titles)"; rc=1; fi
restore
post_v="$(sudo cat /etc/postfiat-monitor.env | sha256sum)"; post_s="$(R 'sha256sum < /etc/pft-watchdog/ntfy.env')"
if [ "$pre_v" = "$post_v" ]; then echo "  validator /etc/postfiat-monitor.env: identical to pre-proof (sha256)"; else echo "  validator monitor env DIFFERS"; rc=1; fi
if [ "$pre_s" = "$post_s" ]; then echo "  sentry /etc/pft-watchdog/ntfy.env: identical to pre-proof (sha256)"; else echo "  sentry ntfy.env DIFFERS"; rc=1; fi
firing="$(curl -s "$AM/api/v2/alerts" | jq -r '[.[] | select(.status.state != "unprocessed") | .labels.alertname] | unique | join(",")')"
if [ -z "$firing" ]; then curl -s -X DELETE "$AM/api/v2/silence/$SIL" -o /dev/null -w "  Alertmanager silence ${SIL:0:8} expired (HTTP %{http_code}); no alerts active\n"
else echo "  Alertmanager silence ${SIL:0:8} left to run out (active alerts: $firing)"; fi
health final
echo "$(ts) fixed-peer live proof end: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
