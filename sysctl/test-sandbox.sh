#!/usr/bin/env bash
# test-sandbox: exercise pft-sysctl.sh check/apply/rollback without touching the host's sysctls.
#   - net.* keys are real kernel sysctls of a throwaway network namespace (unshare --net)
#   - kernel.* / fs.* keys are global, so they live in a fake PROC_SYS tree seeded with the
#     host's current values; net/ in that tree is a symlink to the namespace's /proc/sys/net
#   - sysctl.d dirs, sysctl.conf, CONF_FILE and BACKUP_DIR are copies/paths under a temp dir
#   - SYSCTL_SYSTEM is the script's own `_load` (same file order as procps sysctl --system),
#     run once at the start to give the namespace the host's boot-time state
#
# Usage: sudo ./test-sandbox.sh      exit 0 = all checks passed
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${PFT_SYSCTL_NETNS:-}" ]; then
  HOST_NETNS="$(readlink /proc/self/ns/net)" PFT_SYSCTL_NETNS=1 exec unshare --net "$0" "$@"
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
S="$PWD/pft-sysctl.sh"
export PFT_SYSCTL_SANDBOX=1 PROC_SYS="$T/proc/sys" CONF_FILE="$T/etc/sysctl.d/90-postfiat-hardening.conf" \
  SYSCTL_DIRS="$T/etc/sysctl.d $T/usr/lib/sysctl.d" SYSCTL_CONF="$T/etc/sysctl.conf" BACKUP_DIR="$T/backups"
export SYSCTL_SYSTEM="$S _load"
PASS=0; FAIL=0
check() { # $1 name, $2 expected exit, rest = command
  local name="$1" want="$2" got=0; shift 2
  echo "---- $name: ${*/#$S/pft-sysctl.sh}"
  "$@" || got=$?
  if [ "$got" -eq "$want" ]; then echo "PASS $name (exit $got)"; PASS=$((PASS + 1))
  else echo "FAIL $name (exit $got, want $want)"; FAIL=$((FAIL + 1)); fi
}
expect() { # $1 name, rest = test expression command
  local name="$1"; shift
  if "$@"; then echo "PASS $name"; PASS=$((PASS + 1)); else echo "FAIL $name"; FAIL=$((FAIL + 1)); fi
}
# Everything the script may touch: every profile key + guards, and all of net/ipv4/conf + net/ipv6/conf.
snapshot() {
  { "$S" profile | awk '{print $1}'; echo net.ipv4.ip_forward; } | while read -r k; do
    f="$PROC_SYS/${k//.//}"; [ -f "$f" ] && printf '%s = %s\n' "$k" "$(cat "$f")"; done
  find /proc/sys/net/ipv4/conf /proc/sys/net/ipv6/conf -type f -readable 2>/dev/null | LC_ALL=C sort |
    while read -r f; do printf '%s = %s\n' "${f#/proc/sys/}" "$(tr '\t' ' ' <"$f" 2>/dev/null)"; done
  echo "conf file: $([ -f "$CONF_FILE" ] && sha256sum <"$CONF_FILE" | cut -c1-16 || echo absent)"
}

echo "OS: $(grep ^PRETTY_NAME= /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "netns: host $HOST_NETNS, sandbox $(readlink /proc/self/ns/net) ($( [ "$HOST_NETNS" != "$(readlink /proc/self/ns/net)" ] && echo separate || echo SAME))"
[ "$HOST_NETNS" != "$(readlink /proc/self/ns/net)" ] || { echo "not in a separate netns, refusing"; exit 2; }

