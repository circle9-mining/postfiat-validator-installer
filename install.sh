#!/usr/bin/env bash
# Hardened Post Fiat testnet validator installer (Ubuntu 22.04+, Docker)
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/circle9-mining/postfiat-validator-installer/main/install.sh | sudo bash
#
# Optional environment overrides (pass after sudo, e.g. `sudo SSH_PORT=2222 bash`):
#   POSTFIATD_DIR   default /opt/postfiatd
#   NETWORK         default testnet
#   SSH_PORT        default: auto-detected from sshd, else 22
#
# What it does:
#   1. Installs Docker, Compose v2, UFW and basic tools
#   2. Firewall: default deny incoming, allow SSH, rate-limit TCP 2559 (UFW + DOCKER-USER)
#   3. Deploys the official postfiatd testnet image with admin/RPC ports bound to 127.0.0.1
#   4. Installs a health-check command and runs it
#
# It does NOT generate validator keys or set a domain. Follow the official guide
# (https://postfiat.org/validator-setup/ steps 5-8) for that, keeping keys off chat logs.

set -euo pipefail

POSTFIATD_DIR="${POSTFIATD_DIR:-/opt/postfiatd}"
NETWORK="${NETWORK:-testnet}"
COMPOSE_URL="https://raw.githubusercontent.com/postfiatorg/postfiatd/main/scripts/docker-compose-external-validator.yml"
LOG_FILE="/var/log/postfiat-installer.log"
ADMIN_PORTS=(5005 6005 6006 50051)
PEER_PORT=2559

