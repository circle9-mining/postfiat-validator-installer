# postfiatd log analyzer (`pft-logscan.py`)

`pft-logscan.py` reads the node's `debug.log` and its rotations and tells you what happened: how many
lines per severity and per partition, which partitions are noisiest, restarts (with downtime, and whether
each start was preceded by a clean `Server stopping`), server state changes, lost sync, ledger switches,
amendment blocking, peer connects/disconnects/charges/resource limits, slow jobs, NodeStore/disk errors
and clock warnings, plus an hourly WRN / ERR timeline.

It is read-only: it opens the log files for reading and nothing else (no RPC, no Docker, no writes).
Python 3 standard library only.

```bash
sudo ./logscan/pft-logscan.py                         # all of /opt/postfiatd/logs (debug.log + rotations)
sudo ./logscan/pft-logscan.py --since 24h             # last 24 hours
sudo ./logscan/pft-logscan.py --since 2026-10-21T04:00:00Z --until 2026-10-22T04:00:00Z --json
sudo ./logscan/pft-logscan.py --file /path/to/debug.log-20261021-202057 --stats
```

`sudo` is needed only because the log directory is root-owned on a default install.

| Option | Meaning |
|--------|---------|
| `--log-dir DIR` | Directory with `debug.log`, `debug.log-*` / `debug.log.N`, plain or `.gz` (default `/opt/postfiatd/logs`). Files are read oldest first, ordered by their first timestamp. |
| `--file PATH` | Analyze only these files (repeatable). |
| `--since`, `--until` | Window: ISO-8601 UTC (`2026-10-21T04:00:00Z`, offsets are converted) or relative (`90m`, `24h`, `7d`). |
| `--json` | Print the full report as JSON. |
| `--salt S` | Fixed salt for the anonymizing labels (default: random per run, so labels can't be linked across runs). |
| `--slow-ms N` | LoadMonitor NFO jobs count as slow when run or wait >= N ms (default 1000). LoadMonitor WRN lines always count. |
| `--startup-grace N` | Seconds after `Process starting` during which sync loss, ledger switches, non-full states and `Missing node` are expected (default 600). |
| `--top N` | Number of partitions listed (default 10). |
| `--stats` | Print files, bytes, lines, runtime and peak RSS to stderr. |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | OK: nothing above INFO |
| 1 | WARN: at least one WARN event (see table), or ERR lines that were all `Missing node` inside the startup grace |
| 2 | CRIT: any other ERR/FTL line, amendment blocked, NodeStore error outside the grace, a file could not be read, or no log files found |
| 64 | Usage error (bad option or time) |

## Detectors

Lines look like `2026-Oct-21 20:20:59.819232198 UTC Application:NFO Process starting: ...`. The regex is
applied to the message after `Partition:SEV `; lines without that header (multi-line JSON, stack text)
are counted as continuation lines and not matched. Each detector only looks at the listed partitions and
severities. "Startup grace" = within `--startup-grace` seconds after the last `Process starting`.

| Detector | Partitions, severity | Regex | Level | Operator response |
|----------|---------------------|-------|-------|-------------------|
| `startup` | Application, >= NFO | `^Process starting: (?P<version>[^\s,]+)` | INFO; WARN (UNCLEAN) when no `Server stopping` precedes it in the window | Expected after upgrades/reboots; unexpected ones mean a crash loop or OOM kill. |
| `shutdown` | Application, >= NFO | `^Server stopping(?:: (?P<reason>.*))?` | INFO | Expected for planned restarts; otherwise check who/what sent the signal. |
| `state_change` | NetworkOPs, >= TRC | `STATE->(?P<state>\w+)` | INFO for `full` and within the startup grace; WARN otherwise | full is healthy; disconnected/connected/syncing after startup means lost sync. |
| `lost_sync` | LedgerConsensus, LedgerMaster, NetworkOPs, >= WRN | `We are not running on the consensus ledger\|Need consensus ledger\|Node count \(\d+\) has fallen below required minimum\|fell behind\|out of sync` | INFO within the startup grace; WARN otherwise | INFO within the startup grace; otherwise check peers (peers/), disk latency and clock. |
| `ledger_jump` | LedgerConsensus, LedgerMaster, >= NFO | `^View of consensus changed during \w+ mode=switchedLedger\|^[Ll]edger jump\|^[Jj]umping to ledger` | INFO within the startup grace; WARN otherwise | Node had to switch to the network's ledger; INFO within the startup grace, WARN otherwise. |
| `amendment_blocked` | any, >= NFO | `(?i)amendment.?blocked\|unsupported amendment\|has been enabled.*not supported` | CRIT | Upgrade postfiatd now (upgrade/); an amendment-blocked node cannot follow the network. |
| `peer_connect` | Peer, >= NFO | `^\[\d+\] Public Key: ` | INFO | Informational: completed peer handshakes. |
| `peer_disconnect` | Peer, >= NFO | `^\[\d+\] (?:Closed\|onReadMessage .*\|onWriteMessage .*\|Unable to upgrade to peer protocol.*)$` | INFO | Informational unless peer count drops; then check firewall and peer port 2559. |
| `peer_charge` | Overlay, Peer, PeerFinder, Resource, >= NFO | `(?i)\bcharg(?:e\|ing)\b\|\bfee=` | WARN | A peer (or this node) is being charged for bad/expensive traffic; repeated charges precede drops. |
| `resource_limit` | Overlay, Peer, PeerFinder, Resource, Server, >= NFO | `(?i)resource limit\|over ?limit\|balance.*exceed\|dropping (?:peer\|connection)\|too many (?:connections\|peers)\|slots? full` | WARN | Check peers_max / rate limits (UFW and DOCKER-USER) and whether a peer is misbehaving. |
| `slow_job` | LoadMonitor, >= NFO | `^Job: (?P<job>.+?) run: (?P<run>\d+)ms wait: (?P<wait>\d+)ms` | WARN for every LoadMonitor WRN; NFO lines only when run or wait >= `--slow-ms` | CPU/disk saturation; check load, iowait and disk latency if frequent. |
| `nodestore_error` | Application, Database, LedgerMaster, NodeFamily, NodeObject, NodeStore, SHAMapStore, SQLiteDatabaseImp, >= NFO | `(?i)missing node\|write (?:error\|fail)\|no space left\|disk full\|database (?:is )?(?:locked\|corrupt)\|i/o error\|cannot open\|failed to (?:write\|store\|open)` | CRIT for ERR/FTL; `Missing node` within the startup grace is WARN; NFO/WRN hits are WARN | Check free disk, filesystem errors and node_db; Missing node shortly after startup is normal. |
| `clock_warning` | any, >= WRN | `(?i)\bclock\b\|close.?time (?:offset\|skew\|drift)\|time (?:skew\|jump\|offset)\|close time.*(?:behind\|ahead)` | WARN | Check chrony/timesyncd (exporter clock metric); consensus needs an accurate clock. |

The patterns for `amendment_blocked`, `peer_charge`, `resource_limit` and `clock_warning` are based on
rippled/postfiatd message wording; none of them occurred on the test node, so they are covered by unit-test
fixtures only. The others were seen in the live run (see `logs/logscan/`).

What the levels mean in practice on a healthy node: every restart produces `Node count (0) has fallen
below required minimum`, `connected → disconnected → connected → syncing → tracking → full` and often a
few `NodeFamily:ERR Missing node` lines while the node fetches state; inside the startup grace these are
INFO/WARN rather than alarms. The same lines an hour after a start mean the node lost the network.

## Restart cross-check (`restart-crosscheck.py`)

Confirms that the restarts found in `debug.log` really happened, using Docker and systemd records
(read-only: `journalctl -u docker`, `journalctl --list-boots`, `docker events`, `docker inspect`):

```bash
sudo ./logscan/restart-crosscheck.py --since 2026-10-21T04:00:00Z --until 2026-10-22T10:00:00Z [--tolerance 10]
```

Each `Server stopping` / `Process starting` timestamp is matched to the nearest Docker record within the
tolerance. dockerd's journal has a record for every container stop (`ignoring event ... /tasks/delete`),
but container *starts* are only in `docker events` (kept in memory since dockerd started) and
`docker inspect` (latest start). Starts before the current dockerd start are reported as UNCHECKABLE rather
than counted as matches. Exit 0 when every checkable timestamp matched. Output has UTC times and
sources only (no hostnames or container IDs).

## Sanitized output

Every string in the text and JSON report goes through the sanitizer before printing:

| Replaced | Pattern | Label |
|----------|---------|-------|
| IPv4 (with optional `:port`) | `\d{1,3}(\.\d{1,3}){3}`, checked with `ipaddress` | `ip-1a2b3c4d`, `port-5e6f` |
| IPv6 (bare or `[addr]:port`) | hex/colon runs with 2+ colons, checked with `ipaddress` | `ip-…`, `port-…` |
| `port 2559`, `port=2559` | `port[ =:]+\d{2,5}` | `port-…` |
| Node public keys | base58 `n` + 49–52 chars | `key-1a2b3c4d` |

Labels are the first hex digits of `sha256(salt + "|" + value)`, so the same peer gets the same label within
a run and reports are shareable. Ledger hashes, versions and timestamps are left as they are.

## Tests

```bash
python3 -m unittest discover -s logscan/tests -v
```

Per detector a positive and a negative line (and every detector is covered), startup-grace downgrades,
slow-job threshold, restart/downtime/unclean detection on `tests/fixtures/restart-cycle.log`, `.gz` +
plain rotation ordering, `--since/--until` windows, the hourly timeline, CLI exit codes, and sanitization
of text and JSON output with a positive control (the raw input must contain the IPv4/IPv6/port/key that
the output must not). Fixtures use documentation addresses (192.0.2.0/24, 198.51.100.0/24, 2001:db8::/32)
and a synthetic node key.

## Performance

See `logs/logscan/` for the measured runtime and peak memory on the live log set (~100 MB). The file is
streamed line by line, so memory does not grow with log size; only counters and a few examples per
detector are kept.
