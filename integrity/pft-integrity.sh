#!/usr/bin/env bash
# pft-integrity: read-only file and image integrity monitor for a Post Fiat validator or sentry host.
#
# Closes the tamper/drift gap left by ../audit (one-off hardening checks) and ../secrets (exposure checks):
# `baseline` records a root-only 0600 manifest, `verify` compares the host against it item by item.
# Covered: compose files (+ .env), config-volume files (sha256 only, never contents), add-on systemd units,
# /usr/local/bin scripts, sshd_config(.d) + effective `sshd -T`, normalized UFW and DOCKER-USER rules,
# running image id/digest vs the registry manifest, local image tags, and the container's effective config.
# The manifest stores hashes, modes, owners and mtimes only. Output names changed items and fields only.
#
# Usage: sudo ./pft-integrity.sh baseline
#        sudo ./pft-integrity.sh verify [--json] [--notify] [--verbose] [--expect-sha SHA256]
#        sudo ./pft-integrity.sh accept --reason "why" [--json]
#        sudo ./pft-integrity.sh manifest-sha
#   baseline      write the manifest (refuses to overwrite one; use accept)
#   verify        PASS/WARN/FAIL per item: added / removed / changed (changed fields only)
#   accept        re-baseline after an intended change; logs time, who and why to accept.log
#   manifest-sha  print the manifest sha256 to keep OFF the host; verify --expect-sha checks it
#   --notify      send ntfy only when the set of findings changed since the previous --notify run
#   --verbose     also list unchanged (PASS) items
# Exit codes: 0 all PASS, 1 at least one WARN, 2 at least one FAIL, 3 usage error / no baseline.
# Env: CONTAINER (auto: first running agtipft/postfiatd container)  COMPOSE_DIR (compose label of the container)
#      STATE_DIR (/var/lib/pft-integrity)  NTFY_ENV (/etc/pft-integrity.env, else /etc/postfiat-monitor.env)
#      REGISTRY_CHECK (1; 0 skips the Docker Hub HEAD request)

set -uo pipefail
umask 077

STATE_DIR="${STATE_DIR:-/var/lib/pft-integrity}"
MANIFEST="$STATE_DIR/manifest.tsv"
ACCEPT_LOG="$STATE_DIR/accept.log"
LAST_NOTIFY="$STATE_DIR/last-notify"
REGISTRY_CHECK="${REGISTRY_CHECK:-1}"

CMD="${1:-}"; [ $# -gt 0 ] && shift
JSON=0 NOTIFY=0 VERBOSE=0 REASON="" EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --notify) NOTIFY=1 ;;
    --verbose) VERBOSE=1 ;;
    --reason) REASON="${2:?--reason needs text}"; shift ;;
    --expect-sha) EXPECT="${2:?--expect-sha needs a sha256}"; shift ;;
    -h|--help) CMD=help ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
  shift
done
case "$CMD" in
  baseline|verify|accept|manifest-sha) ;;
  help|"") sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown command: $CMD" >&2; exit 3 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run as root (reads root-only files, docker and iptables)" >&2; exit 3; }
for b in docker jq sha256sum stat iptables; do
  command -v "$b" >/dev/null || { echo "missing dependency: $b" >&2; exit 3; }
done
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
exec 9>"$STATE_DIR/.lock"
flock -w 120 9 || { echo "another pft-integrity run holds the lock" >&2; exit 3; }

OS_NAME="$(grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
h16() { sha256sum | cut -c1-16; }

# ---------- collectors: print "item<TAB>field<TAB>value" lines ----------
emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
file_item() { # file_item ITEM PATH
  [ -f "$2" ] || return 0
  local st; st="$(stat -c '%a %U:%G %Y' -- "$2")" || return 0
  emit "$1" sha256 "$(sha256sum -- "$2" | cut -d' ' -f1)"
  emit "$1" mode "${st%% *}"
  emit "$1" owner "$(cut -d' ' -f2 <<<"$st")"
  emit "$1" mtime "${st##* }"
}
CONTAINER="${CONTAINER:-$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /postfiatd/ {print $1; exit}')}"
INSPECT=""
[ -n "$CONTAINER" ] && INSPECT="$(docker inspect "$CONTAINER" 2>/dev/null | jq '.[0]')"

