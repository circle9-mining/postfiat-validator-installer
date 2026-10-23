#!/usr/bin/env bash
# pft-sysctl: kernel and network-stack sysctl hardening for Post Fiat validator / sentry hosts.
#
# Modes:
#   check      read-only. Compares the runtime value and the persisted value (the last assignment
#              in sysctl --system file order) of every profile key: FAIL = runtime value misses the
#              profile, WARN = runtime ok but not persisted / overridden by a later file, PASS = both
#              ok. Plus Docker guards and conntrack sizing. Exit 0 PASS / 1 WARN / 2 FAIL. --json. [default]
#   apply      WRITES: shows a dry-run diff (key: runtime -> target, and diff -u of the conf file),
#              backs up the prior runtime values, writes CONF_FILE, runs SYSCTL_SYSTEM
#              (sysctl --system), then re-checks the Docker guards. --dry-run stops after the diff.
#   rollback   WRITES: restores the exact prior runtime values from the latest (or --from FILE)
#              backup and removes CONF_FILE (or restores the previous copy of it). Does not run
#              sysctl --system, so the values restored are the ones that were live before apply.
#              Re-applying an unchanged profile is a no-op and takes no new backup.
#   profile    print the hardening profile (key, rule, value written, rationale).
# Boot-time overrides (Ubuntu): ufw re-applies its IPT_SYSCTL file (/etc/ufw/sysctl.conf, sets
# log_martians=0) when it starts, after systemd-sysctl; apport's init script writes
# fs.suid_dumpable=2 when enabled. check treats both as later sources than sysctl.d (WARN, lost
# at reboot); apply edits the offending ufw lines to the profile value and sets enabled=0 in
# /etc/default/apport (KEEP_APPORT=1 skips that), backing up both files for rollback.
#
# Usage: sudo ./pft-sysctl.sh [check|apply|rollback|profile] [--json] [--dry-run] [--from FILE]
# Env: PROC_SYS (/proc/sys)  CONF_FILE (/etc/sysctl.d/90-postfiat-hardening.conf)
#      SYSCTL_DIRS ("/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d")
#      SYSCTL_CONF (/etc/sysctl.conf)  BACKUP_DIR (/var/backups/pft-sysctl)
#      SYSCTL_SYSTEM ("sysctl --system")  UFW_DEFAULT (/etc/default/ufw)  UFW_CONF (/etc/ufw/ufw.conf)
#      APPORT_DEFAULT (/etc/default/apport)  APPORT_INIT (/etc/init.d/apport)  KEEP_APPORT (unset)
# Never written: net.ipv4.ip_forward (Docker needs 1) and net.bridge.bridge-nf-call-* (Docker
# and br_netfilter own them). Keys missing on this kernel are reported SKIP and never written.

set -euo pipefail

PROC_SYS="${PROC_SYS:-/proc/sys}"
CONF_FILE="${CONF_FILE:-/etc/sysctl.d/90-postfiat-hardening.conf}"
SYSCTL_DIRS="${SYSCTL_DIRS:-/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pft-sysctl}"
UFW_DEFAULT="${UFW_DEFAULT:-/etc/default/ufw}"
UFW_CONF="${UFW_CONF:-/etc/ufw/ufw.conf}"
APPORT_DEFAULT="${APPORT_DEFAULT:-/etc/default/apport}"
APPORT_INIT="${APPORT_INIT:-/etc/init.d/apport}"
read -r -a SYSCTL_SYSTEM <<<"${SYSCTL_SYSTEM:-sysctl --system}"

