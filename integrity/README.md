# File and image integrity monitor (`pft-integrity.sh`)

[`audit/`](../audit/README.md) checks how a host is hardened and [`secrets/`](../secrets/README.md) checks where
secrets could leak. Both describe the host at one moment. Neither notices when something changes later, such as an
edited script, a loosened file mode, a new firewall rule or a swapped image. `pft-integrity.sh` covers that drift.
`baseline` records a manifest of the host. `verify` compares the live host with it item by item, prints
PASS/WARN/FAIL for each item and names only the fields that changed.

It only reads. It never changes the files, the firewall or the containers it checks. The only files it writes are
its own state files in `/var/lib/pft-integrity/` (directory 0700, files 0600, root only).

```bash
sudo install -m 755 integrity/pft-integrity.sh /usr/local/bin/pft-integrity
sudo pft-integrity baseline                      # once, after the host is in its known-good state
sudo pft-integrity verify                        # text; add --json for machine output, --verbose to list PASS items
sudo pft-integrity accept --reason "upgrade to 1.0.9 via upgrade/"   # after an intended change
sudo pft-integrity manifest-sha                  # copy this value off the host (see Known limits)
sudo pft-integrity verify --expect-sha <sha>     # also FAIL if the manifest itself was replaced
```

Exit codes: `0` all PASS, `1` at least one WARN, `2` at least one FAIL, `3` usage error or no baseline.

## What is protected

| Item id | Source | Fields stored |
|---------|--------|---------------|
| `compose:<file>` | `docker-compose*.yml`, `compose*.yml` and `.env` in the container's compose project dir (`COMPOSE_DIR` overrides) | sha256, mode, owner, mtime |
| `cfgvol:<file>` | every file in the volume mounted at `/etc/postfiatd` (`postfiatd.cfg`, `validators.txt`, ...) | sha256, mode, owner, mtime (**never contents**) |
| `unit:<name>` | `/etc/systemd/system/pft-*` and `postfiat-*` `.service`/`.timer` (the add-ons in this repo) | sha256, mode, owner, mtime |
| `bin:<name>` | every regular file in `/usr/local/bin` (`postfiat-health`, `postfiat-monitor`, this script, ...) | sha256, mode, owner, mtime |
| `sshd:...` | `/etc/ssh/sshd_config`, `/etc/ssh/sshd_config.d/*`, plus `sshd:effective` = hash of `sshd -T` | sha256, mode, owner, mtime |
| `fw:ufw` | `ufw show added` + `Status:`/`Default:` lines of `ufw status verbose` (no counters) | rule count, sha256 |
| `fw:docker-user` | `iptables -S DOCKER-USER` + `ip6tables -S DOCKER-USER` | rule count, sha256 |
| `image:running` | running postfiatd container: configured ref, image id, local repo digest | values |
| `image:registry` | Docker Hub manifest digest of the running tag (anonymous `HEAD`, not rate-limited) vs the local digest | `matches_local` yes/no/unknown |
| `image:local:<repo:tag>` | every tagged local image | short image id |
| `container:<name>` | effective config of the postfiatd container: image, privileged, restart policy, and hashes of cmd, entrypoint, env, user, mounts, port bindings, cap_add/cap_drop, read-only rootfs, security_opt, network/pid mode, devices, labels | values / 16-hex hashes |

The manifest stores only hashes, modes, owners, mtimes, rule counts and image ids. Env values, port bindings and
config contents are stored as hashes, so the manifest can't leak them. Default text output shows only items that
are not PASS. Add `--verbose` to list every item.

## Severity

| Change | Status |
|--------|--------|
| item removed (file deleted, container gone) | FAIL |
| content changed (`sha256`), owner changed, any container field, firewall rule count/hash, running image id/digest | FAIL |
| mode change that **adds** a group/other permission bit (e.g. `600->644`) | FAIL |
| mode tightened, mtime-only change (e.g. `touch`) | WARN |
| new item (new file in a watched dir, new local image tag) | WARN |
| registry tag no longer matches the local image (upstream published a new build) | WARN |
| registry unreachable | ignored (`unknown` is never treated as a change) |
| `--expect-sha` given and the manifest hash differs | FAIL (`manifest`) |

## Hourly timer with change-only ntfy

```bash
sudo install -m 644 integrity/pft-integrity.service integrity/pft-integrity.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pft-integrity.timer
```

`pft-integrity.service` runs `verify --notify` once an hour (`RandomizedDelaySec=300`, idle I/O class). WARN and FAIL
exits count as success (`SuccessExitStatus=1 2`) because the alert goes out through ntfy, not through systemd.

`--notify` keeps a fingerprint of the current findings (status plus a hash of the finding lines) in
`/var/lib/pft-integrity/last-notify`. It sends one ntfy message only when the fingerprint changes:
clean → tampered, one set of findings → another, or tampered → clean (the recovery message).
A repeat run with the same findings sends nothing. A first run that is clean only records its state.
If delivery fails, the state is left as it was, so the next run tries again.

ntfy settings are read from `/etc/pft-integrity.env`, or from `/etc/postfiat-monitor.env` if that file does not exist:
`NTFY_SERVER`, `NTFY_TOPIC`, `NTFY_TOKEN`, `NODE_LABEL`. The file is parsed as `KEY=VALUE` data and never sourced.
It is ignored unless it is root-owned and not writable by group or others. Keep it at mode 0600. Use a generic
`NODE_LABEL` (e.g. `validator-host`) so the alerts don't reveal the hostname.