collect_compose() {
  local dir="${COMPOSE_DIR:-}" f
  [ -z "$dir" ] && [ -n "$INSPECT" ] &&
    dir="$(jq -r '.Config.Labels["com.docker.compose.project.working_dir"] // empty' <<<"$INSPECT")"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then emit compose:none present 0; return; fi
  for f in "$dir"/docker-compose*.yml "$dir"/docker-compose*.yaml "$dir"/compose*.yml "$dir"/compose*.yaml "$dir"/.env; do
    [ -f "$f" ] && file_item "compose:$(basename "$f")" "$f"
  done
}
collect_cfgvol() {
  [ -n "$INSPECT" ] || return 0
  local src f
  src="$(jq -r '.Mounts[] | select(.Destination=="/etc/postfiatd") | .Source' <<<"$INSPECT")"
  if [ -z "$src" ] || [ ! -d "$src" ]; then emit cfgvol:none present 0; return; fi
  while IFS= read -r -d '' f; do file_item "cfgvol:${f#"$src"/}" "$f"; done < <(find "$src" -type f -print0 | sort -z)
}
collect_files() {
  local f
  for f in /etc/systemd/system/pft-*.service /etc/systemd/system/pft-*.timer \
           /etc/systemd/system/postfiat-*.service /etc/systemd/system/postfiat-*.timer; do
    [ -f "$f" ] && file_item "unit:$(basename "$f")" "$f"
  done
  for f in /usr/local/bin/*; do [ -f "$f" ] && file_item "bin:$(basename "$f")" "$f"; done
  file_item sshd:sshd_config /etc/ssh/sshd_config
  for f in /etc/ssh/sshd_config.d/*; do [ -f "$f" ] && file_item "sshd:sshd_config.d/$(basename "$f")" "$f"; done
  command -v sshd >/dev/null && emit sshd:effective sha256 "$(sshd -T 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
}
collect_fw() {
  local r
  if command -v ufw >/dev/null; then
    # user rules + default policies; no packet counters, so the hash only moves when rules move
    r="$( { ufw show added 2>/dev/null | tail -n +2; ufw status verbose 2>/dev/null | grep -E '^(Status|Default):'; } )"
    emit fw:ufw rules "$(grep -c '^ufw ' <<<"$r")"
    emit fw:ufw sha256 "$(sha256sum <<<"$r" | cut -d' ' -f1)"
  fi
  r="$( { iptables -S DOCKER-USER 2>/dev/null; command -v ip6tables >/dev/null && ip6tables -S DOCKER-USER 2>/dev/null; } )"
  emit fw:docker-user rules "$(grep -c '^-A ' <<<"$r")"
  emit fw:docker-user sha256 "$(sha256sum <<<"$r" | cut -d' ' -f1)"
}
registry_digest() { # registry_digest REF -> manifest digest from Docker Hub (HEAD, not rate-limited), or "unknown"
  local ref="$1" repo tag tok d
  repo="${ref%:*}" tag="${ref##*:}"
  [ "$repo" = "$ref" ] && tag=latest
  case "$repo" in */*/*) echo unknown; return ;; */*) ;; *) repo="library/$repo" ;; esac
  tok="$(curl -fsS -m 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" | jq -r .token 2>/dev/null)"
  if [ -z "$tok" ] || [ "$tok" = null ]; then echo unknown; return; fi
  d="$(curl -fsSI -m 10 -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://registry-1.docker.io/v2/$repo/manifests/$tag" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')"
  echo "${d:-unknown}"
}
collect_images() {
  local ref id local_d reg
  if [ -n "$INSPECT" ]; then
    ref="$(jq -r '.Config.Image' <<<"$INSPECT")"
    id="$(jq -r '.Image' <<<"$INSPECT")"
    local_d="$(docker image inspect "$id" --format '{{json .RepoDigests}}' 2>/dev/null |
      jq -r --arg r "${ref%:*}" '[.[] | select(startswith($r + "@"))][0] // "none" | sub(".*@"; "")')"
    emit image:running ref "$ref"
    emit image:running id "$id"
    emit image:running repo_digest "$local_d"
    if [ "$REGISTRY_CHECK" = 1 ]; then
      reg="$(registry_digest "$ref")"
      if [ "$reg" = unknown ]; then emit image:registry matches_local unknown
      elif [ "$reg" = "$local_d" ] || [ "$reg" = "$id" ]; then emit image:registry matches_local yes
      else emit image:registry matches_local no; fi
    fi
  fi
  # every tagged local image: a pulled/retagged/replaced image shows up as added/changed
  docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | awk '$1 !~ /<none>/' | sort |
    while read -r ref id; do emit "image:local:$ref" id "$id"; done
}
collect_container() {
  [ -n "$INSPECT" ] || { emit container:none present 0; return; }
  local it="container:$CONTAINER" f q
  emit "$it" image "$(jq -r '.Config.Image' <<<"$INSPECT")"
  emit "$it" privileged "$(jq -r '.HostConfig.Privileged' <<<"$INSPECT")"
  emit "$it" restart "$(jq -r '.HostConfig.RestartPolicy.Name' <<<"$INSPECT")"
  # remaining fields are stored as hashes: env values and bindings never land in the manifest
  for f in cmd:.Config.Cmd entrypoint:.Config.Entrypoint env:.Config.Env user:.Config.User \
           mounts:'[.Mounts[]|{Type,Source,Destination,RW}]|sort_by(.Destination)' ports:.HostConfig.PortBindings \
           cap_add:.HostConfig.CapAdd cap_drop:.HostConfig.CapDrop readonly_rootfs:.HostConfig.ReadonlyRootfs \
           security_opt:.HostConfig.SecurityOpt network_mode:.HostConfig.NetworkMode pid_mode:.HostConfig.PidMode \
           devices:.HostConfig.Devices labels:.Config.Labels; do
    q="${f#*:}"
    emit "$it" "${f%%:*}" "$(jq -cS "$q" <<<"$INSPECT" | h16)"
  done
}
collect_all() {
  { collect_compose; collect_cfgvol; collect_files; collect_fw; collect_images; collect_container; } | LC_ALL=C sort -u
}

