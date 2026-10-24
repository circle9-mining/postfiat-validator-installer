#!/usr/bin/env bash
# Live two-host proof for pft-sysctl.sh (run on the validator as a sudo-capable user; sentry reachable as `relay`, root).
# Runs inside a pft-maint window with an Alertmanager silence, and every ntfy target that can fire is pointed at a
# throwaway topic:  validator: /etc/pft-maint/ntfy.env + /etc/postfiat-monitor.env   sentry: /etc/pft-watchdog/ntfy.env
# Steps: 0 before (health both hosts) | 1 alert targets + silence + window | 2 validator: check, apply --dry-run,
# apply, check, health | 3 sentry: same | 4 integrity re-accept both hosts (only if every changed item is sysctl-related)
# | 5 sentry reboot: boot_id changes, check PASS (persisted), health back (full, peers +-2, peering, egress)
# | 6 end window, topic JSON (expect exactly [MAINT] start + [MAINT] end) | restore targets (sha256), expire silence.
#
# Usage: ./live-proof.sh [ttl (50m)]     CAPTURE: file for the topic JSON (topic redacted)
set -uo pipefail
TTL="${1:-50m}"
HERE="$(cd "$(dirname "$0")" && pwd)"; SC="$HERE/pft-sysctl.sh"
R() { ssh -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes relay "$@"; }
ts() { date -u +%FT%TZ; }
T="pftsysctl-proof-$(od -An -tx1 -N6 /dev/urandom | tr -d ' \n')"
red() { sed -e "s/$T/pftsysctl-proof-<redacted>/g" -e 's/ by [a-z_][a-z0-9_-]*$/ by <redacted>/'; }
poll() { curl -s --max-time 20 -K <(printf 'url = "https://ntfy.sh/%s/json?poll=1&since=%s"\n' "$1" "$START"); }
AM=http://127.0.0.1:9093
SIP="$(sudo sed -n 's/^RELAY_TARGET=.*@//p' /etc/pft-watchdog/heartbeat.conf | tr -d '"')"
rpcq() { printf '{"method":"%s"}' "$1"; }
vrpc() { sudo docker exec postfiatd curl -s --max-time 10 -d "$(rpcq "$1")" http://127.0.0.1:5005/; }
srpc() { R "docker exec postfiatd-sentry curl -s --max-time 10 -d '$(rpcq "$1")' http://127.0.0.1:5005/" 2>/dev/null; }
egress() { # container -> HTTP code of the public RPC from inside it (needs Docker NAT + ip_forward)
  local c="$1" q; q="$(rpcq server_info)"
  if [ "$c" = postfiatd ]; then sudo docker exec postfiatd curl -s -o /dev/null -w '%{http_code}' --max-time 15 -d "$q" https://rpc.testnet.postfiat.org
  else R "docker exec $c curl -s -o /dev/null -w '%{http_code}' --max-time 15 -d '$q' https://rpc.testnet.postfiat.org" 2>/dev/null; fi
}
# health -> sets V_ST V_P V_SEN S_ST S_P V_NET S_NET PROM and prints one line
health() {
  local vi vp si
  vi="$(vrpc server_info)"; vp="$(vrpc peers)"; si="$(srpc server_info)"
  V_ST="$(jq -r '.result.info.server_state // "down"' <<<"$vi" 2>/dev/null)"; V_ST="${V_ST:-down}"
  V_P="$(jq -r '.result.info.peers // 0' <<<"$vi" 2>/dev/null)"; V_P="${V_P:-0}"
  V_SEN="$(jq --arg a "$SIP" '[.result.peers[]?.address | select(startswith($a + ":"))] | length' <<<"$vp" 2>/dev/null)"; V_SEN="${V_SEN:-0}"
  S_ST="$(jq -r '.result.info.server_state // "down"' <<<"$si" 2>/dev/null)"; S_ST="${S_ST:-down}"
  S_P="$(jq -r '.result.info.peers // 0' <<<"$si" 2>/dev/null)"; S_P="${S_P:-0}"
  V_NET="$(egress postfiatd)"; S_NET="$(egress postfiatd-sentry)"
  PROM="$(curl -s --max-time 10 http://127.0.0.1:9090/api/v1/targets | jq -r '[.data.activeTargets[].health] | "\(map(select(.=="up"))|length)/\(length)"' 2>/dev/null)"
  echo "  $(ts) health[$1]: validator server_state=$V_ST peers=$V_P sentry_peered=$V_SEN | sentry server_state=$S_ST peers=$S_P | container egress (public RPC) validator=$V_NET sentry=$S_NET | prometheus targets up=$PROM"
}
within2() { local d=$(( $1 - $2 )); [ "${d#-}" -le 2 ]; }
assert_health() { # label; uses V0_P/S0_P from the baseline
  local ok=1
  [ "$V_ST" = full ] || [ "$V_ST" = proposing ] || ok=0
  [ "$S_ST" = full ] || [ "$S_ST" = proposing ] || ok=0
  within2 "$V_P" "$V0_P" || ok=0; within2 "$S_P" "$S0_P" || ok=0
  [ "$V_SEN" -ge 1 ] || ok=0; [ "$V_NET" = 200 ] || ok=0; [ "$S_NET" = 200 ] || ok=0
  [ "${PROM%%/*}" = "${PROM##*/}" ] || ok=0
  if [ "$ok" = 1 ]; then echo "  health check [$1]: PASS (both full, peers within +-2 of before ($V0_P/$S0_P), sentry peered, both containers reach the public RPC, prometheus targets $PROM up)"
  else echo "  health check [$1]: FAIL"; rc=1; fi
}
SIL=""
restore() {
  [ "${RESTORED:-0}" = 1 ] && return; RESTORED=1
  sudo pft-maint active >/dev/null 2>&1 && sudo pft-maint end --reason "sysctl live-proof restore" >/dev/null
  sudo rm -f /etc/pft-maint/ntfy.env
  sudo test -f /etc/postfiat-monitor.env.pre-proof && sudo mv /etc/postfiat-monitor.env.pre-proof /etc/postfiat-monitor.env
  R "test -f /etc/pft-watchdog/ntfy.env.pre-proof && mv /etc/pft-watchdog/ntfy.env.pre-proof /etc/pft-watchdog/ntfy.env"
  echo "$(ts) restored: validator monitor env, sentry watchdog ntfy.env; removed proof /etc/pft-maint/ntfy.env"
}
integrity_accept() { # host(validator|sentry) reason
  local out bad
  if [ "$1" = validator ]; then out="$(sudo pft-integrity verify 2>&1)"; else out="$(R 'pft-integrity verify 2>&1')"; fi
  red <<<"$out" | grep -E '^\s+\[(WARN|FAIL)\]|^RESULT' | sed "s/^/  [$1] /"
  bad="$(grep -E '^\s+\[(WARN|FAIL)\]' <<<"$out" | grep -v -i sysctl || true)"
  if [ -n "$bad" ]; then echo "  [$1] NOT accepted: a changed item is not sysctl-related"; rc=1; return; fi
  if grep -qE '^\s+\[(WARN|FAIL)\]' <<<"$out"; then
    if [ "$1" = validator ]; then sudo pft-integrity accept --reason "$2" 2>&1 | red | sed "s/^/  [$1] /"; sudo pft-integrity verify 2>&1 | tail -1 | sed "s/^/  [$1] /"
    else R "pft-integrity accept --reason '$2' 2>&1" | red | sed "s/^/  [$1] /"; R 'pft-integrity verify 2>&1' | tail -1 | sed "s/^/  [$1] /"; fi
  else echo "  [$1] nothing changed in the integrity baseline - no accept needed"; fi
}
host_round() { # validator|sentry
  local h="$1"
  if [ "$h" = validator ]; then x() { sudo /usr/local/bin/pft-sysctl "$@"; }; else x() { R /usr/local/bin/pft-sysctl "$@"; }; fi
  echo "== $h: install"
  if [ "$h" = validator ]; then sudo install -m 755 "$SC" /usr/local/bin/pft-sysctl; sha256sum /usr/local/bin/pft-sysctl | sed 's/^/  /'
  else R 'install -m 755 /dev/stdin /usr/local/bin/pft-sysctl && sha256sum /usr/local/bin/pft-sysctl' <"$SC" | sed 's/^/  /'; fi
  echo "== $h: \$ pft-sysctl check   (before)"; x check 2>&1 | sed 's/^/  /'; echo "  exit=${PIPESTATUS[0]}"
  echo "== $h: \$ pft-sysctl apply --dry-run"; x apply --dry-run 2>&1 | sed 's/^/  /'; echo "  exit=${PIPESTATUS[0]}"
  echo "== $h: \$ pft-sysctl apply"; x apply 2>&1 | sed 's/^/  /'; local e="${PIPESTATUS[0]}"; echo "  exit=$e"; [ "$e" = 0 ] || rc=1
  echo "== $h: \$ pft-sysctl check   (after)"; x check 2>&1 | sed 's/^/  /'; e="${PIPESTATUS[0]}"; echo "  exit=$e"; [ "$e" = 0 ] || rc=1
  echo "== $h: \$ pft-sysctl check --json   (after; summary)"; x check --json 2>/dev/null | jq -c '{result, exit, pass: ([.items[]|select(.status=="PASS")]|length), skip: ([.items[]|select(.status=="SKIP")]|length)}' | sed 's/^/  /'
  sleep 20; health "after apply on $h"; assert_health "after apply on $h"
}

START="$(date +%s)" rc=0
echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"') | validator-host"
echo "     $(R 'grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d "\""') | sentry-host"
echo "$(ts) pft-sysctl two-host live proof start; ttl $TTL"
echo "  script sha256 $(sha256sum "$SC" | cut -c1-64)  sysctl/pft-sysctl.sh"
[ -n "$SIP" ] || { echo "abort: sentry address not found in heartbeat.conf"; exit 3; }
sudo pft-maint status | sed 's/^/  pft-maint: /'; sudo pft-maint lock list | sed 's/^/  locks: /'
sudo test -e /etc/pft-maint/ntfy.env && { echo "abort: /etc/pft-maint/ntfy.env already exists"; exit 3; }
sudo pft-maint active >/dev/null 2>&1 && { echo "abort: a maintenance window is already active"; exit 3; }

if [ "${PRE_ROLLBACK:-0}" = 1 ]; then
  # Re-run on hosts that are already hardened: undo every apply (latest backup first: restores the
  # boot-override files and the previous conf), then restore the oldest backup = the true pre-hardening values.
  # No restart, no reboot: runtime values + files only.
  echo "== 0r. PRE_ROLLBACK=1: back to the pre-hardening state on both hosts"
  for h in validator sentry; do
    if [ "$h" = validator ]; then x() { sudo /usr/local/bin/pft-sysctl "$@"; }; ls_bk() { sudo find /var/backups/pft-sysctl -maxdepth 1 -name 'sysctl-*.tsv' | LC_ALL=C sort; }
    else x() { R /usr/local/bin/pft-sysctl "$@"; }; ls_bk() { R "find /var/backups/pft-sysctl -maxdepth 1 -name 'sysctl-*.tsv' | LC_ALL=C sort"; }; fi
    echo "== $h: $(ls_bk | wc -l) backup(s), restored newest first"
    for b in $(ls_bk | LC_ALL=C sort -r); do
      echo "== $h: \$ pft-sysctl rollback --from $(basename "$b")"; x rollback --from "$b" 2>&1 | sed 's/^/  /'
    done
    echo "== $h: \$ pft-sysctl check   (pre-hardening state; FAIL expected)"; x check 2>&1 | tail -1 | sed 's/^/  /'
  done
fi

echo "== 0. before"
health before; V0_P="$V_P"; S0_P="$S_P"
if [ "$V_ST" != full ] || [ "$S_ST" != full ] || [ "$V_SEN" -lt 1 ]; then echo "abort: not healthy before the proof"; exit 3; fi
BOOT0="$(R 'cat /proc/sys/kernel/random/boot_id')"; echo "  sentry boot_id ${BOOT0:0:8}... uptime: $(R 'uptime -p')"

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
  startsAt:$s, endsAt:$e, createdBy:"pft-sysctl live-proof", comment:"planned: sysctl apply + sentry reboot"}')" | jq -r '.silenceID // empty')"
