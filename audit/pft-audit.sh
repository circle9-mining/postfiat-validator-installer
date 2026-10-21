#!/usr/bin/env bash
# res() always returns 0, so `test && res PASS ... || res WARN ...` never runs both branches.
# shellcheck disable=SC2015
# pft-audit: read-only security audit of a Post Fiat validator or sentry host.
#
# Prints one PASS/WARN/FAIL/INFO line per check with the reason and, for WARN/FAIL, a fix hint.
# It never changes anything on the host. Output contains no IP addresses, usernames or secrets.
#
# Exit codes: 0 all checks PASS (INFO ignored), 1 at least one WARN, 2 at least one FAIL, 3 usage error.
#
# Usage: sudo ./pft-audit.sh [--json] [--only PREFIX[,PREFIX...]] [--list]
#   --json   print a JSON summary instead of text lines
#   --only   run only checks whose id starts with one of the prefixes (e.g. --only fw.,files.)
#   --list   print the check ids and exit
# Env:   CONTAINER (auto: first running agtipft/postfiatd container)  PEER_PORT (2559)
#        COMPOSE_DIR (/opt/postfiatd)  BACKUP_DIR (/var/backups/postfiat)

set -uo pipefail

PEER_PORT="${PEER_PORT:-2559}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/postfiat}"
ADMIN_PORTS=(5005 6005 6006 50051)
CHECK_IDS="ssh.root_login ssh.password_auth ssh.empty_passwords ssh.x11_forwarding ssh.max_auth_tries
ports.admin_loopback ports.public_listeners fw.ufw_active fw.ufw_peer_limit fw.docker_user_limit
fw.docker_bypass docker.socket docker.group container.privileged container.capabilities
container.network container.no_new_privileges container.restart container.log_rotation container.user
files.node_config files.monitor_env files.sshd_config files.authorized_keys files.backups
patch.unattended patch.pending_security patch.reboot time.ntp node.state node.peers
relay.mode relay.sentry_upstream relay.sentry_http relay.validator_private relay.validator_fw"

JSON=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --only) ONLY="${2:?--only needs a prefix list}"; shift ;;
    --list) tr -s ' \n' '\n' <<<"$CHECK_IDS"; exit 0 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo): several checks read root-only files" >&2; exit 3; }

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
    printf '  [%s] %-26s %s\n' "$st" "$id" "$msg"
    [ -n "$hint" ] && [ "$st" != PASS ] && [ "$st" != INFO ] && printf '         %-26s fix: %s\n' "" "$hint"
  fi
  return 0
}
section() {
  local t="$1" p; shift
  [ "$JSON" -eq 0 ] || return 0
  for p in "$@"; do want "$p" && { printf '%s\n' "-- $t"; return 0; }; done
  return 0
}

# ---------- facts ----------
OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
SSHD="$(sshd -T 2>/dev/null)"
sshv() { awk -v k="$1" '$1==k {print $2; exit}' <<<"$SSHD"; }
SSH_PORT="$(sshv port)"; SSH_PORT="${SSH_PORT:-22}"
LISTEN="$(ss -ltnpH 2>/dev/null)"
HAVE_DOCKER=0; command -v docker >/dev/null && docker info >/dev/null 2>&1 && HAVE_DOCKER=1
if [ -z "${CONTAINER:-}" ] && [ "$HAVE_DOCKER" -eq 1 ]; then
  CONTAINER="$(docker ps --filter ancestor=agtipft/postfiatd --format '{{.Names}}' | head -1)"
  [ -n "$CONTAINER" ] || CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /postfiatd/ {print $1; exit}')"