# ---------- commands ----------
manifest_sha() { sha256sum "$MANIFEST" | cut -d' ' -f1; }
write_manifest() {
  local tmp; tmp="$(mktemp "$STATE_DIR/.manifest.XXXXXX")"
  { echo "# pft-integrity manifest $(now) container=${CONTAINER:-none}"; collect_all; } >"$tmp"
  chmod 600 "$tmp" && mv -f "$tmp" "$MANIFEST"
}
count_items() { grep -v '^#' "$MANIFEST" | cut -f1 | sort -u | wc -l; }
summary_by_kind() { grep -v '^#' "$MANIFEST" | cut -f1 | sort -u | cut -d: -f1 | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}'; }

if [ "$CMD" = manifest-sha ]; then
  [ -f "$MANIFEST" ] || { echo "no baseline at $MANIFEST" >&2; exit 3; }
  manifest_sha; exit 0
fi
if [ "$CMD" = baseline ]; then
  [ -f "$MANIFEST" ] && { echo "baseline exists; use: accept --reason \"...\"" >&2; exit 3; }
  write_manifest
  echo "pft-integrity baseline - $(now)"
  echo "OS: $OS_NAME | container: ${CONTAINER:-none}"
  echo "manifest: mode $(stat -c '%a %U' "$MANIFEST"), $(count_items) items: $(summary_by_kind)"
  echo "manifest sha256: $(manifest_sha)  (keep a copy off-host; verify --expect-sha checks it)"
  exit 0
