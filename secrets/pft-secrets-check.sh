#!/usr/bin/env bash
# res() always returns 0, so `test && res PASS ... || res WARN ...` never runs both branches.
# shellcheck disable=SC2015
# pft-secrets-check: read-only secrets and config-exposure check for a Post Fiat validator or sentry host.
#
# Complements ../audit (SSH, firewall, container hardening) with: postfiatd.cfg port/admin bindings,
# [validator_token]/[validation_seed] handling, secret leakage paths (docker inspect, container logs,
# debug.log, shell history, world-readable files, backup archives) and a remote reachability probe.
# Secret values are never printed: only file/container names, counts, modes and owners.
#
# Exit codes: 0 all checks PASS (INFO ignored), 1 at least one WARN, 2 at least one FAIL, 3 usage error.
#
# Usage: sudo ./pft-secrets-check.sh [--json] [--only PREFIX[,PREFIX...]] [--list] [--show-paths]
#        ./pft-secrets-check.sh --probe HOST [--label NAME] [--json]
#   --json        print a JSON summary instead of text lines
#   --only        run only checks whose id starts with one of the prefixes (e.g. --only leak.)
#   --show-paths  print /home/<name> paths unmasked (default masks the user name)
#   --probe HOST  run on ANOTHER host you operate: one TCP connect per admin/RPC port (5005 6005 6006 50051)
#                 and to the peer port; expects admin/RPC closed and peer open. Touches nothing else.
#   --label NAME  name printed instead of HOST in probe output (default "target")
# Env:   CONTAINER (auto: first running postfiatd container)  COMPOSE_DIR
#        (default: compose project dir of the container, else /opt/<container>)
#        BACKUP_DIR (/var/backups/postfiat)  PEER_PORT (2559)  LOG_TAIL (20000 container log lines)

set -uo pipefail

PEER_PORT="${PEER_PORT:-2559}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postfiat}"
LOG_TAIL="${LOG_TAIL:-20000}"
ADMIN_PORTS=(5005 6005 6006 50051)
CHECK_IDS="cfg.admin_roles cfg.admin_exposure cfg.rpc_exposure cfg.container_bind cfg.secret_sections
keys.validator_keys leak.docker_env leak.container_logs leak.debug_log leak.shell_history leak.world_readable
leak.backups probe.admin_ports probe.peer_port"

# Strong secret patterns (PCRE). A hit is a FAIL wherever it is found; the matched text is never printed.
#  - XRPL-family seeds: s + 28 base58 chars (secp256k1) or sEd + 28 (ed25519), not inside a longer base58 word
#  - validator token blob: base64 of {"manifest": / {"validation_secret_key"
#  - key words emitted by wallet_propose / validator-keys, PEM private keys, GitHub and ntfy access tokens
B58='1-9A-HJ-NP-Za-km-z'
SECRET_RX="(?<![${B58}])s(?:Ed)?[${B58}]{28}(?![${B58}])|eyJtYW5pZmVzdCI6|eyJ2YWxpZGF0aW9uX3NlY3JldF9rZXki"
SECRET_RX+="|validation_secret_key|master_seed|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36}"
SECRET_RX+="|github_pat_[A-Za-z0-9_]{40,}|tk_[a-z0-9]{29}"
# Public documentation examples that match SECRET_RX but are not secrets (the example seed printed in the
# comments of the stock postfiatd.cfg / rippled example config).
KNOWN_EXAMPLES="shfArahZT9Q9ckTf3s1psJ7C7qzVN"
# Environment variable names that hold credentials (value presence is reported, never the value).
# NAME_FILE=/path variables (Docker's convention for file-based secrets) are pointers, not values: not flagged.
ENV_NAME_RX='(SEED|SECRET|TOKEN|PASSW|PRIVATE|API_?KEY|NTFY|WEBHOOK)'

JSON=0 ONLY="" SHOW_PATHS=0 PROBE="" LABEL=target
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --only) ONLY="${2:?--only needs a prefix list}"; shift ;;
    --list) tr -s ' \n' '\n' <<<"$CHECK_IDS"; exit 0 ;;
    --show-paths) SHOW_PATHS=1 ;;
    --probe) PROBE="${2:?--probe needs a host}"; shift ;;
    --label) LABEL="${2:?--label needs a name}"; shift ;;
    -h|--help) sed -n '4,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done

