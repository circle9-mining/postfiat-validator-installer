#!/usr/bin/env bash
# pft-backup: timestamped tar.gz of a Post Fiat node's configuration (not the ledger DB)
# with a SHA-256 manifest, secrets excluded by default, and retention pruning.
#
# Archive layout:
#   MANIFEST.sha256        sha256 of every other file in the archive
#   META.txt               creation time, OS, image, build_version, what was excluded
#   files/<abs path>       postfiatd.cfg + validators.txt (from the container), compose
#                          file + .env, add-on systemd units and the helper scripts they run
#   firewall/              ufw user rules, `ufw status verbose`, `iptables -S DOCKER-USER`
# A sidecar <archive>.sha256 is written next to the archive.
#
# Default (no secrets): [validator_token], [validation_seed], [node_seed] sections are
# stripped from postfiatd.cfg and the monitor env file (ntfy topic) is left out.
# --include-secrets keeps them and encrypts the whole archive with gpg --symmetric
# (AES256); the passphrase comes from PFT_BACKUP_PASSPHRASE_FILE or PFT_BACKUP_PASSPHRASE.
#
# Usage: sudo ./pft-backup.sh [--include-secrets] [--keep N] [--dest DIR]
# Env:   BACKUP_DIR (/var/backups/postfiat)  KEEP (14)  COMPOSE_DIR (/opt/postfiatd)
#        CONTAINER (postfiatd)  SECRET_FILES (extra files only included with --include-secrets)

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/postfiat}"
KEEP="${KEEP:-14}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
CONTAINER="${CONTAINER:-postfiatd}"
INCLUDE_SECRETS=0

UNITS=(postfiat-monitor.service postfiat-monitor.timer postfiat-docker-user.service pft-exporter.service)
HELPERS=(/usr/local/bin/postfiat-health /usr/local/bin/postfiat-monitor
  /usr/local/sbin/postfiat-docker-user.sh /opt/pft-exporter/pft_exporter.py)
read -r -a SECRET_FILES <<<"${SECRET_FILES:-/etc/postfiat-monitor.env}"
SECRET_SECTIONS='validator_token|validation_seed|node_seed'

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --include-secrets) INCLUDE_SECRETS=1 ;;
    --keep) KEEP="${2:?--keep needs a number}"; shift ;;
    --dest) BACKUP_DIR="${2:?--dest needs a directory}"; shift ;;
    -h|--help) usage 0 ;;
    *) log "unknown argument: $1"; usage 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer (got '$KEEP')."
for c in docker tar gzip sha256sum; do command -v "$c" >/dev/null || die "$c required."; done
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not found."

PASSFILE=""
if [ "$INCLUDE_SECRETS" -eq 1 ]; then
  command -v gpg >/dev/null || die "gpg required for --include-secrets."
  if [ -n "${PFT_BACKUP_PASSPHRASE_FILE:-}" ]; then
    [ -s "$PFT_BACKUP_PASSPHRASE_FILE" ] || die "PFT_BACKUP_PASSPHRASE_FILE is empty or missing."
    PASSFILE="$PFT_BACKUP_PASSPHRASE_FILE"
  elif [ -z "${PFT_BACKUP_PASSPHRASE:-}" ]; then
    die "--include-secrets needs PFT_BACKUP_PASSPHRASE_FILE or PFT_BACKUP_PASSPHRASE."
  fi
fi

OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
log "OS: $OS_NAME"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="pft-backup-$TS"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$NAME"
mkdir -p "$STAGE/files" "$STAGE/firewall" "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

add_file() { # $1 = absolute path on this host
  local dst="$STAGE/files$1"
  mkdir -p "$(dirname "$dst")"
  cp -p "$1" "$dst"
  log "  + $1"
}

log "collecting node config from container '$CONTAINER'"
mkdir -p "$STAGE/files/etc/postfiatd"
docker cp -q "$CONTAINER:/etc/postfiatd/validators.txt" "$STAGE/files/etc/postfiatd/validators.txt"
log "  + /etc/postfiatd/validators.txt (container)"
docker cp -q "$CONTAINER:/etc/postfiatd/postfiatd.cfg" "$WORK/postfiatd.cfg"
EXCLUDED=()
if [ "$INCLUDE_SECRETS" -eq 1 ]; then
  cp "$WORK/postfiatd.cfg" "$STAGE/files/etc/postfiatd/postfiatd.cfg"
  log "  + /etc/postfiatd/postfiatd.cfg (container, secrets kept)"