fi
CONTAINER="${CONTAINER:-}"
cinsp() { docker inspect -f "$1" "$CONTAINER" 2>/dev/null; }
CFG=""
[ -n "$CONTAINER" ] && CFG="$(docker exec "$CONTAINER" cat /etc/postfiatd/postfiatd.cfg 2>/dev/null)"
cfg_section() { awk -v s="[$1]" '$0==s {f=1; next} /^\[/ {f=0} f && NF && $1 !~ /^#/' <<<"$CFG"; }
SENTRY_CONF="$(grep -rlsE "listen[[:space:]]+${PEER_PORT}\b" /etc/nginx/streams.d /etc/nginx/conf.d /etc/nginx/nginx.conf 2>/dev/null | head -1)"
if [ -n "$SENTRY_CONF" ]; then ROLE=sentry
elif [ "$(cfg_section peer_private | head -1)" = 1 ] && [ -n "$(cfg_section ips_fixed)" ]; then ROLE=validator-behind-sentry
else ROLE=standalone; fi
# who serves the peer port: docker-proxy (published container port) or a host process (nginx)
PEER_OWNER="$(awk -v p=":${PEER_PORT}" '$4 ~ p"$" && $4 !~ /^127\./ {print $6; exit}' <<<"$LISTEN" | grep -oE '"[^"]+"' | head -1 | tr -d '"')"

[ "$JSON" -eq 0 ] && {
  echo "Post Fiat host audit - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "OS: $OS_NAME | kernel: $(uname -r) | role: $ROLE | container: ${CONTAINER:-none}"
}

# ---------- SSH ----------
section "SSH (effective sshd -T config)" ssh.
if [ -z "$SSHD" ]; then
  res WARN ssh.root_login "sshd -T returned nothing; SSH config not audited" "run as root on a host with openssh-server"
else
  prl="$(sshv permitrootlogin)" pwa="$(sshv passwordauthentication)"
  if [ "$prl" = yes ] && [ "$pwa" = yes ]; then
    res FAIL ssh.root_login "root may log in with a password (PermitRootLogin yes + PasswordAuthentication yes)" \
      "install a key for root/an admin user, then set PermitRootLogin prohibit-password"
  elif [ "$prl" = yes ]; then
    res WARN ssh.root_login "PermitRootLogin yes (keys only, since password auth is off)" "set PermitRootLogin prohibit-password or no"
  else
    res PASS ssh.root_login "PermitRootLogin $prl"
  fi
  [ "$pwa" = no ] && res PASS ssh.password_auth "password authentication disabled" ||
    res WARN ssh.password_auth "password authentication enabled (brute-force target)" \
      "after confirming key login works, set PasswordAuthentication no (check sshd_config.d/ overrides: first value wins)"
  [ "$(sshv permitemptypasswords)" = yes ] && res FAIL ssh.empty_passwords "PermitEmptyPasswords yes" "set PermitEmptyPasswords no" ||
    res PASS ssh.empty_passwords "empty passwords refused"
  [ "$(sshv x11forwarding)" = yes ] && res WARN ssh.x11_forwarding "X11Forwarding yes (not needed on a server)" "set X11Forwarding no" ||
    res PASS ssh.x11_forwarding "X11 forwarding off"
  mat="$(sshv maxauthtries)"
  [ "${mat:-6}" -le 4 ] && res PASS ssh.max_auth_tries "MaxAuthTries $mat" ||
    res WARN ssh.max_auth_tries "MaxAuthTries ${mat:-6} (>4)" "set MaxAuthTries 3"
fi

# ---------- ports ----------
section "Listening ports" ports.
bad=() ok=()
for p in "${ADMIN_PORTS[@]}"; do
  lines="$(awk -v p=":$p" '$4 ~ p"$" {print $4}' <<<"$LISTEN")"
  [ -z "$lines" ] && continue
  if grep -qvE '^(127\.|\[::1\]|::1)' <<<"$lines"; then bad+=("$p"); else ok+=("$p"); fi
done
if [ "${#bad[@]}" -gt 0 ]; then
  res FAIL ports.admin_loopback "admin/RPC port(s) ${bad[*]} listen on a non-loopback address" \
    "bind them to 127.0.0.1 in the compose file (\"127.0.0.1:5005:5005\") and recreate the container"
elif [ "${#ok[@]}" -gt 0 ]; then
  res PASS ports.admin_loopback "admin/RPC port(s) ${ok[*]} loopback only"
else
  res INFO ports.admin_loopback "no admin/RPC port published on the host"
fi
extra="$(awk '$4 !~ /^(127\.|\[::1\]|::1|127\.0\.0\.53%lo)/ {n=split($4,a,":"); print a[n]}' <<<"$LISTEN" |
  grep -vxE "${SSH_PORT}|${PEER_PORT}" | sort -un | paste -sd, -)"