NP=0 NW=0 NF=0 NI=0
RESULTS=()
want() {
  [ -z "$ONLY" ] && return 0
  local p
  IFS=',' read -ra ps <<<"$ONLY"
  for p in "${ps[@]}"; do [[ "$1" == "$p"* ]] && return 0; done
  return 1
}
jesc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
# res STATUS ID MESSAGE [HINT]
res() {
  local st="$1" id="$2" msg="$3" hint="${4:-}"
  want "$id" || return 0
  case "$st" in PASS) NP=$((NP + 1)) ;; WARN) NW=$((NW + 1)) ;; FAIL) NF=$((NF + 1)) ;; INFO) NI=$((NI + 1)) ;; esac
  RESULTS+=("{\"id\":\"$id\",\"status\":\"$st\",\"message\":\"$(jesc "$msg")\",\"hint\":\"$(jesc "$hint")\"}")
  if [ "$JSON" -eq 0 ]; then
    printf '  [%s] %-20s %s\n' "$st" "$id" "$msg"
    [ -n "$hint" ] && [ "$st" != PASS ] && [ "$st" != INFO ] && printf '         %-20s fix: %s\n' "" "$hint"
  fi
  return 0
}
section() {
  local t="$1" p; shift
  [ "$JSON" -eq 0 ] || return 0
  for p in "$@"; do want "$p" && { printf '%s\n' "-- $t"; return 0; }; done
  return 0
}
finish() {
  local rc=0
  [ "$NW" -gt 0 ] && rc=1
  [ "$NF" -gt 0 ] && rc=2
  if [ "$JSON" -eq 1 ]; then
    printf '{"time":"%s","os":"%s","mode":"%s","pass":%d,"warn":%d,"fail":%d,"info":%d,"exit":%d,"results":[%s]}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(jesc "$OS_NAME")" "$1" "$NP" "$NW" "$NF" "$NI" "$rc" \
      "$(IFS=,; echo "${RESULTS[*]}")"
  else
    echo "RESULT: $NP pass, $NW warn, $NF fail, $NI info -> exit $rc"
  fi
  exit "$rc"
}
# mask user names in home paths unless --show-paths
mp() { if [ "$SHOW_PATHS" -eq 1 ]; then printf '%s' "$1"; else sed -E 's#^/home/[^/]+#/home/<user>#' <<<"$1"; fi; }
# count SECRET_RX matches on stdin / in a (possibly gzipped) file, ignoring KNOWN_EXAMPLES
nmatch() { grep -oP -- "$SECRET_RX" | grep -cvxF -- "$KNOWN_EXAMPLES"; }
nsecret() {
  case "$1" in
    *.gz) zcat -- "$1" 2>/dev/null | nmatch ;;
    *) nmatch <"$1" 2>/dev/null ;;
  esac
}
OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"

# ---------- remote probe mode ----------
if [ -n "$PROBE" ]; then
  # one TCP connect per port: 0 open, 1 refused, 124 no answer within 3s (filtered)
  # shellcheck disable=SC2016  # $0/$1 are expanded by the inner bash
  tcp1() { timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$PROBE" "$1" 2>/dev/null; }
  pstate() { tcp1 "$1"; case $? in 0) echo open ;; 124) echo filtered ;; *) echo closed ;; esac; }
  [ "$JSON" -eq 0 ] && {
    echo "Post Fiat secrets/exposure probe - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "OS: $OS_NAME | probing: $LABEL | one TCP connect per port, nothing sent"
  }
  section "Reachability from this host" probe.
  open=() det=()
  for p in "${ADMIN_PORTS[@]}"; do s="$(pstate "$p")"; det+=("$p=$s"); [ "$s" = open ] && open+=("$p"); done
  if [ "${#open[@]}" -eq 0 ]; then
    res PASS probe.admin_ports "$LABEL: admin/RPC ports not reachable (${det[*]})"
  else
    res FAIL probe.admin_ports "$LABEL: admin/RPC port(s) reachable from outside: ${open[*]} (${det[*]})" \
      "publish admin/RPC ports on 127.0.0.1 only (compose \"127.0.0.1:5005:5005\") and keep ufw default deny"
  fi
  s="$(pstate "$PEER_PORT")"
  [ "$s" = open ] && res PASS probe.peer_port "$LABEL: peer port $PEER_PORT open (expected)" ||
    res WARN probe.peer_port "$LABEL: peer port $PEER_PORT $s" "allow $PEER_PORT/tcp in ufw / DOCKER-USER so peers can connect"
  finish probe
