#!/usr/bin/env bash
# pft-restore: restore a pft-backup.sh archive onto this host and bring postfiatd back up.
#
#  1. verifies the sidecar <archive>.sha256 (if present) and, after extracting into a temp
#     dir, the archive's MANIFEST.sha256 (every file must match; unlisted files are refused)
#  2. decrypts *.gpg archives (PFT_BACKUP_PASSPHRASE_FILE or PFT_BACKUP_PASSPHRASE)
#  3. installs docker-compose.yml/.env into COMPOSE_DIR (existing files kept as *.pre-restore-<ts>)
#  4. creates the container, copies postfiatd.cfg + validators.txt into its config volume,
#     starts it, and waits until server_state is "full" (or proposing) within --timeout
#  5. optional: --with-units installs the add-on units + helper scripts (daemon-reload, the
#     units are not enabled); --with-firewall installs the saved ufw user rules and reloads ufw
#
# Exit codes: 0 ok, 1 error, 2 usage, 3 verification failed, 4 timeout waiting for "full".
#
# Usage: sudo ./pft-restore.sh [--dry-run] [--timeout SECS] [--with-units] [--with-firewall] ARCHIVE
# Env:   COMPOSE_DIR (/opt/postfiatd)  CONTAINER (postfiatd)  TIMEOUT (900)

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/postfiatd}"
CONTAINER="${CONTAINER:-postfiatd}"
TIMEOUT="${TIMEOUT:-900}"
DRY_RUN=0
WITH_UNITS=0
WITH_FIREWALL=0
ARCHIVE=""

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $1"; exit "${2:-1}"; }
usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN would run: $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift ;;
    --with-units) WITH_UNITS=1 ;;
    --with-firewall) WITH_FIREWALL=1 ;;
    -h|--help) usage 0 ;;
    -*) log "unknown option: $1"; usage 2 ;;
    *) [ -z "$ARCHIVE" ] || usage 2; ARCHIVE="$1" ;;
  esac
  shift
done

[ -n "$ARCHIVE" ] || usage 2
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer." 2
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
for c in docker tar sha256sum; do command -v "$c" >/dev/null || die "$c required."; done
docker compose version >/dev/null 2>&1 ||
  die "'docker compose' plugin missing (Ubuntu: apt-get install docker-compose-v2); nothing was changed."

OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
log "OS: $OS_NAME"
[ "$DRY_RUN" -eq 1 ] && log "mode: DRY-RUN (verification runs, nothing on this host is changed)"
log "archive: $ARCHIVE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. sidecar checksum of the archive itself
if [ -f "$ARCHIVE.sha256" ]; then
  want="$(cut -d' ' -f1 "$ARCHIVE.sha256")"
  have="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
  [ "$want" = "$have" ] || die "archive sha256 mismatch: sidecar $want, archive $have" 3
  log "archive sha256 OK ($have)"
else
  log "WARNING: no sidecar $ARCHIVE.sha256; relying on the internal manifest only"
fi

# 2. decrypt if needed
TARBALL="$ARCHIVE"
if [[ "$ARCHIVE" == *.gpg ]]; then
  command -v gpg >/dev/null || die "gpg required for encrypted archives."
  TARBALL="$WORK/archive.tar.gz"
  gpg_args=(--batch --quiet --pinentry-mode loopback --decrypt -o "$TARBALL")
  if [ -n "${PFT_BACKUP_PASSPHRASE_FILE:-}" ]; then
    gpg "${gpg_args[@]}" --passphrase-file "$PFT_BACKUP_PASSPHRASE_FILE" "$ARCHIVE" || die "gpg decrypt failed" 3
  elif [ -n "${PFT_BACKUP_PASSPHRASE:-}" ]; then
    printf '%s' "$PFT_BACKUP_PASSPHRASE" | gpg "${gpg_args[@]}" --passphrase-fd 0 "$ARCHIVE" || die "gpg decrypt failed" 3
  else
    die "encrypted archive: set PFT_BACKUP_PASSPHRASE_FILE or PFT_BACKUP_PASSPHRASE." 2
  fi
  log "decrypted"
fi

# 3. extract into a temp dir and verify the manifest
if tar -tzf "$TARBALL" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
  die "archive contains absolute or '..' paths; refusing" 3
fi
tar -C "$WORK" -xzf "$TARBALL" || die "tar extraction failed" 3
mapfile -t tops < <(find "$WORK" -mindepth 1 -maxdepth 1 -type d -name 'pft-backup-*')
[ "${#tops[@]}" -eq 1 ] || die "unexpected archive layout" 3
SRC="${tops[0]}"
[ -f "$SRC/MANIFEST.sha256" ] || die "MANIFEST.sha256 missing" 3
log "verifying MANIFEST.sha256 ($(wc -l <"$SRC/MANIFEST.sha256") entries)"
if ! (cd "$SRC" && sha256sum --check --strict --quiet MANIFEST.sha256); then
  die "manifest verification FAILED; nothing was restored" 3