[ -z "$extra" ] && res PASS ports.public_listeners "only SSH ($SSH_PORT) and peer ($PEER_PORT) listen on public addresses" ||
  res WARN ports.public_listeners "extra non-loopback listener(s) on port(s): $extra" \
    "stop/disable the service or bind it to 127.0.0.1; a default-deny firewall alone is one mistake away from exposure"

# ---------- firewall ----------
section "Firewall" fw.
if ! command -v ufw >/dev/null; then
  res FAIL fw.ufw_active "ufw not installed" "apt-get install ufw; allow SSH, limit $PEER_PORT/tcp, ufw enable"
else
  UFW="$(ufw status verbose 2>/dev/null)"
  if grep -q '^Status: active' <<<"$UFW" && grep -q 'deny (incoming)' <<<"$UFW"; then
    res PASS fw.ufw_active "ufw active, default deny incoming"
  else
    res FAIL fw.ufw_active "ufw inactive or default incoming policy is not deny" "ufw default deny incoming && ufw enable"
  fi
  prules="$(grep -E "^${PEER_PORT}/tcp" <<<"$UFW")"
  if [ "$ROLE" = validator-behind-sentry ]; then
    res INFO fw.ufw_peer_limit "peer port rules evaluated by relay.validator_fw"
  elif grep -q 'LIMIT IN' <<<"$prules"; then
    res PASS fw.ufw_peer_limit "ufw LIMIT on $PEER_PORT/tcp"
  elif grep -q 'ALLOW IN' <<<"$prules"; then
    res WARN fw.ufw_peer_limit "ufw ALLOW (no rate limit) on $PEER_PORT/tcp" "ufw limit $PEER_PORT/tcp, then delete the allow rule"
  else
    res WARN fw.ufw_peer_limit "no ufw rule for $PEER_PORT/tcp (peers cannot reach the node if it is meant to be public)" \
      "ufw limit $PEER_PORT/tcp"
  fi
fi
DU="$(iptables -S DOCKER-USER 2>/dev/null)"
if [ "$PEER_OWNER" = docker-proxy ]; then
  if grep -q -- "--dport $PEER_PORT .*connlimit" <<<"$DU" && grep -q -- "--dport $PEER_PORT .*-m limit" <<<"$DU"; then
    res PASS fw.docker_user_limit "DOCKER-USER connlimit + rate limit on $PEER_PORT (Docker-published ports bypass ufw)"
  elif grep -q -- "--dport $PEER_PORT .*-s " <<<"$DU"; then
    res PASS fw.docker_user_limit "DOCKER-USER restricts $PEER_PORT to fixed source address(es)"
  else
    res FAIL fw.docker_user_limit "$PEER_PORT is published by Docker but DOCKER-USER has no limit for it; ufw rules do not apply" \
      "systemctl restart postfiat-docker-user (installer) or add connlimit/limit rules to DOCKER-USER"
  fi
else
  res INFO fw.docker_user_limit "peer port served by ${PEER_OWNER:-nothing public}; DOCKER-USER limit not required"