fi
if [ "$CMD" = accept ]; then
  [ -n "$REASON" ] || { echo "accept needs --reason \"why\"" >&2; exit 3; }
  [ -f "$MANIFEST" ] || { echo "no baseline at $MANIFEST; run baseline first" >&2; exit 3; }
  old="$(manifest_sha)"
  write_manifest
  new="$(manifest_sha)"
  printf '%s\tby=%s\told=%s\tnew=%s\treason=%s\n' "$(now)" "${SUDO_USER:-$(id -un)}" "$old" "$new" \
    "$(tr '\t\n' '  ' <<<"$REASON")" >>"$ACCEPT_LOG"
  chmod 600 "$ACCEPT_LOG"
  echo "pft-integrity accept - $(now): re-baselined $(count_items) items by ${SUDO_USER:-$(id -un)}"
  echo "manifest sha256: $old -> $new (logged to accept.log)"
  exit 0
fi

# ---------- verify ----------
[ -f "$MANIFEST" ] || { echo "no baseline at $MANIFEST; run: $0 baseline" >&2; exit 3; }
CUR="$(collect_all)"
BASE="$(grep -v '^#' "$MANIFEST")"
NP=0 NW=0 NF=0
FINDINGS=()   # "STATUS<TAB>item<TAB>change<TAB>detail"
add() { FINDINGS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); case "$1" in WARN) NW=$((NW + 1)) ;; FAIL) NF=$((NF + 1)) ;; esac; }

if [ -n "$EXPECT" ]; then
  if [ "$(manifest_sha)" = "$EXPECT" ]; then NP=$((NP + 1)); else
    add FAIL manifest changed "sha256 differs from --expect-sha (baseline replaced or edited)"; fi
fi
items="$(printf '%s\n%s\n' "$BASE" "$CUR" | cut -f1 | grep -v '^$' | LC_ALL=C sort -u)"
while IFS= read -r it; do
  b="$(awk -F'\t' -v i="$it" '$1==i {print $2"\t"$3}' <<<"$BASE")"
  c="$(awk -F'\t' -v i="$it" '$1==i {print $2"\t"$3}' <<<"$CUR")"
  if [ -z "$b" ]; then
    case "$it" in compose:*|cfgvol:*|unit:*|bin:*|sshd:*) add WARN "$it" added "new file" ;; *) add WARN "$it" added "new item" ;; esac
    continue
  fi
  if [ -z "$c" ]; then add FAIL "$it" removed "missing since baseline"; continue; fi
  [ "$b" = "$c" ] && { NP=$((NP + 1)); [ "$VERBOSE" = 1 ] && FINDINGS+=("PASS"$'\t'"$it"$'\t'unchanged$'\t'); continue; }
  sev=WARN det=()
  while IFS=$'\t' read -r fld bv; do
    cv="$(awk -F'\t' -v f="$fld" '$1==f {print $2}' <<<"$c")"
    [ "$bv" = "$cv" ] && continue
    case "$it:$fld" in
      image:registry:matches_local)
        [ "$cv" = unknown ] && continue   # registry unreachable: not a change
        det+=("registry tag no longer matches the local image ($bv->$cv)") ;;
      *:mode)
        det+=("mode $bv->$cv")
        # FAIL when group/other gained any permission bit
        [ $(( 8#$cv & ~8#$bv & 8#077 )) -ne 0 ] && sev=FAIL ;;
      *:mtime) det+=("mtime") ;;
      *:rules) det+=("rules $bv->$cv"); sev=FAIL ;;
      *) det+=("$fld"); sev=FAIL ;;
    esac
  done <<<"$b"
  # fields that exist only in the current scan
  while IFS=$'\t' read -r fld _; do
    grep -q "^$fld"$'\t' <<<"$b" || { det+=("$fld (new field)"); sev=FAIL; }
  done <<<"$c"
  if [ "${#det[@]}" -eq 0 ]; then NP=$((NP + 1)); continue; fi
  d="$(IFS=,; echo "${det[*]}")"
  add "$sev" "$it" changed "${d//,/, }"
done <<<"$items"

RC=0; [ "$NW" -gt 0 ] && RC=1; [ "$NF" -gt 0 ] && RC=2
STATUS=PASS; [ "$RC" = 1 ] && STATUS=WARN; [ "$RC" = 2 ] && STATUS=FAIL
jesc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