else
  # drop every line of the secret sections (header up to the next [section])
  awk -v re="^\\\\[($SECRET_SECTIONS)\\\\]" '
    /^\[/ { skip = ($0 ~ re) }
    !skip' "$WORK/postfiatd.cfg" >"$STAGE/files/etc/postfiatd/postfiatd.cfg"
  found="$(grep -oE "^\[($SECRET_SECTIONS)\]" "$WORK/postfiatd.cfg" | tr '\n' ' ' || true)"
  log "  + /etc/postfiatd/postfiatd.cfg (container, stripped sections: ${found:-none present})"
  EXCLUDED+=("postfiatd.cfg sections [${SECRET_SECTIONS//|/], [}] (present: ${found:-none})")
fi

log "collecting compose files from $COMPOSE_DIR"
for f in docker-compose.yml .env; do
  if [ -f "$COMPOSE_DIR/$f" ]; then add_file "$COMPOSE_DIR/$f"; fi
done

log "collecting add-on systemd units and helper scripts"
for u in "${UNITS[@]}"; do
  if [ -f "/etc/systemd/system/$u" ]; then
    add_file "/etc/systemd/system/$u"
    printf '%s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || true)" >>"$STAGE/files/units-enabled.txt"
  fi
done
for h in "${HELPERS[@]}"; do if [ -f "$h" ]; then add_file "$h"; fi; done

for s in "${SECRET_FILES[@]}"; do
  [ -f "$s" ] || continue
  if [ "$INCLUDE_SECRETS" -eq 1 ]; then add_file "$s"; else EXCLUDED+=("$s"); log "  - $s (secret, excluded)"; fi
done

log "collecting firewall rules"
for r in /etc/ufw/user.rules /etc/ufw/user6.rules; do
  [ -f "$r" ] && cp -p "$r" "$STAGE/firewall/$(basename "$r")" && log "  + $r"
done
if command -v ufw >/dev/null; then ufw status verbose >"$STAGE/firewall/ufw-status.txt" 2>&1 || true; log "  + ufw status verbose"; fi
if iptables -S DOCKER-USER >"$STAGE/firewall/docker-user.rules" 2>/dev/null; then
  log "  + iptables -S DOCKER-USER ($(wc -l <"$STAGE/firewall/docker-user.rules") rules)"
else
  rm -f "$STAGE/firewall/docker-user.rules"
fi

BUILD="$(docker exec "$CONTAINER" curl -s --max-time 10 http://localhost:5005/ -X POST \
  -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' 2>/dev/null |
  grep -o '"build_version":"[^"]*"' | cut -d'"' -f4 || true)"
{
  echo "created_utc=$TS"
  echo "os=$OS_NAME"
  echo "image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")"
  echo "build_version=${BUILD:-unknown}"
  echo "secrets_included=$INCLUDE_SECRETS"
  for e in "${EXCLUDED[@]}"; do echo "excluded=$e"; done
  echo "not_backed_up=ledger database (postfiatd-data volume): re-syncs from the network"
} >"$STAGE/META.txt"

(cd "$STAGE" && find . -type f -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum) >"$WORK/MANIFEST.sha256"
mv "$WORK/MANIFEST.sha256" "$STAGE/MANIFEST.sha256"
log "manifest: $(wc -l <"$STAGE/MANIFEST.sha256") files"

umask 077
OUT="$BACKUP_DIR/$NAME.tar.gz"
tar -C "$WORK" -czf "$OUT" "$NAME"
if [ "$INCLUDE_SECRETS" -eq 1 ]; then
  gpg_args=(--batch --yes --pinentry-mode loopback --symmetric --cipher-algo AES256 -o "$OUT.gpg")
  if [ -n "$PASSFILE" ]; then
    gpg "${gpg_args[@]}" --passphrase-file "$PASSFILE" "$OUT"
  else
    printf '%s' "$PFT_BACKUP_PASSPHRASE" | gpg "${gpg_args[@]}" --passphrase-fd 0 "$OUT"
  fi
  rm -f "$OUT"
  OUT="$OUT.gpg"
  log "encrypted with gpg --symmetric (AES256)"
fi
(cd "$BACKUP_DIR" && sha256sum "$(basename "$OUT")" >"$(basename "$OUT").sha256")
log "archive: $OUT ($(stat -c %s "$OUT") bytes)"
log "sha256 : $(cut -d' ' -f1 "$OUT.sha256")"

log "retention: keep newest $KEEP"
mapfile -t all < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'pft-backup-*.tar.gz' -o -name 'pft-backup-*.tar.gz.gpg' \) -printf '%f\n' | LC_ALL=C sort -r)
for ((i = KEEP; i < ${#all[@]}; i++)); do
  rm -f "$BACKUP_DIR/${all[$i]}" "$BACKUP_DIR/${all[$i]}.sha256"
  log "  pruned ${all[$i]}"
done
log "retention: $(( ${#all[@]} < KEEP ? ${#all[@]} : KEEP )) kept, $(( ${#all[@]} > KEEP ? ${#all[@]} - KEEP : 0 )) pruned"
log "done"
