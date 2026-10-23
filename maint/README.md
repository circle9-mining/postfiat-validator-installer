# pft-maint: planned-maintenance windows

A planned `postfiatd` restart on the validator trips three alerters: the [watchdog](../watchdog/README.md) on the
sentry raises LAGGING/STALE, the [ntfy health monitor](../monitor/) raises UNHEALTHY, and an image or config change
makes the [integrity monitor](../integrity/README.md) WARN. Before this add-on, the only way to keep those pages
off the operator's phone was to hand-edit alert targets and remember to put them back. `pft-maint` replaces that
with a time-boxed flag that every alerter checks, and a guarded `restart-node` that only runs inside a window.

```
validator host                                              sentry host
pft-maint start --ttl 30m --reason "..."
  /var/lib/pft-maint/flag.json (root 0644)
  [MAINT] start  -> ntfy (exactly one)
  signed {"type":"maint"} -> ssh pftwd@sentry  ---------->  forced command `pft-watchdog receive` -> spool
                                                            pft-watchdog check (root): HMAC ok -> pft-maint apply-remote
                                                              /var/lib/pft-maint/flag.json (origin "remote")
postfiat-monitor / pft-integrity:                           pft-watchdog / pft-integrity:
  `pft-maint active` -> suppress + count                      `pft-maint active` -> suppress + count
pft-maint end            -> [MAINT] end (exactly one)       signed end -> copy removed (no message)
  or TTL reached -> pft-maint tick (60s timer) -> [MAINT] end   TTL reached -> tick closes the copy silently
```

| File | What |
|---|---|
| `pft-maint.sh` | `start`, `end`, `status [--json]`, `active`, `tick`, `restart-node`, `lock add/rm/list`, `suppressed`, `apply-remote` |
| `pft-maint-tick.{service,timer}` | `pft-maint tick` every 60s: closes an expired window and sends its single end message |
| `install.sh` | `install [--label L] [--ntfy-env F]`, `uninstall [--purge]`; also installs the maintenance-aware alerters this host already runs |
| `test-maint.sh` | fake-clock unit tests (no root needed except the pft-integrity case) |
| `../watchdog/pft-watchdog.sh`, `../monitor/postfiat-monitor.sh`, `../integrity/pft-integrity.sh` | patched to honour the flag |

## Install

On both hosts (the watchdog channel from the [watchdog add-on](../watchdog/README.md) must already work):

```bash
sudo ./install.sh install --label validator          # on the sentry: --label sentry
sudo pft-integrity accept --reason "pft-maint installed"
sudo pft-maint status
```

ntfy target: `/etc/pft-maint/ntfy.env` if present (`--ntfy-env`), else `/etc/postfiat-monitor.env`, else
`/etc/pft-integrity.env`. The file must be root-owned and not group/other-writable; it is parsed as data, never
sourced, and the topic and token reach curl through a config on a file descriptor, not argv.

## Use

```bash
sudo pft-maint start --ttl 30m --reason "postfiatd config change"
sudo pft-maint restart-node            # guarded restart, one-line verdict
sudo pft-maint end                     # or let the TTL expire
```

`restart-node` refuses (exit 4) unless all pre-checks pass, and prints `restart-node PASS|FAIL|TIMEOUT|REFUSED: ...`:

| Phase | Check |
|---|---|
| pre | a valid window is active on this host and has at least `RESTART_TIMEOUT + POST_TIMEOUT` (600 + 300 s) left |
| pre | no unexpired data-collection lock (`pft-maint lock add NAME --until ISO8601\|EPOCH --reason ...`); a malformed lock counts as held |
| pre | `server_state` is `full` (or `proposing`); peer count, validated ledger and whether the sentry is a peer are recorded |
| restart | `docker restart -t 60 postfiatd`, then poll every 5s until `full`; not full after `RESTART_TIMEOUT` -> `TIMEOUT`, exit 2 |
| post | within `POST_TIMEOUT`: peers within ±2 of the recorded count, the sentry peered again (if it was before), validated ledger above the recorded one. Any miss -> `FAIL`, exit 1 |

The sentry address is `SENTRY_ADDR` in `/etc/pft-maint/maint.conf`, else the host in the watchdog's
`RELAY_TARGET`. Long-running collectors (24 h analyses that read the local node) should declare a lock for their
window, so nobody restarts the node under them by accident.

## Flag format and TTL semantics

