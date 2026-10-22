#!/usr/bin/env bash
# drill.sh: reversible four-change tamper drill for pft-integrity (run as root on a host you operate).
#   1. append a comment to a script        (DRILL_SCRIPT, restored byte-for-byte with its mtime)
#   2. chmod 644 a 0600 file                (DRILL_600, mode restored)
#   3. add/remove a no-op DOCKER-USER rule  (-A ... -j RETURN after the chain's own end: never changes a verdict)
#   4. pull a different image tag           (DRILL_TAG, never run, removed afterwards)
# Verify must name each change with the right item and field, notify once, stay silent on the unchanged
# repeat, and come back clean after the revert. Nothing touches the running postfiatd container.
#
# Usage: sudo DRILL_SCRIPT=/usr/local/bin/x DRILL_600=/path/file [DRILL_TAG=repo:tag] ./drill.sh [/path/pft-integrity]
set -uo pipefail
PI="${1:-/usr/local/bin/pft-integrity}"
: "${DRILL_SCRIPT:?set DRILL_SCRIPT}" "${DRILL_600:?set DRILL_600}"
DRILL_TAG="${DRILL_TAG:-agtipft/postfiatd:testnet-light-1.0.8}"
RULE=(DOCKER-USER -m comment --comment pft-integrity-drill -j RETURN)
step() { printf '\n== %s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; echo "exit $?"; }
item_of() { # manifest item id for a path
  case "$1" in
    /usr/local/bin/*) echo "bin:${1##*/}" ;;
    /etc/ssh/sshd_config.d/*) echo "sshd:sshd_config.d/${1##*/}" ;;
    */.env|*/docker-compose*) echo "compose:${1##*/}" ;;
    *) echo "?" ;;
  esac
}
[ "$(stat -c %a "$DRILL_600")" = 600 ] || { echo "DRILL_600 must be mode 600"; exit 3; }
docker image inspect "$DRILL_TAG" >/dev/null 2>&1 && { echo "$DRILL_TAG already present; pick another tag"; exit 3; }
iptables -C "${RULE[@]}" >/dev/null 2>&1 && { echo "drill rule already present"; exit 3; }
BK="$(mktemp -d)"; cp -p "$DRILL_SCRIPT" "$BK/script"

revert() {
  step "revert all four changes"
  cp -p "$BK/script" "$DRILL_SCRIPT" && echo "restored $(item_of "$DRILL_SCRIPT") (content + mode + mtime)"
  chmod 600 "$DRILL_600" && echo "chmod 600 $(item_of "$DRILL_600")"
  while iptables -C "${RULE[@]}" >/dev/null 2>&1; do iptables -D "${RULE[@]}" >/dev/null; done && echo "drill rule removed from DOCKER-USER"
  docker image inspect "$DRILL_TAG" >/dev/null 2>&1 && docker rmi "$DRILL_TAG" >/dev/null && echo "removed image tag $DRILL_TAG"
  rm -rf "$BK"
}
trap revert EXIT

echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"') | $(date -u +%Y-%m-%dT%H:%M:%SZ) | drill"
step "pre-drill verify (clean expected)"
run "$PI" verify --notify

step "apply 1/4: append a comment to $(item_of "$DRILL_SCRIPT")"
echo "# pft-integrity drill $(date -u +%s)" >>"$DRILL_SCRIPT"
step "apply 2/4: chmod 644 $(item_of "$DRILL_600") (was 600)"
chmod 644 "$DRILL_600"
step "apply 3/4: append no-op rule to DOCKER-USER"
iptables -A "${RULE[@]}" && echo "rules now: $(iptables -S DOCKER-USER | grep -c '^-A ')"
step "apply 4/4: pull $DRILL_TAG (not run)"
docker pull -q "$DRILL_TAG"

step "verify after tamper (4 findings + 1 ntfy expected)"
out="$("$PI" verify --notify 2>&1)"; rc=$?
echo "$out"; echo "exit $rc"
step "detection check"
chk() { if grep -E "\[$1\] +$2 +$3 .*$4" <<<"$out" >/dev/null; then echo "DETECTED  $1 $2 $3 $4"; else echo "MISSING   $1 $2 $3 $4"; fi; }
chk FAIL "$(item_of "$DRILL_SCRIPT")" changed "sha256"
chk FAIL "$(item_of "$DRILL_600")" changed "mode 600->644"
chk FAIL "fw:docker-user" changed "rules"
chk WARN "image:local:$DRILL_TAG" added ""

step "verify again, nothing changed (no ntfy expected)"
run "$PI" verify --notify

trap - EXIT
revert
step "verify after revert (clean + 1 recovery ntfy expected)"
run "$PI" verify --notify
step "verify again (clean, no ntfy expected)"
run "$PI" verify --notify
