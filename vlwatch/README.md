# pft-vlwatch: validator-list (UNL) health check

A node only trusts validations from its UNL, and it gets that list from a signed publisher list
(`[validator_list_sites]` / `[validator_list_keys]`). When that list expires, stops refreshing or is replaced by an
older sequence, the node can lose quorum while `server_state` still says `full` and peers look fine. That is the
case the `monitor/`, `alerts/` and `watchdog/` add-ons cannot see. `pft-vlwatch` checks the list itself.

It is read-only. It calls `validator_list_sites`, `validators` and `server_info` on the node's local admin RPC
through `docker exec <container> curl` (the admin port is only bound inside the container) and changes nothing on
the node. The only file it writes is its state file.

## Checks

| check | PASS | WARN | FAIL |
|---|---|---|---|
| `rpc` | all three methods answer `status=success` | | any method missing, non-JSON (e.g. `Forbidden`) or `error` (other checks are skipped) |
| `sites` | at least one validator-list site | | no site configured |
| `site_status:<uri>` | `last_refresh_status` is `accepted` or `same_sequence` | never refreshed | any other status (`invalid`, `expired`, `untrusted`, `stale`, `unsupported_version`, ...), with `last_refresh_message` |
| `site_fresh:<uri>` | last refresh within `REFRESH_MULT` x `refresh_interval_min` (default 3 x 5 min) | up to 2x that | older |
| `site_cover:<pub>` | the publisher list's `uri` is a configured site | the list is not fetched from any configured site | |
| `available:<pub>` | `available=true` | | `available=false` |
| `expiry:<pub>` | >= `--warn-days` (30) days left | < 30 days | < `--crit-days` (7) days, or expired |
| `seq:<pub>` | seq >= saved high-water mark (first run records it) | no seq reported | seq lower than saved (rollback) |
| `list_status` | `validator_list.status=active` | | anything else (`expired`, `unknown`, missing) |
| `trusted_keys` | trusted key count = sum of available list lengths | fewer than the list length | 0, or fewer than `validation_quorum` |
| `amendment_blocked` | absent / false | | `true` (upgrade postfiatd) |

`<pub>` is the first 16 hex characters of the publisher key. Days are whole days rounded toward zero, so a list
that expires in 23 hours reads `0 day(s) left` (FAIL) and one that expired 47 hours ago reads `EXPIRED 1 day(s) ago`.

The state file (default `/var/lib/pft-vlwatch/state.json`) keeps the highest seq seen per publisher. It is never
lowered, so a rollback keeps failing until the list is back at or above the high-water mark. If the publisher
legitimately resets its sequence, delete the state file after you have checked the new list.

Exit codes: `0` all PASS, `1` any WARN, `2` any FAIL (including RPC unreachable), `3` usage error.

## Usage

```bash
sudo bash vlwatch/pft-vlwatch.sh                                   # validator (container postfiatd)
sudo bash vlwatch/pft-vlwatch.sh --container postfiatd-sentry      # sentry
sudo bash vlwatch/pft-vlwatch.sh --json                            # machine-readable
sudo bash vlwatch/pft-vlwatch.sh --warn-days 45 --crit-days 10 --refresh-mult 2
bash vlwatch/pft-vlwatch.sh --fixtures DIR --now EPOCH --state /tmp/s.json   # offline, from saved RPC JSON
```

`--fixtures DIR` reads `validator_list_sites.json`, `validators.json` and `server_info.json` from DIR instead of
the node. The tests and the drill use it.

## Change-only ntfy timer (optional)

```bash
sudo vlwatch/install.sh --timer --ntfy-env ./ntfy.env --container postfiatd --label validator-host
sudo pft-integrity accept --reason "pft-vlwatch installed"   # if the integrity add-on is installed
```

- `ntfy.env` (see `ntfy.env.example`: `NTFY_SERVER`, `NTFY_TOPIC`, optional `NTFY_TOKEN`) is installed as
  `/etc/pft-vlwatch/ntfy.env`, root 0600. pft-vlwatch refuses to send if the file is not root-owned with no
  group/other permissions. The URL and token go to curl through a config on a file descriptor, never through argv
  or the environment.
- `pft-vlwatch.timer` runs `pft-vlwatch.service` (oneshot, exit 1/2 counted as success) 5 min after boot and then
  every 10 min. `/etc/pft-vlwatch/vlwatch.env` sets the container, extra flags and the label shown in titles.
- Change-only: a message is sent when the overall verdict or the set of non-PASS checks changes, including
  `RECOVERED` on the way back to PASS. Priority is `high` for FAIL, `default` for WARN and `low` for recovery. The
  first run is silent if it passes. The new signature is saved only after a successful send, so a failed send is
  retried on the next run.
- `sudo vlwatch/install.sh --uninstall` removes the script, units and state, and keeps `/etc/pft-vlwatch`.

## Tests and drill

- `bash vlwatch/tests/run-tests.sh` runs offline, with no node, network or ntfy (`NTFY_OUTBOX` captures messages).
  The positive control is `tests/fixtures/recorded-validator/`, real answers recorded from the validator host
  (server_info trimmed to the fields the check reads, recording time in `NOW`). Each negative case is that
  recording plus one jq mutation: expired, expiring (WARN/FAIL), refresh error, never refreshed, stale refresh,
  missing site, seq rollback/advance, unavailable, trusted keys short / below quorum / zero, amendment_blocked,
  missing / non-JSON / error RPC, the change-only notification sequence, the env-file guard and usage errors. A
  harness self-check confirms that a wrong expectation is reported.
- `sudo bash vlwatch/drill.sh` captures the live RPC answers, runs them (PASS, silent), injects an expired list, a
  refresh error and a seq rollback (FAIL, one message), runs again (silent), then reads the throwaway topic back
  from ntfy.sh and requires exactly one message. The topic is random and printed as `<redacted>`. The drill's
  env file lives in a temp dir, so the operator's `/etc/pft-vlwatch` is never read.

Logs: [`../logs/vlwatch/`](../logs/vlwatch/).