if [ "$JSON" = 1 ]; then
  js=()
  for f in "${FINDINGS[@]}"; do
    IFS=$'\t' read -r s i ch d <<<"$f"
    js+=("{\"status\":\"$s\",\"item\":\"$(jesc "$i")\",\"change\":\"$ch\",\"detail\":\"$(jesc "$d")\"}")
  done
  printf '{"time":"%s","os":"%s","status":"%s","pass":%d,"warn":%d,"fail":%d,"exit":%d,"findings":[%s]}\n' \
    "$(now)" "$(jesc "$OS_NAME")" "$STATUS" "$NP" "$NW" "$NF" "$RC" "$(IFS=,; echo "${js[*]}")"
else
  echo "pft-integrity verify - $(now)"
  echo "OS: $OS_NAME | container: ${CONTAINER:-none} | baseline: $(head -1 "$MANIFEST" | awk '{print $4}')"
  for f in "${FINDINGS[@]}"; do
    IFS=$'\t' read -r s i ch d <<<"$f"
    printf '  [%s] %-44s %-8s %s\n' "$s" "$i" "$ch" "$d"
  done
  echo "RESULT: $STATUS - $NP unchanged, $NW warn, $NF fail -> exit $RC"
fi

# ---------- change-only ntfy ----------
if [ "$NOTIFY" = 1 ]; then
  key="$STATUS $(printf '%s\n' "${FINDINGS[@]}" | grep -v '^PASS' | sha256sum | cut -c1-16)"
  prev="$(cat "$LAST_NOTIFY" 2>/dev/null || echo none)"
  if [ "$key" = "$prev" ]; then
    echo "ntfy: findings unchanged since last run ($STATUS) - not sent" >&2
  elif [ "$prev" = none ] && [ "$STATUS" = PASS ]; then
    echo "ntfy: first run and clean - state recorded, not sent" >&2
    echo "$key" >"$LAST_NOTIFY"
  else
    env_file="${NTFY_ENV:-/etc/pft-integrity.env}"
    [ -f "$env_file" ] || env_file=/etc/postfiat-monitor.env
    NTFY_SERVER=https://ntfy.sh NTFY_TOPIC="" NTFY_TOKEN="" NODE_LABEL=postfiat-node
    if [ -f "$env_file" ]; then
      if [ "$(stat -c '%u' "$env_file")" = 0 ] && [ $(( 8#$(stat -c '%a' "$env_file") & 8#022 )) -eq 0 ]; then
        # parse KEY=VALUE lines; never source (the file is data, not code)
        while IFS='=' read -r k v; do
          case "$k" in NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN|NODE_LABEL) printf -v "$k" '%s' "${v//\"/}" ;; esac
        done < <(grep -E '^(NTFY_SERVER|NTFY_TOPIC|NTFY_TOKEN|NODE_LABEL)=' "$env_file")
      else
        echo "ntfy: $env_file must be root-owned and not group/other-writable - not used" >&2
      fi
    fi
    if [ -z "$NTFY_TOPIC" ]; then
      echo "ntfy: no NTFY_TOPIC configured - not sent (state not updated)" >&2
    else
      if [ "$STATUS" = PASS ]; then msg="integrity back to baseline ($NP items unchanged)"
      else msg="$(printf '%s\n' "${FINDINGS[@]}" | grep -v '^PASS' | head -10 | awk -F'\t' '{print $1" "$2" "$3": "$4}')"; fi
      args=(-fsS -m 15 -H "Title: pft-integrity $NODE_LABEL: $STATUS ($NW warn, $NF fail)" -d "$msg")
      [ "$STATUS" = FAIL ] && args+=(-H "Priority: high")
      [ -n "$NTFY_TOKEN" ] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
      if curl "${args[@]}" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null; then
        echo "$key" >"$LAST_NOTIFY"; echo "ntfy: status change ($prev -> $key) - sent" >&2
      else
        echo "ntfy: delivery failed - will retry next run" >&2
      fi
    fi
  fi
fi
exit "$RC"