fi
extra="$(comm -13 <(awk '{print $2}' "$SRC/MANIFEST.sha256" | LC_ALL=C sort) \
  <(cd "$SRC" && find . -type f ! -name MANIFEST.sha256 -printf '%P\n' | LC_ALL=C sort))"
[ -z "$extra" ] || die "files not listed in manifest: $extra" 3
log "manifest OK"
sed 's/^/  meta: /' "$SRC/META.txt"

F="$SRC/files"
[ -f "$F/etc/postfiatd/postfiatd.cfg" ] || die "postfiatd.cfg missing from archive" 3
[ -f "$F$COMPOSE_DIR/docker-compose.yml" ] || die "docker-compose.yml for $COMPOSE_DIR missing from archive" 3

# 4. compose files
TS="$(date -u +%Y%m%dT%H%M%SZ)"
log "restore compose files -> $COMPOSE_DIR"
run mkdir -p "$COMPOSE_DIR" "$COMPOSE_DIR/logs"
for f in docker-compose.yml docker-compose.override.yml .env; do
  [ -f "$F$COMPOSE_DIR/$f" ] || continue
  [ -f "$COMPOSE_DIR/$f" ] && run cp -p "$COMPOSE_DIR/$f" "$COMPOSE_DIR/$f.pre-restore-$TS"
  run install -m 0644 "$F$COMPOSE_DIR/$f" "$COMPOSE_DIR/$f"
done

# 5. optional units / firewall
if [ "$WITH_UNITS" -eq 1 ]; then
  log "restore add-on units and helper scripts (not enabled)"
  while IFS= read -r p; do
    case "$p" in units-enabled.txt) continue ;; opt/postfiatd/*|etc/postfiatd/*) continue ;; esac
    run install -D -m "$(stat -c %a "$F/$p")" "$F/$p" "/$p"
  done < <(cd "$F" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  run systemctl daemon-reload
  [ -f "$F/units-enabled.txt" ] && sed 's/^/  was enabled on source: /' "$F/units-enabled.txt"
else
  log "skip units (use --with-units)"
fi
if [ "$WITH_FIREWALL" -eq 1 ]; then
  command -v ufw >/dev/null || die "ufw not installed"
  log "restore ufw user rules"
  for r in user.rules user6.rules; do
    [ -f "$SRC/firewall/$r" ] || continue
    run cp -p "/etc/ufw/$r" "/etc/ufw/$r.pre-restore-$TS"
    run install -m 0640 "$SRC/firewall/$r" "/etc/ufw/$r"
  done
  run ufw reload
  log "DOCKER-USER rules are re-applied by postfiat-docker-user.service (restore with --with-units)"
else
  log "skip firewall (use --with-firewall; saved rules are in firewall/ of the archive)"
fi

# 6. container + config volume
log "create container and load config into its volume"
run docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" create
if docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  run docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" stop
fi
run docker cp "$F/etc/postfiatd/postfiatd.cfg" "$CONTAINER:/etc/postfiatd/postfiatd.cfg"
[ -f "$F/etc/postfiatd/validators.txt" ] &&
  run docker cp "$F/etc/postfiatd/validators.txt" "$CONTAINER:/etc/postfiatd/validators.txt"
START="$(date +%s)"
run docker compose --project-directory "$COMPOSE_DIR" -f "$COMPOSE_DIR/docker-compose.yml" up -d

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN would wait up to ${TIMEOUT}s for server_state full"
  log "DRY-RUN complete; nothing changed"
  exit 0
fi

log "waiting up to ${TIMEOUT}s for server_state full"
state=unknown
last=""
while :; do
  el=$(( $(date +%s) - START ))
  state="$(docker exec "$CONTAINER" curl -s --max-time 10 http://localhost:5005/ -X POST \
    -H 'Content-Type: application/json' -d '{"method":"server_info","params":[{}]}' 2>/dev/null |
    grep -o '"server_state":"[^"]*"' | cut -d'"' -f4 || true)"
  state="${state:-unreachable}"
  [ "$state" != "$last" ] && log "  t+${el}s server_state: $state" && last="$state"
  case "$state" in full|proposing|validating) break ;; esac
  [ "$el" -ge "$TIMEOUT" ] && die "server_state still '$state' after ${TIMEOUT}s" 4
  sleep 5
done
log "server_state: $state after $(( $(date +%s) - START ))s"
log "restore complete"