fi

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo): checks read root-only files and docker" >&2; exit 3; }

# ---------- facts ----------
HAVE_DOCKER=0; command -v docker >/dev/null && docker info >/dev/null 2>&1 && HAVE_DOCKER=1
if [ -z "${CONTAINER:-}" ] && [ "$HAVE_DOCKER" -eq 1 ]; then
  CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /postfiatd/ {print $1; exit}')"
fi
CONTAINER="${CONTAINER:-}"
cinsp() { docker inspect -f "$1" "$CONTAINER" 2>/dev/null; }
# node dir: COMPOSE_DIR, else the compose project dir of the container, else /opt/<container>, else /opt/postfiatd
if [ -z "${COMPOSE_DIR:-}" ] && [ -n "$CONTAINER" ]; then
  COMPOSE_DIR="$(cinsp '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  [ -z "$COMPOSE_DIR" ] && [ -d "/opt/$CONTAINER" ] && COMPOSE_DIR="/opt/$CONTAINER"
fi
COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
CFG="" CFG_DIR="" LOG_DIR="" NETMODE=""
if [ -n "$CONTAINER" ]; then
  CFG="$(docker exec "$CONTAINER" cat /etc/postfiatd/postfiatd.cfg 2>/dev/null)"
  CFG_DIR="$(cinsp '{{range .Mounts}}{{if eq .Destination "/etc/postfiatd"}}{{.Source}}{{end}}{{end}}')"
  LOG_DIR="$(cinsp '{{range .Mounts}}{{if eq .Destination "/var/log/postfiatd"}}{{.Source}}{{end}}{{end}}')"
  NETMODE="$(cinsp '{{.HostConfig.NetworkMode}}')"
else
  for d in /etc/postfiatd /opt/postfiatd/etc; do [ -f "$d/postfiatd.cfg" ] && { CFG_DIR="$d"; CFG="$(cat "$d/postfiatd.cfg")"; break; }; done
  [ -d /var/log/postfiatd ] && LOG_DIR=/var/log/postfiatd
fi
cfg_section() { awk -v s="[$1]" '$0==s {f=1; next} /^\[/ {f=0} f && NF && $1 !~ /^#/' <<<"$CFG"; }
cfg_kv() { cfg_section "$1" | awk -F'=' -v k="$2" '{gsub(/[ \t]/, "", $1)} $1==k {v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit}'; }
is_loop() { [[ "$1" =~ ^(127\.[0-9.]+|::1|\[::1\]|localhost)$ ]]; }
# host addresses a container port is reachable on (empty = not published)
host_binds() {
  local port="$1" ip="$2"
  if [ -z "$CONTAINER" ] || [ "$NETMODE" = host ]; then echo "$ip"; return; fi
  docker port "$CONTAINER" "$port/tcp" 2>/dev/null | sed -E 's/:[0-9]+$//' | sort -u
}

[ "$JSON" -eq 0 ] && {
  echo "Post Fiat secrets/exposure check - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "OS: $OS_NAME | container: ${CONTAINER:-none} | network: ${NETMODE:-n/a}"
}

# ---------- postfiatd.cfg ----------
section "postfiatd.cfg ports and secrets" cfg.
if [ -z "$CFG" ]; then
  res WARN cfg.admin_roles "postfiatd.cfg not found/readable; port checks skipped" "set CONTAINER= or run on the node host"