## Handling findings

| Finding | What to do |
|---------|------------|
| `bin:` / `unit:` changed `sha256` | `git diff` against this repo, or reinstall the add-on. If you can't explain the change, treat the host as compromised: rotate the validator token on a clean machine and rebuild. |
| `compose:` / `cfgvol:` changed `sha256` | Compare with your backup (`backup/`). An unexpected `postfiatd.cfg` change (new `[port_*]`, `admin =`, `[ips_fixed]`) can expose admin RPC or change peering. Run `secrets/` and `audit/`. |
| any `mode` loosened (FAIL) | `chmod` it back (e.g. `600` for `.env` and sshd drop-ins), then find out who changed it (`journalctl`, shell history). |
| `sshd:*` changed | `sshd -T` and compare. Re-run `audit/ --only ssh.` before you close the session. |
| `fw:*` rules changed | `ufw status numbered` / `iptables -S DOCKER-USER`. A rule that nobody added is a strong compromise signal. |
| `image:running` / `container:` changed | Was there a planned upgrade (`upgrade/`)? If not, check `docker events` and `logscan/restart-crosscheck.py` for who recreated the container. |
| `image:local:*` added | A pulled image is not running yet. Remove it unless you pulled it on purpose (`docker rmi`). |
| `image:registry` `yes->no` | A new upstream build was published under your tag. Read the release notes, then upgrade with `upgrade/` and `accept`. |
| `manifest` (with `--expect-sha`) | Someone re-baselined. Check `accept.log`. If no one did, assume root was compromised. |

After every intended change, run `accept --reason "..."`. It rewrites the manifest and appends
`time, by=<sudo user>, old sha, new sha, reason` to the 0600 `accept.log`. A plain `baseline` refuses to overwrite.

## Known limits

- **Root can rewrite the baseline.** An attacker with root can edit the manifest, `accept`, or replace this script.
  To mitigate this, copy `pft-integrity manifest-sha` off the host after each `accept`, and run
  `verify --expect-sha <sha>` from your own machine (`ssh host sudo pft-integrity verify --expect-sha ...`).
  For stronger protection, run the checker from a read-only medium or another host. Nothing on the host itself can
  fully defend against a root attacker.
- **Point-in-time.** The timer runs hourly. A change made and reverted within the hour, or with the mtime restored,
  is not seen. Use auditd/fanotify if you need real-time detection.
- **Scope is the deploy surface.** The checker does not cover package binaries (use `debsums`/`dpkg --verify`),
  the kernel, `/etc/passwd`, cron, or the contents of the ledger DB.
- **Registry check is Docker Hub only.** For other registries `image:registry` is `unknown`. `matches_local` compares
  the tag's current digest. It does not check signatures.
- **Docker-managed rules.** Docker rewrites its own `DOCKER*` chains on restart. Only `DOCKER-USER` (operator-owned)
  is tracked.

## Tamper drill (proof)

[`drill.sh`](drill.sh) makes four reversible changes, runs `verify --notify` twice, reverts the changes, and runs it
twice more. It never touches the running postfiatd container.

1. Appends a comment line to a script (`DRILL_SCRIPT`). The backup is restored byte-for-byte with its mtime.
2. Runs `chmod 644` on a 0600 file (`DRILL_600`), then restores the mode.
3. Adds a no-op rule to DOCKER-USER: `-A ... -m comment --comment pft-integrity-drill -j RETURN`. The rule sits
   after the chain's own end and changes no verdict. It is deleted afterwards.
4. Pulls a different tag of the node image (`agtipft/postfiatd:testnet-light-1.0.8`, never run) and removes it afterwards.

Logs from both hosts (Ubuntu 22.04.5, 2026-10-22) are in [`../logs/integrity/`](../logs/integrity/):

| Log | Host | Shows |
|-----|------|-------|
| `1-validator-drill.log` | validator | shellcheck, install, baseline (36 items, manifest 600 root), clean verify text+json, drill: 4/4 DETECTED with the right item+field, 1 ntfy on change, none on the unchanged repeat, revert, clean verify + 1 recovery ntfy, then none |
| `2-sentry-drill.log` | sentry | same on the sentry (17 items, no compose project); the sha256 of the copied files equals the files in this commit |
| `3-timer.log` | both | `enable --now pft-integrity.timer`, one run through the unit (`Result=success`, unchanged → no ntfy) |
| `4-accept.log` | validator | `manifest-sha`, `baseline` refusing to overwrite, `accept` without/with `--reason`, accept.log line, `--expect-sha` FAIL on a stale sha and PASS on the new one |

Notes: before the sentry run, `drill.sh` gained a `>/dev/null` on its `iptables -C/-D` calls. In log 1 (validator)
the cleanup's `iptables -C` printed the rule once (`RETURN all ... /* pft-integrity-drill */`). Nothing else changed.
The validator drill used `postfiat-health` and the compose `.env` as targets. The sentry drill used the installed
`pft-integrity` itself and an sshd drop-in. The sentry's DOCKER-USER chain is empty by design, because its container
publishes the peer port on loopback only and nginx handles 2559 under UFW (see `sentry/`). The published logs redact
the operator's username (`<user>`) and the host's local timezone in `systemctl list-timers` (`<tz>`).
In log 2, the five lines printed on the validator before the ssh session (local sha256 of the same four files,
identical to the sentry's own lines) were dropped so that the log opens with the sentry's OS line.