# key  rule(eq|ge)  want  write  rationale
PROFILE='net.ipv4.conf.all.rp_filter eq 2 2 reverse-path filter, loose mode (strict breaks asymmetric/Docker routing)
net.ipv4.conf.default.rp_filter eq 2 2 same for interfaces created later (veths)
net.ipv4.tcp_syncookies eq 1 1 SYN-flood resistance on the public peer port 2559
net.ipv4.conf.all.accept_redirects eq 0 0 ignore ICMP redirects (route hijack)
net.ipv4.conf.default.accept_redirects eq 0 0 same for new interfaces
net.ipv4.conf.all.secure_redirects eq 0 0 ignore redirects even from listed gateways
net.ipv4.conf.default.secure_redirects eq 0 0 same for new interfaces
net.ipv4.conf.all.send_redirects eq 0 0 a node host is not a router for its LAN
net.ipv4.conf.default.send_redirects eq 0 0 same for new interfaces
net.ipv6.conf.all.accept_redirects eq 0 0 ignore ICMPv6 redirects
net.ipv6.conf.default.accept_redirects eq 0 0 same for new interfaces
net.ipv4.conf.all.accept_source_route eq 0 0 drop source-routed packets
net.ipv4.conf.default.accept_source_route eq 0 0 same for new interfaces
net.ipv6.conf.all.accept_source_route eq 0 0 drop IPv6 source-routed packets
net.ipv6.conf.default.accept_source_route eq 0 0 same for new interfaces
net.ipv4.conf.all.log_martians eq 1 1 log impossible source addresses (kernel rate-limited)
net.ipv4.conf.default.log_martians eq 1 1 same for new interfaces
net.ipv4.icmp_echo_ignore_broadcasts eq 1 1 no smurf amplification
net.ipv4.icmp_ignore_bogus_error_responses eq 1 1 do not log bogus ICMP errors
kernel.kptr_restrict eq 2 2 hide kernel pointers from everyone, incl. root tools
kernel.dmesg_restrict eq 1 1 kernel log only for CAP_SYSLOG
kernel.unprivileged_bpf_disabled ge 1 2 no unprivileged eBPF (2 = revertible; 1 locks until reboot)
kernel.yama.ptrace_scope ge 1 1 ptrace only of descendants (3 would be irreversible)
fs.protected_hardlinks eq 1 1 no hardlinks to files you do not own
fs.protected_symlinks eq 1 1 no following others symlinks in sticky dirs
fs.protected_fifos ge 1 1 no O_CREAT on others FIFOs in sticky dirs
fs.protected_regular ge 1 2 no O_CREAT on others regular files in sticky dirs
fs.suid_dumpable eq 0 0 no core dumps of setuid processes (key material in memory)'

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "ERROR: $*"; exit 2; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

kpath() { printf '%s/%s' "$PROC_SYS" "${1//.//}"; }
has_key() { [ -f "$(kpath "$1")" ]; }
get_key() { tr -s '\t ' ' ' <"$(kpath "$1")"; }
set_key() { printf '%s\n' "$2" >"$(kpath "$1")"; }

ok_rule() { # rule want value
  case "$1" in
    eq) [ "$3" = "$2" ] ;;
    ge) [[ "$3" =~ ^[0-9]+$ ]] && [ "$3" -ge "$2" ] ;;
  esac
}

# sysctl --system order (procps): *.conf from SYSCTL_DIRS, first directory wins per basename,
# sorted by basename, then SYSCTL_CONF last.
conf_files() {
  local d f b
  declare -A seen=()
  for d in $SYSCTL_DIRS; do
    for f in "$d"/*.conf; do
      [ -f "$f" ] || continue
      b="${f##*/}"; [ -n "${seen[$b]:-}" ] && continue
      seen[$b]="$f"
    done
  done
  for b in "${!seen[@]}"; do printf '%s\t%s\n' "$b" "${seen[$b]}"; done | LC_ALL=C sort | cut -f2
  [ -f "$SYSCTL_CONF" ] && printf '%s\n' "$SYSCTL_CONF"
  return 0
}

# Value of the last `NAME=value` line of a shell-style config file (quotes stripped), or nothing.
shvar() { if [ -f "$2" ]; then sed -n "s/^[[:space:]]*$1=//p" "$2" | tail -1 | tr -d "\"'"; fi; }