if [ -n "$SIL" ]; then echo "  Alertmanager silence ${SIL:0:8} alertname=~.+ for $((ttl_min + 10))m"; else echo "abort: silence not created"; exit 3; fi
sudo pft-maint start --ttl "$TTL" --reason "[DRILL] pft-sysctl apply both hosts + sentry reboot" | red | sed 's/^/  /'

host_round validator
host_round sentry

echo "== 4. integrity baselines (re-accept only sysctl-related changes)"
integrity_accept validator "task_c1bc656865a9f3245d9c80b092a5ad1f: pft-sysctl installed + 90-postfiat-hardening.conf"
integrity_accept sentry "task_c1bc656865a9f3245d9c80b092a5ad1f: pft-sysctl installed + 90-postfiat-hardening.conf"

echo "== 5. sentry reboot (persistence)"
echo "  $(ts) \$ systemctl reboot   (sentry)"; R 'systemctl reboot' >/dev/null 2>&1 || true
sleep 45; up=0
for _ in $(seq 1 60); do R true 2>/dev/null && { up=1; break; }; sleep 10; done
[ "$up" = 1 ] || { echo "  sentry did not come back over ssh in 10 min"; rc=1; }
BOOT1="$(R 'cat /proc/sys/kernel/random/boot_id')"
echo "  $(ts) sentry back: boot_id ${BOOT1:0:8}... ($([ "$BOOT1" != "$BOOT0" ] && echo changed || echo UNCHANGED)) uptime: $(R 'uptime -p')"
[ "$BOOT1" != "$BOOT0" ] || rc=1
echo "== 5a. sentry: \$ pft-sysctl check   (after reboot: runtime values come from the persisted file)"
R /usr/local/bin/pft-sysctl check 2>&1 | sed 's/^/  /'; e="${PIPESTATUS[0]}"; echo "  exit=$e"; [ "$e" = 0 ] || rc=1
echo "== 5b. sentry back to full and re-peered (poll every 30s, max 25 min)"
for i in $(seq 1 50); do
  health "post-reboot poll $i" >/tmp/pft-sysctl-health.$$; tail -1 /tmp/pft-sysctl-health.$$
  if [ "$S_ST" = full ] && [ "$V_SEN" -ge 1 ] && within2 "$S_P" "$S0_P" && within2 "$V_P" "$V0_P"; then break; fi
  sleep 30
done
rm -f /tmp/pft-sysctl-health.$$
assert_health "after sentry reboot"
R 'docker ps --format "{{.Names}} {{.Status}}"' | sed 's/^/  sentry container: /'
integrity_accept sentry "task_c1bc656865a9f3245d9c80b092a5ad1f: post-reboot"

echo "== 6. end window"
sudo pft-maint end --reason "pft-sysctl live proof done" | red | sed 's/^/  /'
echo "== 6a. messages on the throwaway topic (ntfy poll JSON, topic redacted; expect [MAINT] start + [MAINT] end only)"
sleep 10
J="$(poll "$T")"; red <<<"$J" | tee "${CAPTURE:-/dev/null}" | jq -c '{time, title, message}' | sed 's/^/  /'
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
echo "$(ts) pft-sysctl two-host live proof end: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
exit "$rc"