# ---------- helpers ----------
log()  { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root (pipe into 'sudo bash')."

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
log "=== Post Fiat validator installer starting ==="

# ---------- OS check ----------
if [ -r /etc/os-release ]; then
  . /etc/os-release
  log "Detected OS: ${PRETTY_NAME:-unknown}"
  [ "${ID:-}" = "ubuntu" ] || die "Ubuntu required."
  major="${VERSION_ID%%.*}"
  [ "${major:-0}" -ge 22 ] || die "Ubuntu 22.04 or newer required."
else
  die "Cannot read /etc/os-release."
fi

# ---------- SSH port ----------
if [ -z "${SSH_PORT:-}" ]; then
  SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
  SSH_PORT="${SSH_PORT:-22}"
fi
log "SSH port: $SSH_PORT"

# ---------- 1. packages ----------
log "Step 1/5: installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io docker-compose-v2 curl wget jq python3 ufw iptables
systemctl enable --now docker
docker compose version || die "Docker Compose v2 not available."

# ---------- 2. firewall ----------
log "Step 2/5: configuring firewall"
# SSH first so we never lock ourselves out. Existing rules are preserved (no reset).
ufw allow "${SSH_PORT}/tcp" comment 'SSH'
ufw limit "${PEER_PORT}/tcp" comment 'Post Fiat peer protocol (rate-limited)'
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# Docker-published ports bypass UFW's INPUT chain, so the effective rate limit
# for the container lives in DOCKER-USER. Persist it via a systemd unit.
cat > /usr/local/sbin/postfiat-docker-user.sh <<'EOF'
#!/usr/bin/env bash
set -e
iptables -N DOCKER-USER 2>/dev/null || true
iptables -F DOCKER-USER
iptables -I DOCKER-USER -j RETURN
iptables -I DOCKER-USER -p tcp --dport 2559 -m state --state NEW -j DROP
iptables -I DOCKER-USER -p tcp --dport 2559 -m state --state NEW -m limit --limit 100/second --limit-burst 50 -j ACCEPT
iptables -I DOCKER-USER -p tcp --dport 2559 -m connlimit --connlimit-above 50 -j DROP
iptables -I DOCKER-USER -p tcp --dport 2559 -m state --state ESTABLISHED,RELATED -j ACCEPT
EOF
chmod 755 /usr/local/sbin/postfiat-docker-user.sh

cat > /etc/systemd/system/postfiat-docker-user.service <<'EOF'
[Unit]
Description=Post Fiat peer-port rate limits (DOCKER-USER)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/postfiat-docker-user.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now postfiat-docker-user.service

# ---------- 3. node directory + compose ----------
log "Step 3/5: preparing $POSTFIATD_DIR"
mkdir -p "$POSTFIATD_DIR/logs"
cd "$POSTFIATD_DIR"

if [ -f docker-compose.yml ]; then
  cp docker-compose.yml "docker-compose.yml.bak.$(date +%s)"
  log "Existing docker-compose.yml backed up."
fi
wget -q "$COMPOSE_URL" -O docker-compose.yml

# Bind admin/RPC ports to loopback only; leave peer port public.
for p in "${ADMIN_PORTS[@]}"; do
  sed -i "s|- \"${p}:${p}\"|- \"127.0.0.1:${p}:${p}\"|" docker-compose.yml
done

cat > .env <<EOF
NETWORK=${NETWORK}
HOSTNAME=$(hostname)
EOF

# Verify the resolved compose config before starting anything.
docker compose config --format json | python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"]["postfiatd"]
img = svc.get("image", "")
print("image:", img)
if not img.endswith("-light-latest"):
    raise SystemExit("image tag must be the official rolling -light-latest tag")
by = {int(p["target"]): p for p in svc.get("ports", [])}
for port in (5005, 6005, 6006, 50051):
    hip = by.get(port, {}).get("host_ip")
    print(f"{port} host_ip: {hip}")
    if hip != "127.0.0.1":
        raise SystemExit(f"{port} is not bound to 127.0.0.1")
if by.get(2559, {}).get("host_ip") == "127.0.0.1":
    raise SystemExit("peer port 2559 must stay public")
print("2559 host_ip:", by.get(2559, {}).get("host_ip", "0.0.0.0"))
'

# ---------- 4. start node ----------
log "Step 4/5: pulling and starting postfiatd"
docker compose pull
docker compose up -d
# Re-apply DOCKER-USER after Docker has (re)created its chains.
/usr/local/sbin/postfiat-docker-user.sh

IMAGE_REF="$(docker inspect postfiatd --format '{{.Config.Image}}')"
IMAGE_DIGEST="$(docker inspect "$(docker inspect postfiatd --format '{{.Image}}')" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo unknown)"
log "Running image: $IMAGE_REF"
log "Resolved digest: $IMAGE_DIGEST"

# ---------- 5. health check ----------
log "Step 5/5: installing and running health check"
cat > /usr/local/bin/postfiat-health <<'EOF'
#!/usr/bin/env bash
# Post Fiat validator health check. Exit 0 = healthy, 1 = failed.
set -uo pipefail
FAIL=0
pass() { printf '  [PASS] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }
info() { printf '  [INFO] %s\n' "$*"; }

echo "Post Fiat health check - $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1. Container up
state="$(docker inspect postfiatd --format '{{.State.Status}}' 2>/dev/null || echo missing)"
[ "$state" = "running" ] && pass "container postfiatd running" || fail "container state: $state"

# 2. Port bindings
listen="$(ss -ltnH 2>/dev/null)"
for p in 5005 6005 6006 50051; do
  if echo "$listen" | grep -Eq "(0\.0\.0\.0|\[::\]|\*):${p}\b"; then
    fail "admin port $p exposed on all interfaces"
  elif echo "$listen" | grep -Eq "127\.0\.0\.1:${p}\b"; then
    pass "admin port $p bound to 127.0.0.1"
  else
    info "admin port $p not listening"
  fi
done
echo "$listen" | grep -Eq ":2559\b" && pass "peer port 2559 listening" || fail "peer port 2559 not listening"

# 3. Firewall
if ufw status | grep -q "Status: active"; then
  pass "UFW active"
  ufw status | grep -E "2559/tcp.*LIMIT" >/dev/null && pass "UFW rate limit on 2559" || fail "no UFW LIMIT rule on 2559"
else
  fail "UFW inactive"
fi
iptables -S DOCKER-USER 2>/dev/null | grep -q "dport 2559 -m state --state NEW -m limit" \
  && pass "DOCKER-USER rate limit on 2559" || fail "DOCKER-USER rate limit missing"

# 4. Node RPC
resp="$(docker exec postfiatd curl -s --max-time 10 http://localhost:5005/ -X POST \
  -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' 2>/dev/null)"
srv_state="$(echo "$resp" | jq -r '.result.info.server_state // empty' 2>/dev/null)"
if [ -n "$srv_state" ]; then
  pass "RPC responding (server_state: $srv_state)"
  build="$(echo "$resp" | jq -r '.result.info.build_version // "?"')"
  peers="$(echo "$resp" | jq -r '.result.info.peers // "?"')"
  ledgers="$(echo "$resp" | jq -r '.result.info.complete_ledgers // "?"')"
  info "build_version: $build | peers: $peers | complete_ledgers: $ledgers"
  ref="$(curl -s --max-time 10 https://rpc.testnet.postfiat.org -X POST -H 'Content-Type: application/json' \
    -d '{"method":"server_info","params":[{}]}' | jq -r '.result.info.build_version // empty' 2>/dev/null)"
  if [ -n "$ref" ]; then
    [ "$ref" = "$build" ] && pass "build matches foundation RPC ($ref)" || info "foundation RPC build: $ref (local: $build)"
  fi
  case "$srv_state" in
    proposing) pass "validator proposing" ;;
    full|tracking|syncing|connected) info "node $srv_state - add validator token (official guide steps 5-8) to start proposing" ;;
  esac
else
  fail "RPC not responding on localhost:5005"
fi

echo
[ "$FAIL" -eq 0 ] && echo "RESULT: HEALTHY" || echo "RESULT: UNHEALTHY"
exit "$FAIL"
EOF
chmod 755 /usr/local/bin/postfiat-health

log "Waiting for RPC to come up (up to 180s)..."
for _ in $(seq 1 36); do
  if docker exec postfiatd curl -s --max-time 5 http://localhost:5005/ -X POST \
      -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' \
      | jq -e '.result.info.server_state' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

log "--- docker compose ps ---"
docker compose ps
log "--- UFW status ---"
ufw status verbose
log "--- DOCKER-USER chain ---"
iptables -L DOCKER-USER -n -v
log "--- Listening sockets ---"
ss -ltn | grep -E ':(2559|5005|6005|6006|50051)\b' || true
log "--- Health check ---"
if /usr/local/bin/postfiat-health; then
  log "=== Install complete: HEALTHY ==="
else
  log "=== Install finished but health check FAILED - see above ==="
  exit 1
fi
log "Full log: $LOG_FILE  |  Re-run checks any time: sudo postfiat-health"