else
  bad_roles=() admin_pub=() rpc_pub=() wide=() summary=()
  for sec in $(cfg_section server); do
    port="$(cfg_kv "$sec" port)" ip="$(cfg_kv "$sec" ip)" proto="$(cfg_kv "$sec" protocol)"
    adm="$(cfg_kv "$sec" admin)" gw="$(cfg_kv "$sec" secure_gateway)"
    [ -n "$port" ] || continue
    for a in ${adm//,/ } ${gw//,/ }; do is_loop "$a" || bad_roles+=("$sec:$a"); done
    pub=""
    while read -r b; do [ -n "$b" ] && ! is_loop "$b" && pub="$b"; done < <(host_binds "$port" "${ip:-0.0.0.0}")
    summary+=("$sec(${proto:-?}/$port ${pub:+public}${pub:-local}${adm:+ admin})")
    if [ "$proto" = peer ]; then :
    elif [ -n "$pub" ] && { [ -n "$adm" ] || [ -n "$gw" ]; }; then admin_pub+=("$sec:$port")
    elif [ -n "$pub" ]; then rpc_pub+=("$sec:$port")
    fi
    [ -n "$CONTAINER" ] && [ "$NETMODE" != host ] && ! is_loop "${ip:-0.0.0.0}" && [ "$proto" != peer ] && wide+=("$sec:$port")
  done
  # port_grpc is not always listed in [server]
  gport="$(cfg_kv port_grpc port)" gip="$(cfg_kv port_grpc ip)" ggw="$(cfg_kv port_grpc secure_gateway)"
  if [ -n "$gport" ] && ! grep -qx port_grpc <<<"$(cfg_section server)"; then
    for a in ${ggw//,/ }; do is_loop "$a" || bad_roles+=("port_grpc:$a"); done
    while read -r b; do [ -n "$b" ] && ! is_loop "$b" && admin_pub+=("port_grpc:$gport"); done < <(host_binds "$gport" "${gip:-0.0.0.0}")
  fi
  [ "${#bad_roles[@]}" -eq 0 ] && res PASS cfg.admin_roles "admin=/secure_gateway= grant only loopback" ||
    res FAIL cfg.admin_roles "admin role granted to non-loopback sources: ${bad_roles[*]}" \
      "set admin = 127.0.0.1 (and secure_gateway = 127.0.0.1) in every port section"
  [ "${#admin_pub[@]}" -eq 0 ] && res PASS cfg.admin_exposure "no admin port reachable on a public host address" ||
    res FAIL cfg.admin_exposure "admin port(s) reachable on a public host address: ${admin_pub[*]}" \
      "publish admin ports as 127.0.0.1:PORT:PORT (Docker) or set ip = 127.0.0.1"
  [ "${#rpc_pub[@]}" -eq 0 ] && res PASS cfg.rpc_exposure "no public RPC/WS port (${summary[*]})" ||
    res WARN cfg.rpc_exposure "non-admin RPC/WS port(s) public: ${rpc_pub[*]}" \
      "bind to 127.0.0.1 unless you deliberately run a public RPC node (then rate-limit it)"
  if [ "${#wide[@]}" -eq 0 ]; then
    res PASS cfg.container_bind "RPC/WS sections bind loopback inside the container"
  else
    others="$(docker network inspect "$NETMODE" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' | grep -vx "$CONTAINER" | grep -c .)"
    [ "${others:-0}" -eq 0 ] &&
      res PASS cfg.container_bind "${wide[*]} bind 0.0.0.0 inside the container (needed for Docker publishing); no other container on network $NETMODE" ||
      res WARN cfg.container_bind "${wide[*]} reachable from $others other container(s) on network $NETMODE" \
        "move other containers to their own network, or keep postfiatd on a dedicated compose network"
  fi
  secs=() ; for s in validator_token validation_seed; do grep -qx "\[$s\]" <<<"$CFG" && secs+=("[$s]"); done
  # every file in the config dir (incl. copies like postfiatd.cfg.pre-*) that carries a secret section
  holders=() loose=()
  if [ -n "$CFG_DIR" ] && [ -d "$CFG_DIR" ]; then
    while IFS= read -r -d '' f; do
      grep -qE '^\[(validator_token|validation_seed)\]' "$f" 2>/dev/null || continue
      m="$(stat -c '%a %U' "$f")"; holders+=("$(basename "$f") $m")
      [ $((8#$(stat -c %a "$f") & 8#077)) -ne 0 ] && loose+=("$(basename "$f") $m")
    done < <(find "$CFG_DIR" -maxdepth 1 -type f -print0)
    dm="$(stat -c '%a' "$CFG_DIR")"
  fi
  if [ "${#secs[@]}" -eq 0 ] && [ "${#holders[@]}" -eq 0 ]; then
    res INFO cfg.secret_sections "no [validator_token]/[validation_seed] in the config dir (node is not a validator yet)"
  elif [ "${#loose[@]}" -gt 0 ]; then
    res FAIL cfg.secret_sections "secret section present (${secs[*]:-copies only}); readable beyond owner: ${loose[*]}" \
      "chmod 600 the listed files in the config volume; delete stale copies that hold the token"
  else
    res PASS cfg.secret_sections "secret section present (${secs[*]:-copies only}); files ${holders[*]}; dir ${dm:-?} (values not shown)"
  fi
fi

# ---------- validator key files ----------
section "Validator key files" keys.
kf=() kbad=()
while IFS= read -r -d '' f; do
  m="$(stat -c '%a %U' "$f")"; kf+=("$(mp "$f") $m")
  [ $((8#$(stat -c %a "$f") & 8#077)) -ne 0 ] && kbad+=("$(mp "$f") $m")
done < <(find /root /home /opt /etc /srv -maxdepth 5 -type f -name 'validator-keys*.json' -print0 2>/dev/null)
if [ "${#kf[@]}" -eq 0 ]; then res INFO keys.validator_keys "no validator-keys.json on this host (keep it offline)"
elif [ "${#kbad[@]}" -gt 0 ]; then res FAIL keys.validator_keys "validator-keys.json readable beyond owner: ${kbad[*]}" \
  "chmod 600, and better: move the master key file off the server"
else res WARN keys.validator_keys "validator-keys.json present online: ${kf[*]}" "keep the master key offline; only the token belongs on the server"
fi

# ---------- leakage paths ----------
section "Secret leakage paths" leak.
if [ "$HAVE_DOCKER" -eq 1 ]; then
  envhit=() strong=()
  for c in $(docker ps --format '{{.Names}}'); do
    names="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E "^[A-Za-z_]*${ENV_NAME_RX}[A-Za-z_]*=." | grep -vE '^[A-Za-z_]+_FILE=/' | cut -d= -f1 | tr '\n' ' ')"
    [ -n "$names" ] && envhit+=("$c:${names% }")
    n="$(docker inspect -f '{{json .Config.Env}}{{json .Config.Cmd}}{{json .Config.Entrypoint}}{{json .Args}}{{json .Config.Labels}}' "$c" | nmatch)"
    [ "$n" -gt 0 ] && strong+=("$c")
  done
  if [ "${#strong[@]}" -gt 0 ]; then
    res FAIL leak.docker_env "secret-format value in docker inspect (env/cmd/args/labels) of: ${strong[*]}" \
      "remove it from the run command/compose file; mount a 0400 file instead and recreate the container"
  elif [ "${#envhit[@]}" -gt 0 ]; then
    res WARN leak.docker_env "credential-named env vars visible via docker inspect: ${envhit[*]}" \
      "pass the value as a read-only mounted file (mode 0400, owned by the container user) instead of -e/--env-file"
  else
    res PASS leak.docker_env "no credential-named env vars or secret-format values in docker inspect ($(docker ps -q | wc -l) containers)"
  fi
  if [ -n "$CONTAINER" ]; then
    n="$(docker logs --tail "$LOG_TAIL" "$CONTAINER" 2>&1 | nmatch)"
    [ "$n" -eq 0 ] && res PASS leak.container_logs "no secret-format strings in last $LOG_TAIL lines of docker logs $CONTAINER" ||
      res FAIL leak.container_logs "$n match(es) of secret-format strings in docker logs $CONTAINER" \
        "rotate the exposed key; recreate the container to drop its json log"
  fi
else
  res INFO leak.docker_env "docker not available; container checks skipped"
fi

if [ -n "$LOG_DIR" ] && [ -d "$LOG_DIR" ]; then
  hits=() nf=0
  while IFS= read -r -d '' f; do
    nf=$((nf + 1)); n="$(nsecret "$f")"; [ "${n:-0}" -gt 0 ] && hits+=("$(basename "$f"):$n")
  done < <(find "$LOG_DIR" -maxdepth 1 -type f \( -name 'debug.log*' -o -name '*.log' -o -name '*.gz' \) -print0)
  [ "${#hits[@]}" -eq 0 ] && res PASS leak.debug_log "no secret-format strings in $nf node log file(s)" ||
    res FAIL leak.debug_log "secret-format strings in node logs: ${hits[*]}" \
      "rotate the exposed key, then delete or truncate the affected log files"
else
  res INFO leak.debug_log "node log dir not found; skipped"
fi

hh=() hm=() nh=0
while IFS= read -r -d '' f; do
  nh=$((nh + 1)); owner="$(stat -c %U "$f")" mode="$(stat -c %a "$f")"
  n="$(nsecret "$f")"; [ "${n:-0}" -gt 0 ] && hh+=("$(mp "$f"):$n")
  [ $((8#$mode & 8#077)) -ne 0 ] && hm+=("$(mp "$f") $mode $owner")
done < <(find /root /home -maxdepth 2 -type f \( -name '.*history' -o -name '.*_hist' \) -print0 2>/dev/null)
if [ "${#hh[@]}" -gt 0 ]; then
  res FAIL leak.shell_history "secret-format strings in shell/REPL history: ${hh[*]}" \
    "rotate the exposed secret, delete the lines (history -d / edit the file), start commands with a space (HISTCONTROL=ignorespace)"
elif [ "${#hm[@]}" -gt 0 ]; then
  res WARN leak.shell_history "history files readable beyond owner: ${hm[*]}" "chmod 600 the listed files"
else
  res PASS leak.shell_history "$nh history file(s): no secret-format strings, all owner-only"
fi

wr=() wn=() ww=() roots=("$COMPOSE_DIR"); [ -n "$CFG_DIR" ] && roots+=("$CFG_DIR")
existing=(); for r in "${roots[@]}"; do [ -d "$r" ] && existing+=("$r"); done
if [ "${#existing[@]}" -gt 0 ]; then
  # world-writable files anywhere in the node dirs; world-readable files that look like (or contain) secrets
  while IFS= read -r -d '' f; do ww+=("$(mp "$f")"); done < <(find "${existing[@]}" -xdev -type f -perm -o+w -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    n="$(nsecret "$f")"
    if [ "${n:-0}" -gt 0 ]; then wr+=("$(mp "$f"):$n"); continue; fi
    case "$(basename "$f")" in *.env|*secret*|*token*|*seed*|*.key|*.pem|*pass*) wn+=("$(mp "$f")") ;; esac
  done < <(find "${existing[@]}" -xdev -type f -perm -o+r -size -20M -print0 2>/dev/null)
  if [ "${#ww[@]}" -gt 0 ] || [ "${#wr[@]}" -gt 0 ]; then
    res FAIL leak.world_readable "world-writable: ${ww[*]:-none}; world-readable secret files: ${wr[*]:-none}" \
      "chmod o-rwx the listed files (600 for secrets); remove planted/unused copies"
  elif [ "${#wn[@]}" -gt 0 ]; then
    res WARN leak.world_readable "world-readable files with credential-style names (no secret found inside): ${wn[*]}" \
      "chmod 600 them so a credential added later is not exposed"
  else
    res PASS leak.world_readable "no world-writable files and no world-readable secret files under ${#existing[@]} node dir(s)"
  fi
fi

if [ -d "$BACKUP_DIR" ]; then
  bdm="$(stat -c '%a %U' "$BACKUP_DIR")" bl=() plain=() total=0
  while IFS= read -r -d '' f; do
    total=$((total + 1)); m="$(stat -c '%a' "$f")" o="$(stat -c '%U' "$f")"
    { [ $((8#$m & 8#077)) -ne 0 ] || [ "$o" != root ]; } && bl+=("$(basename "$f") $m $o")
    case "$f" in *.tar.gz|*.tgz)
      tar -xzOf "$f" --wildcards '*postfiatd.cfg' 2>/dev/null | grep -qE '^\[(validator_token|validation_seed)\]' && plain+=("$(basename "$f")") ;;
    esac
  done < <(find "$BACKUP_DIR" -type f -print0)
  if [ "${#bl[@]}" -gt 0 ] || [ $((8#${bdm% *} & 8#077)) -ne 0 ]; then
    res FAIL leak.backups "backup dir $bdm; files readable beyond root: ${bl[*]:-none}" "chmod 700 the dir and 600 root every archive"
  elif [ "${#plain[@]}" -gt 0 ]; then
    res WARN leak.backups "${#plain[@]} unencrypted archive(s) contain a validator token: ${plain[*]}" \
      "encrypt backups (backup/ add-on: gpg passphrase file) and delete the plaintext copies"
  else
    res PASS leak.backups "backup dir $bdm, $total file(s) all 600-or-stricter root; no plaintext archive holds a token"
  fi
else
  res INFO leak.backups "no backup dir at $BACKUP_DIR"
fi

finish local