fi
if [ "$HAVE_DOCKER" -eq 1 ]; then
  # shellcheck disable=SC2016  # Go template, not shell expansion
  pub="$(docker ps -q | xargs -r docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}={{.HostIp}} {{end}}{{end}}' 2>/dev/null |
    tr ' ' '\n' | awk -F= -v pp="${PEER_PORT}/tcp" 'NF==2 && $1!=pp && $2!~/^(127\.|::1)/ {print $1}' | sort -u | paste -sd, -)"
  [ -z "$pub" ] && res PASS fw.docker_bypass "no container port other than $PEER_PORT published on a public address" ||
    res FAIL fw.docker_bypass "container port(s) $pub published on all interfaces (bypasses ufw)" "bind them to 127.0.0.1"
fi

# ---------- docker ----------
section "Docker daemon and container" docker.
if [ "$HAVE_DOCKER" -eq 0 ]; then
  res FAIL docker.socket "docker not running; container checks skipped" "systemctl enable --now docker"
else
  sp="$(stat -c '%a %U:%G' /var/run/docker.sock)"
  [[ "$sp" == 660\ root:* ]] && res PASS docker.socket "docker.sock $sp" ||
    res FAIL docker.socket "docker.sock permissions $sp" "chmod 660 /var/run/docker.sock (owner root, group docker)"
  members="$(getent group docker | cut -d: -f4)"
  n=0; [ -n "$members" ] && n="$(tr ',' '\n' <<<"$members" | grep -c .)"
  res INFO docker.group "$n non-root account(s) in the docker group (each is root-equivalent; keep it to admins)"
  if [ -z "$CONTAINER" ]; then
    res FAIL container.privileged "no running postfiatd container found" "start the node (docker compose up -d) or set CONTAINER="
  else
    [ "$(cinsp '{{.HostConfig.Privileged}}')" = true ] && res FAIL container.privileged "container runs --privileged" "remove privileged: true" ||
      res PASS container.privileged "not privileged"
    ca="$(cinsp '{{join .HostConfig.CapAdd ","}}')"
    [ -z "$ca" ] && res PASS container.capabilities "no added capabilities" ||
      res WARN container.capabilities "added capabilities: $ca" "drop cap_add unless the image documents a need"
    nm="$(cinsp '{{.HostConfig.NetworkMode}}')"
    [ "$nm" = host ] && res WARN container.network "host network mode (admin ports bind on the host directly)" "use a bridge network with loopback port bindings" ||
      res PASS container.network "network mode $nm"
    grep -q 'no-new-privileges' <<<"$(cinsp '{{json .HostConfig.SecurityOpt}}')" &&
      res PASS container.no_new_privileges "no-new-privileges set" ||
      res WARN container.no_new_privileges "no-new-privileges not set (setuid binaries in the image could raise privileges)" \
        "compose: security_opt: [\"no-new-privileges:true\"] (or docker run --security-opt no-new-privileges)"
    rp="$(cinsp '{{.HostConfig.RestartPolicy.Name}}')"
    case "$rp" in always|unless-stopped) res PASS container.restart "restart policy $rp" ;;
      *) res WARN container.restart "restart policy '${rp:-none}': node stays down after a crash or reboot" "restart: unless-stopped" ;; esac
    ld="$(cinsp '{{.HostConfig.LogConfig.Type}}')" lms="$(cinsp '{{index .HostConfig.LogConfig.Config "max-size"}}')"
    if [ "$ld" = json-file ] && { [ -z "$lms" ] || [ "$lms" = "<no value>" ]; }; then
      res WARN container.log_rotation "json-file logging without max-size (unbounded disk growth)" \
        "--log-opt max-size=100m --log-opt max-file=10, or a daemon.json default"
    else
      res PASS container.log_rotation "log driver $ld${lms:+ max-size=$lms}"
    fi
    u="$(cinsp '{{.Config.User}}')"
    res INFO container.user "container user '${u:-image default}' (the official image runs postfiatd as root; mitigated by no-new-privileges, no caps, loopback admin ports)"
  fi
fi