```json
{"v":1,"id":"m1792754147-3323170","reason":"postfiatd config change","start":1792754147,"expiry":1792755947,"host":"validator","origin":"local"}
```

A flag is **valid** only if all of these hold: regular file (not a symlink), owned by root, not group/other-writable,
at most 4 KiB, JSON with `v==1`, string `id`/`reason`/`host`, numeric `start` < `expiry`, `expiry - start <=
MAX_TTL_SEC` (4 h), and `start` not more than 60 s in the future. A window is **active** while `now < expiry`.
`pft-maint active` exits 0 (active), 1 (none or expired) or 2 (malformed); the alerters suppress only on 0.

- One window at a time: `start` refuses while one is active. To extend, `end` and `start` again.
- `start` sends exactly one `[MAINT] start` message. `end` sends exactly one `[MAINT] end`. If nobody ends the window,
  the first `tick` after `expiry` sends exactly one `[MAINT] end ... expired`. The flag is then archived to
  `history.jsonl` with how it ended and the suppressed-alert counts, so no second message is possible.
- The sentry copy has `origin: "remote"`. It cannot be ended on the sentry (`end` refuses), it is removed by the
  signed end message, and an expired copy is closed by the sentry's `tick` without a message, because the origin
  host already reports.
- The sentry copy travels as a signed message over the existing forced-command SSH account (`pftwd`, which can
  only write to the spool). The watchdog's root `check` verifies the HMAC, rejects replays (`maint_replay`: ts not
  newer than the last maint message) and messages from the future, and only then calls `pft-maint apply-remote`,
  which validates the flag again before it writes it. A forged or replayed message is `BADSIG` and is never applied.

## What each alerter does inside a window

| Alerter | Inside a valid window | First run after the window |
|---|---|---|
| `pft-watchdog` (sentry) | STALE/LAGGING: no ntfy, counted once per state change, `maint:true` in `--json`. **BADSIG is never suppressed**: a forged or replayed heartbeat is tampering, not maintenance. RECOVERED is not sent for a suppressed incident | a non-OK state is alerted even though it is not a new state (`... (maintenance window closed, still not OK)`) |
| `postfiat-monitor` (validator) | UNHEALTHY is logged as `MAINT: alert suppressed` and counted; the stored state is left unchanged | still unhealthy -> the normal UNHEALTHY alert, because the stored state never became `fail` |
| `pft-integrity --notify` | a changed finding set is not sent and **not recorded**, and is counted | the next `--notify` run (hourly timer) sends it, since the recorded state is still the old one |

## Why fail-open

A maintenance flag is a way to switch off paging, so anything wrong with it has to turn paging back on, not
leave it off. If the flag is expired, malformed, too long-lived, writable by non-root, a symlink, or `pft-maint`
is not installed or fails, `pft-maint active` returns non-zero and every alerter behaves exactly as before this
add-on. The worst case for a bad flag is an alert you didn't need, not one you missed. The 4 h `MAX_TTL_SEC` cap
means a forgotten window can't silence the host for long.

## Tests

`./test-maint.sh` uses a file as the clock (`PFT_MAINT_NOW_FILE`; sleeps advance it), outbox files instead of
ntfy, and stubs for the node RPC and `docker restart`. It covers: start/suppress/end with exactly one message
each, BADSIG during a window, TTL expiry with the post-expiry alerts from the watchdog and monitor, six kinds of
malformed flag, the lock / no-window / not-full / too-short-window refusals, restart timeout, PASS and FAIL
verdicts, the signed sentry copy (apply, replay, forgery, signed end, silent expiry), and pft-integrity's
suppress-then-send (root, throwaway `STATE_DIR`). Logs: [`../logs/maint/`](../logs/maint/).

## Limits

- The sentry copy arrives on the watchdog's next `check` (60s timer). The watchdog applies it before it decides
  the state in that same run, so a restart started right after `start` is covered; there is no gap in the order
  of events, only up to 60s of delay.
- If the push to the sentry fails, `start` says `sentry copy: failed` (also in the start message) and the
  watchdog will page as usual. Nothing retries it.
- pft-integrity runs hourly, so "first run after the window" can be up to an hour later for that alerter.
- The clocks of both hosts must agree within the watchdog's `SKEW_TOL_SEC` (30s) for the signed message to be
  accepted; the flag times themselves are compared against each host's own clock.
- Root on either host can write a valid flag. That's by design: root can stop the alerters anyway.