# fake tree: kernel/fs profile keys seeded from the host, net -> this namespace
mkdir -p "$PROC_SYS" "$T/etc/sysctl.d" "$T/usr/lib/sysctl.d" "$BACKUP_DIR"
ln -s /proc/sys/net "$PROC_SYS/net"
"$S" profile | awk '$1 !~ /^net\./ {print $1}' | while read -r k; do
  f="/proc/sys/${k//.//}"; [ -r "$f" ] || continue
  mkdir -p "$(dirname "$PROC_SYS/${k//.//}")"; cat "$f" >"$PROC_SYS/${k//.//}"
done
for f in /etc/sysctl.d/*.conf; do cp -L "$f" "$T/etc/sysctl.d/"; done
for f in /usr/lib/sysctl.d/*.conf; do cp -L "$f" "$T/usr/lib/sysctl.d/"; done
[ -f /etc/sysctl.conf ] && cp -L /etc/sysctl.conf "$SYSCTL_CONF"
echo "seeded: $(find "$PROC_SYS" -path "$PROC_SYS/net" -prune -o -type f -print | wc -l) kernel/fs keys, $(find "$T/etc/sysctl.d" "$T/usr/lib/sysctl.d" -name '*.conf' | wc -l) sysctl.d files"
"$S" _load   # namespace now looks like a freshly booted host (systemd-sysctl ran)

echo; echo "==== 1. Docker guard negative control: ip_forward=0 (set in the sandbox netns only)"
echo 0 >/proc/sys/net/ipv4/ip_forward
check "check reports FAIL" 2 "$S" check
"$S" check | grep -E '^FAIL +net.ipv4.ip_forward' || true
check "apply refuses" 2 "$S" apply
expect "nothing written" test ! -e "$CONF_FILE"
echo 1 >/proc/sys/net/ipv4/ip_forward   # what dockerd does at start

echo; echo "==== 2. check before"
snapshot >"$T/before.txt"
check "check before (gaps -> FAIL)" 2 "$S" check
check "json (.exit == 2, >30 items)" 0 sh -c "'$S' check --json | jq -e '.exit == 2 and (.items | length) > 30' >/dev/null"

echo; echo "==== 3. apply --dry-run"
check "dry-run" 0 "$S" apply --dry-run
expect "dry-run wrote nothing" test ! -e "$CONF_FILE"
expect "dry-run changed nothing" cmp -s "$T/before.txt" <(snapshot)

echo; echo "==== 4. apply"
check "apply -> re-check all PASS" 0 "$S" apply
check "check after apply" 0 "$S" check
expect "ip_forward still 1" test "$(cat /proc/sys/net/ipv4/ip_forward)" = 1
echo "-- $CONF_FILE (sandbox copy)"; sed 's/^/  /' "$CONF_FILE"

echo; echo "==== 5. idempotent re-apply"
"$S" apply >"$T/reapply.txt" || true
grep -E 'runtime value\(s\) change' "$T/reapply.txt"
expect "second apply changes 0 values" grep -q '  0 runtime value(s) change' "$T/reapply.txt"

echo; echo "==== 6. negative control: deliberately wrong runtime value"
echo 0 >"$PROC_SYS/kernel/kptr_restrict"
check "wrong kptr_restrict -> FAIL" 2 "$S" check
"$S" check | grep -E '^FAIL' || true
echo 2 >"$PROC_SYS/kernel/kptr_restrict"

echo; echo "==== 7. negative control: later sysctl.d file overrides the profile"
printf 'kernel.kptr_restrict = 0\n' >"$T/etc/sysctl.d/99-zz-override.conf"
check "override -> WARN" 1 "$S" check
"$S" check | grep -E '^WARN' || true
rm "$T/etc/sysctl.d/99-zz-override.conf"

echo; echo "==== 8. negative control: a sysctl.d file sets ip_forward=0"
printf 'net.ipv4.ip_forward = 0\n' >"$T/etc/sysctl.d/99-zz-forward.conf"
check "persisted ip_forward=0 -> FAIL" 2 "$S" check
"$S" check | grep -E '^FAIL' || true
rm "$T/etc/sysctl.d/99-zz-forward.conf"

echo; echo "==== 9. rollback"
check "rollback" 0 "$S" rollback
snapshot >"$T/after.txt"
echo "before sha256: $(sha256sum <"$T/before.txt" | cut -c1-16)  ($(wc -l <"$T/before.txt") lines)"
echo "after  sha256: $(sha256sum <"$T/after.txt" | cut -c1-16)  ($(wc -l <"$T/after.txt") lines)"
expect "rollback byte-identical (cmp before after)" cmp "$T/before.txt" "$T/after.txt"
expect "conf file removed" test ! -e "$CONF_FILE"
check "check after rollback = before" 2 "$S" check

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