# ufw's IPT_SYSCTL file if ufw is enabled (ufw runs `sysctl -p` on it at start, after systemd-sysctl).
ufw_sysctl() {
  local f
  [ "$(shvar ENABLED "$UFW_CONF")" = yes ] || return 0
  f="$(shvar IPT_SYSCTL "$UFW_DEFAULT")"
  [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}
# 0 when apport's init script will set fs.suid_dumpable=2 at boot (enabled=1, the default if unset).
apport_sets_dumpable() {
  [ -f "$APPORT_INIT" ] && grep -q 'suid_dumpable' "$APPORT_INIT" || return 1
  [ "$(shvar enabled "$APPORT_DEFAULT")" != 0 ]
}

parse_assign() { # file -> file<TAB>key<TAB>value per assignment (key normalised, '-' prefix dropped)
  awk -v f="$1" '
    /^[[:space:]]*([#;]|$)/ { next }
    { line=$0; sub(/^[[:space:]]*-?/, "", line); i=index(line, "="); if (!i) next
      k=substr(line, 1, i-1); v=substr(line, i+1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/\//, ".", k); gsub(/[[:space:]]+/, " ", v); print f "\t" k "\t" v }' "$1"
}

# All assignments in boot order: sysctl --system files, then ufw IPT_SYSCTL, then apport.
assignments() {
  local f
  while IFS= read -r f; do parse_assign "$f"; done < <(conf_files)
  while IFS= read -r f; do parse_assign "$f"; done < <(ufw_sysctl)
  if apport_sets_dumpable; then printf '%s\tfs.suid_dumpable\t2\n' "$APPORT_DEFAULT"; fi
  return 0
}

# persisted <key> <assignments-file> -> "value<TAB>file" of the last matching assignment, or nothing.
persisted() {
  local key="$1" f k v out=""
  while IFS=$'\t' read -r f k v; do
    # shellcheck disable=SC2053  # globs in sysctl.d keys (e.g. net.ipv4.conf.*.rp_filter) are intended
    if [ "$k" = "$key" ] || { [[ "$k" == *'*'* ]] && [[ "$key" == $k ]]; }; then out="$v"$'\t'"$f"; fi
  done <"$2"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

profile_lines() { printf '%s\n' "$PROFILE"; }

# ---------- check ----------
RESULTS=()  # status<TAB>key<TAB>want<TAB>runtime<TAB>persisted<TAB>source<TAB>note
add() { RESULTS+=("$(printf '%s\t' "$@")"); }

run_checks() {
  local tmp key rule want _w _r cur p pv src st note
  tmp="$(mktemp)"; assignments >"$tmp"
  while read -r key rule want _w _r; do
    if ! has_key "$key"; then add SKIP "$key" "$rule $want" - - - "not present on this kernel"; continue; fi
    cur="$(get_key "$key")"; p="$(persisted "$key" "$tmp")"
    pv="${p%%$'\t'*}"; src="${p#*$'\t'}"; [ -n "$p" ] || { pv=-; src=-; }
    if ! ok_rule "$rule" "$want" "$cur"; then st=FAIL; note="runtime value does not meet the profile"
    elif [ "$pv" = - ]; then st=WARN; note="runtime only, no sysctl.d file sets it (kernel default after reboot)"
    elif ! ok_rule "$rule" "$want" "$pv"; then st=WARN; note="persisted value does not meet the profile (lost at reboot)"
      case "$src" in "$APPORT_DEFAULT") note="apport sets it at boot (enabled=1 in $APPORT_DEFAULT; lost at reboot)" ;;
        "$(ufw_sysctl)") note="ufw re-applies $src at start, after sysctl.d (lost at reboot)" ;; esac
    else st=PASS; note=""; fi
    add "$st" "$key" "$rule $want" "$cur" "$pv" "$src" "$note"
  done < <(profile_lines)

  # Docker guards: checked, never written.
  if has_key net.ipv4.ip_forward; then
    cur="$(get_key net.ipv4.ip_forward)"; p="$(persisted net.ipv4.ip_forward "$tmp")"
    pv="${p%%$'\t'*}"; src="${p#*$'\t'}"; [ -n "$p" ] || { pv=-; src=-; }
    if [ "$cur" != 1 ]; then add FAIL net.ipv4.ip_forward "docker 1" "$cur" "$pv" "$src" "Docker container networking needs ip_forward=1"
    elif [ "$pv" = 0 ]; then add FAIL net.ipv4.ip_forward "docker 1" "$cur" "$pv" "$src" "a sysctl.d file sets 0: sysctl --system would break Docker"
    else add PASS net.ipv4.ip_forward "docker 1" "$cur" "$pv" "$src" "Docker guard (never written)"; fi
  fi
  for key in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
    if has_key "$key"; then add INFO "$key" "untouched" "$(get_key "$key")" - - "owned by Docker/br_netfilter, never written"
    else add INFO "$key" "untouched" - - - "br_netfilter not loaded, never written"; fi
  done

  # Conntrack sizing: recommendation only.
  if has_key net.netfilter.nf_conntrack_max && has_key net.netfilter.nf_conntrack_count; then
    local max cnt pct rec=262144
    max="$(get_key net.netfilter.nf_conntrack_max)"; cnt="$(get_key net.netfilter.nf_conntrack_count)"
    pct=$((cnt * 100 / (max > 0 ? max : 1)))
    while [ "$rec" -lt $((cnt * 4)) ]; do rec=$((rec * 2)); done
    if [ "$pct" -ge 75 ]; then st=WARN; note="table ${pct}% full; raise nf_conntrack_max to >= $rec"
    else st=PASS; note="${pct}% used; headroom ok (recommend >= $rec = 4x current count, min 262144)"; fi
    add "$st" net.netfilter.nf_conntrack_max ">= 4x count" "$max" - - "$note (count $cnt)"
  else
    add SKIP net.netfilter.nf_conntrack_max ">= 4x count" - - - "nf_conntrack not loaded"
  fi
  rm -f "$tmp"
}

report() { # $1 = json?
  local r worst=0 n_pass=0 n_warn=0 n_fail=0 st
  for r in "${RESULTS[@]}"; do
    st="${r%%$'\t'*}"
    case "$st" in PASS) n_pass=$((n_pass + 1)) ;; WARN) n_warn=$((n_warn + 1)); [ $worst -lt 1 ] && worst=1 ;;
                  FAIL) n_fail=$((n_fail + 1)); worst=2 ;; esac
  done
  if [ "$1" = 1 ]; then
    printf '%s\n' "${RESULTS[@]}" | jq -R -s -c --argjson exit "$worst" '
      [split("\n")[] | select(length > 0) | split("\t") |
        {status: .[0], key: .[1], want: .[2], runtime: .[3], persisted: .[4], source: .[5], note: .[6]}] as $r |
      {result: (["PASS","WARN","FAIL"][$exit]), exit: $exit, items: $r}'
  else
    printf '%-5s %-45s %-10s %-8s %-9s %s\n' STATE KEY WANT RUNTIME PERSIST "SOURCE / NOTE"
    for r in "${RESULTS[@]}"; do
      IFS=$'\t' read -r st key want cur pv src note <<<"$r"
      printf '%-5s %-45s %-10s %-8s %-9s %s\n' "$st" "$key" "$want" "$cur" "$pv" "${src##*/}${note:+ | $note}"
    done
    printf 'RESULT: %s - %d pass, %d warn, %d fail -> exit %d\n' \
      "$(echo PASS WARN FAIL | cut -d' ' -f$((worst + 1)))" "$n_pass" "$n_warn" "$n_fail" "$worst"
  fi
  return "$worst"
}

# ---------- apply ----------
render_conf() {
  local key rule want write rat cur
  printf '# Managed by pft-sysctl.sh (postfiat-validator-installer/sysctl). Rollback: pft-sysctl.sh rollback\n'
  printf '# Never sets net.ipv4.ip_forward or net.bridge.* (Docker owns them).\n'
  while read -r key rule want write rat; do
    has_key "$key" || continue
    cur="$(get_key "$key")"
    # ge rules keep a stricter current value (e.g. unprivileged_bpf_disabled=1 cannot be lowered)
    if [ "$rule" = ge ] && ok_rule ge "$want" "$cur"; then write="$cur"; fi
    printf '# %s\n%s = %s\n' "$rat" "$key" "$write"
  done < <(profile_lines)
}

# Boot-override fixes -> "path<TAB>newcontent-file" lines; writes candidate copies into $1 (a temp dir).
render_overrides() {
  local d="$1" uf key rule want write _r
  uf="$(ufw_sysctl)"
  if [ -n "$uf" ]; then
    cp -p "$uf" "$d/ufw"
    local slash v
    while read -r key rule want write _r; do
      slash="${key//.//}"
      v="$(parse_assign "$uf" | awk -F'\t' -v k="$key" '$2 == k {v=$3} END {print v}')"
      if [ -z "$v" ] || ok_rule "$rule" "$want" "$v"; then continue; fi
      # rewrite every `key=value` / `key/with/slashes=value` assignment line of this key
      sed -i -E "s#^([[:space:]]*-?(${key//./\\.}|${slash})[[:space:]]*=[[:space:]]*).*#\1${write}#" "$d/ufw"
    done < <(profile_lines)
    cmp -s "$uf" "$d/ufw" || printf '%s\t%s\n' "$uf" "$d/ufw"
  fi
  if [ -z "${KEEP_APPORT:-}" ] && apport_sets_dumpable && has_key fs.suid_dumpable; then
    if [ -f "$APPORT_DEFAULT" ]; then cp -p "$APPORT_DEFAULT" "$d/apport"; else : >"$d/apport"; fi
    if grep -qE '^[[:space:]]*enabled=' "$d/apport"; then sed -i -E 's/^([[:space:]]*enabled=).*/\10/' "$d/apport"
    else printf 'enabled=0\n' >>"$d/apport"; fi
    printf '%s\t%s\n' "$APPORT_DEFAULT" "$d/apport"
  fi
  return 0
}

do_apply() {
  local dry="$1" new cur key v n=0 ts bk od ovr orig cand i=0
  [ -d "$(dirname "$CONF_FILE")" ] || die "$(dirname "$CONF_FILE") missing"
  has_key net.ipv4.ip_forward && [ "$(get_key net.ipv4.ip_forward)" != 1 ] && [ -z "${ALLOW_NO_FORWARD:-}" ] &&
    die "Docker guard: net.ipv4.ip_forward=$(get_key net.ipv4.ip_forward) (expected 1); refusing to apply"
  new="$(mktemp)"; render_conf >"$new"
  echo "== dry-run diff (runtime -> target)"
  while IFS= read -r line; do
    [[ "$line" == \#* ]] && continue
    key="${line%% = *}"; v="${line#* = }"; cur="$(get_key "$key")"
    if [ "$cur" != "$v" ]; then printf '  %-45s %s -> %s\n' "$key" "$cur" "$v"; n=$((n + 1)); fi
  done <"$new"
  echo "  $n runtime value(s) change"
  echo "== diff -u ${CONF_FILE}"
  diff -u --label "$CONF_FILE (current)" --label "$CONF_FILE (new)" \
    "$( [ -f "$CONF_FILE" ] && echo "$CONF_FILE" || echo /dev/null)" "$new" | sed 's/^/  /' || true
  od="$(mktemp -d)"; ovr="$(render_overrides "$od")"
  while IFS=$'\t' read -r orig cand; do
    [ -n "$orig" ] || continue
    echo "== boot override: diff -u $orig"
    diff -u --label "$orig (current)" --label "$orig (new)" "$( [ -f "$orig" ] && echo "$orig" || echo /dev/null)" "$cand" | sed 's/^/  /' || true
  done <<<"$ovr"
  if [ "$dry" = 1 ]; then rm -rf "$new" "$od"; echo "dry-run: nothing written"; return 0; fi
  if [ "$n" -eq 0 ] && [ -z "$ovr" ] && [ -f "$CONF_FILE" ] && cmp -s "$CONF_FILE" "$new"; then
    # no backup here: it would hold the hardened values and make `rollback` a no-op
    rm -rf "$new" "$od"; echo "already applied: no runtime change, conf identical, no boot overrides - nothing written, no new backup"; return 0
  fi

  ts="$(date -u +%Y%m%dT%H%M%SZ)"; install -d -m 700 "$BACKUP_DIR"; bk="$BACKUP_DIR/sysctl-$ts.tsv"
  ( umask 077
    while read -r key _; do has_key "$key" && printf '%s\t%s\n' "$key" "$(get_key "$key")"; done < <(profile_lines) >"$bk"
    if [ -f "$CONF_FILE" ]; then cp -p "$CONF_FILE" "$bk.conf"; fi
    # other files edited: path list in $bk.files (backup<TAB>path; backup "-" = file did not exist)
    : >"$bk.files"
    while IFS=$'\t' read -r orig cand; do
      [ -n "$orig" ] || continue; i=$((i + 1))
      if [ -f "$orig" ]; then cp -p "$orig" "$bk.f$i"; printf '%s\t%s\n' "$bk.f$i" "$orig"; else printf -- '-\t%s\n' "$orig"; fi
    done <<<"$ovr" >"$bk.files" )
  echo "== backup: $bk ($(wc -l <"$bk") keys)$( [ -f "$bk.conf" ] && echo " + previous conf")$( [ -s "$bk.files" ] && echo " + $(wc -l <"$bk.files") boot-override file(s)")"
  install -m 644 "$new" "$CONF_FILE"; rm -f "$new"
  while IFS=$'\t' read -r orig cand; do
    [ -n "$orig" ] || continue
    # in place (cat >) keeps owner, mode and inode of the original
    if [ -f "$orig" ]; then cat "$cand" >"$orig"; else install -m 644 "$cand" "$orig"; fi
    echo "== edited boot override $orig"
  done <<<"$ovr"
  rm -rf "$od"
  echo "== wrote $CONF_FILE; running: ${SYSCTL_SYSTEM[*]}"
  "${SYSCTL_SYSTEM[@]}" >/dev/null || die "${SYSCTL_SYSTEM[*]} failed (rollback: $0 rollback --from $bk)"
  if has_key net.ipv4.ip_forward && [ "$(get_key net.ipv4.ip_forward)" != 1 ] && [ -z "${ALLOW_NO_FORWARD:-}" ]; then
    set_key net.ipv4.ip_forward 1
    die "Docker guard: ip_forward was 0 after ${SYSCTL_SYSTEM[*]}; set back to 1 - fix the sysctl.d file that sets it"
  fi
  echo "== applied; re-check:"
}

do_rollback() {
  local bk="$1" key v n=0
  [ -n "$bk" ] || bk="$(find "$BACKUP_DIR" -maxdepth 1 -name 'sysctl-*.tsv' 2>/dev/null | LC_ALL=C sort | tail -1)"
  if [ -z "$bk" ] || [ ! -f "$bk" ]; then die "no backup found in $BACKUP_DIR"; fi
  echo "== rollback from $bk"
  while IFS=$'\t' read -r key v; do
    has_key "$key" || continue
    if [ "$(get_key "$key")" != "$v" ]; then
      set_key "$key" "$v" || log "WARN: could not restore $key=$v"
      printf '  %-45s -> %s\n' "$key" "$v"; n=$((n + 1))
    fi
  done <"$bk"
  echo "  $n value(s) restored"
  if [ -f "$bk.conf" ]; then cp -p "$bk.conf" "$CONF_FILE"; echo "  restored previous $CONF_FILE"
  elif [ -f "$CONF_FILE" ]; then rm -f "$CONF_FILE"; echo "  removed $CONF_FILE"; fi
  local src dst
  if [ -f "$bk.files" ]; then
    while IFS=$'\t' read -r src dst; do
      if [ "$src" = - ]; then rm -f "$dst"; echo "  removed $dst"
      else cat "$src" >"$dst"; touch -r "$src" "$dst"; echo "  restored $dst"; fi
    done <"$bk.files"
  fi
}

# ---------- load (sandbox stand-in for sysctl --system against PROC_SYS) ----------
do_load() {
  local f k v
  while IFS=$'\t' read -r f k v; do
    [[ "$k" == *'*'* ]] && continue
    has_key "$k" && { set_key "$k" "$v" 2>/dev/null || true; }
  done < <(assignments)
}

mode="${1:-check}"; [ $# -gt 0 ] && shift
JSON=0 DRY=0 FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;; --dry-run) DRY=1 ;; --from) FROM="${2:?--from FILE}"; shift ;;
    -h|--help) usage 0 ;; *) usage 2 ;;
  esac; shift
done

case "$mode" in
  check) run_checks; report "$JSON" ;;
  profile) profile_lines | while read -r k r w s rat; do printf '%-45s %s %-2s write %-2s %s\n' "$k" "$r" "$w" "$s" "$rat"; done ;;
  apply) [ "$DRY" = 1 ] || [ "$(id -u)" = 0 ] || [ -n "${PFT_SYSCTL_SANDBOX:-}" ] || die "apply needs root"
         do_apply "$DRY"; [ "$DRY" = 1 ] && exit 0; run_checks; report "$JSON" ;;
  rollback) [ "$(id -u)" = 0 ] || [ -n "${PFT_SYSCTL_SANDBOX:-}" ] || die "rollback needs root"
            do_rollback "$FROM" ;;
  _load) do_load ;;
  -h|--help|help) usage 0 ;;
  *) usage 2 ;;
esac