# ---------- files ----------
section "File permissions" files.
if [ -n "$CFG" ]; then
  mode="$(docker exec "$CONTAINER" stat -c '%a' /etc/postfiatd/postfiatd.cfg 2>/dev/null)"
  if grep -qE '^\[(validator_token|validation_seed|node_seed)\]' <<<"$CFG"; then
    [[ "$mode" =~ ^[0-7][04]0$ ]] && res PASS files.node_config "postfiatd.cfg holds secrets, mode $mode" ||
      res FAIL files.node_config "postfiatd.cfg holds a token/seed and is mode $mode" "chmod 600 /etc/postfiatd/postfiatd.cfg (inside the volume)"
  else
    res PASS files.node_config "postfiatd.cfg mode $mode, no token/seed sections"
  fi
fi
if [ -f /etc/postfiat-monitor.env ]; then
  m="$(stat -c '%a %U' /etc/postfiat-monitor.env)"
  [ "$m" = "600 root" ] && res PASS files.monitor_env "/etc/postfiat-monitor.env $m" ||
    res FAIL files.monitor_env "/etc/postfiat-monitor.env is $m (holds the ntfy topic/token)" "chown root /etc/postfiat-monitor.env && chmod 600 /etc/postfiat-monitor.env"
fi
m="$(stat -c '%a %U' /etc/ssh/sshd_config)"
[[ "$m" =~ ^[0-7][0-7][0-5]\ root$ ]] && [[ ! "$m" =~ ^[0-7][2367] ]] && res PASS files.sshd_config "sshd_config $m" ||
  res FAIL files.sshd_config "sshd_config $m (writable by non-root)" "chown root /etc/ssh/sshd_config && chmod 644 /etc/ssh/sshd_config"
badk=0
while IFS=: read -r _ _ _ _ _ home _; do
  for f in "$home/.ssh/authorized_keys" "$home/.ssh"; do
    [ -e "$f" ] || continue
    [ -n "$(find "$f" -maxdepth 0 -perm /022)" ] && badk=$((badk + 1))
  done
done < /etc/passwd
[ "$badk" -eq 0 ] && res PASS files.authorized_keys "no group/world-writable .ssh dir or authorized_keys" ||
  res FAIL files.authorized_keys "$badk .ssh dir(s)/authorized_keys file(s) group- or world-writable" "chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
if [ -d "$BACKUP_DIR" ]; then
  wr="$(find "$BACKUP_DIR" -maxdepth 1 \( -perm -004 -o -perm -040 \) -name 'pft-backup-*' | wc -l)"
  bm="$(stat -c '%a' "$BACKUP_DIR")"
  if [ "$wr" -eq 0 ] || [[ "$bm" =~ ^[0-7]00$ ]]; then res PASS files.backups "backup dir mode $bm, archives not exposed"
  else res WARN files.backups "$wr backup archive(s) readable by other users in a mode-$bm dir" "chmod 700 $BACKUP_DIR"; fi
fi

# ---------- patching / time ----------
section "Patching and time" patch. time.
if dpkg -s unattended-upgrades >/dev/null 2>&1 && grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then
  res PASS patch.unattended "unattended-upgrades installed and enabled"
else
  res WARN patch.unattended "unattended security upgrades not enabled" "apt-get install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
fi
ns="$(apt list --upgradable 2>/dev/null | grep -c -- '-security' || true)"
[ "$ns" -eq 0 ] && res PASS patch.pending_security "no pending security updates (cached package lists)" ||
  res WARN patch.pending_security "$ns pending security update(s)" "apt-get update && apt-get upgrade"
if [ -f /var/run/reboot-required ]; then
  res WARN patch.reboot "reboot required to load installed updates ($(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null | cut -c1-80))" \
    "reboot in a maintenance window; the container restarts (restart policy) and postfiat-docker-user re-applies rules"
else
  res PASS patch.reboot "no reboot pending"
fi
[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && res PASS time.ntp "system clock NTP-synchronized" ||
  res FAIL time.ntp "clock not NTP-synchronized (consensus and TLS depend on it)" "timedatectl set-ntp true; check systemd-timesyncd/chrony"

# ---------- node ----------
section "Node" node.
if [ -n "$CONTAINER" ]; then
  INFO_JSON="$(docker exec "$CONTAINER" curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    http://127.0.0.1:5005 -d '{"method":"server_info","params":[{}]}' 2>/dev/null)"
  st="$(grep -o '"server_state":"[^"]*"' <<<"$INFO_JSON" | cut -d'"' -f4)"
  pe="$(grep -o '"peers":[0-9]*' <<<"$INFO_JSON" | head -1 | cut -d: -f2)"
  case "$st" in
    full|proposing|validating) res PASS node.state "server_state $st" ;;
    syncing|tracking|connected) res WARN node.state "server_state $st (not yet full)" "wait; if it persists check peers and disk" ;;
    *) res FAIL node.state "server_state '${st:-no RPC answer}'" "docker logs $CONTAINER; postfiat-health" ;;
  esac
  [ "${pe:-0}" -gt 0 ] && res PASS node.peers "$pe peer(s)" || res FAIL node.peers "0 peers" "check $PEER_PORT reachability / [ips_fixed]"
fi

# ---------- relay mode ----------
section "Relay / sentry mode" relay.
res INFO relay.mode "detected role: $ROLE"
case "$ROLE" in
  sentry)
    up="$(grep -oE 'proxy_pass[[:space:]]+[^;]+' "$SENTRY_CONF" | awk '{print $2}')"
    if [[ "$up" =~ ^127\. ]]; then
      upb="$(awk -v p=":${up##*:}" '$4 ~ p"$" {print $4}' <<<"$LISTEN" | grep -vcE '^127\.' || true)"
      [ "$upb" -eq 0 ] && res PASS relay.sentry_upstream "nginx stream -> loopback upstream; upstream port not public" ||
        res FAIL relay.sentry_upstream "sentry upstream port also listens on a public address" "publish it as 127.0.0.1:${up##*:}"
    else
      res INFO relay.sentry_upstream "nginx stream forwards to a non-loopback upstream (card-literal topology)"
    fi
    if awk '$4 ~ /:(80|443)$/ && $4 !~ /^(127\.|\[::1\])/' <<<"$LISTEN" | grep -q nginx; then
      res WARN relay.sentry_http "nginx also serves HTTP on a public address (default site), not needed for a sentry" \
        "rm /etc/nginx/sites-enabled/default && nginx -t && systemctl reload nginx"
    else
      res PASS relay.sentry_http "nginx serves only the stream relay"
    fi ;;
  validator-behind-sentry)
    res PASS relay.validator_private "[peer_private]=1 with $(cfg_section ips_fixed | grep -c .) [ips_fixed] peer(s)"
    if grep -q -- "--dport $PEER_PORT .*-s " <<<"$DU" && ! grep -E "^${PEER_PORT}/tcp" <<<"${UFW:-}" | grep -q 'Anywhere'; then
      res PASS relay.validator_fw "inbound $PEER_PORT limited to the sentry in ufw and DOCKER-USER"
    else
      res WARN relay.validator_fw "inbound $PEER_PORT not restricted to the sentry in both ufw and DOCKER-USER" "sentry/validator-setup.sh apply"
    fi ;;
  *) res INFO relay.validator_private "standalone node (no sentry); public peer port is expected" ;;
esac

# ---------- summary ----------
RC=0; [ "$NW" -gt 0 ] && RC=1; [ "$NF" -gt 0 ] && RC=2
if [ "$JSON" -eq 1 ]; then
  printf '{"time":"%s","os":"%s","role":"%s","pass":%d,"warn":%d,"fail":%d,"info":%d,"exit":%d,"results":[%s]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(jesc "$OS_NAME")" "$ROLE" "$NP" "$NW" "$NF" "$NI" "$RC" "$(IFS=,; echo "${RESULTS[*]}")"
else
  echo "RESULT: $NP pass, $NW warn, $NF fail, $NI info -> exit $RC"
fi
exit "$RC"
