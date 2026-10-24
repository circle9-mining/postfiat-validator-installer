# pft-resync: cold-resync recovery time (RTO) drill

If a node's ledger DB is lost (disk failure, corrupted NuDB, an `rm` in the wrong place) and there is no backup,
the only way back is a cold resync from the network. `pft-resync` measures how long that takes on your own hardware,
phase by phase, so the number in your runbook is measured and not a guess. It can also undo the drill: if the node
is not back within the timeout, the old DB is put back.

## Safety: sentry first

**Run the drill on a sentry, not on your validator.** A cold resync also deletes `wallet.db`, so the node gets a new
node identity (`pubkey_node`), and the node is not serving the network until it is back to `full`. A sentry that
the validator lists in `[ips_fixed]` (see [`sentry/`](../sentry/README.md)) is peered again by address, so its new
identity does not matter. A validator that loses its identity changes what its peers see. Measure on the sentry
and use that number for the validator.

The drill refuses (exit 4, nothing touched) unless **all** of these are true:

| Guard | Why |
|---|---|
| `--yes` | it deletes the node's ledger DB |
| a valid [`pft-maint`](../maint/README.md) window is active with at least `TIMEOUT + 300` s left | alerters on the host are suppressed for the whole drill, rollback included |
| no `pft-maint` data-collection lock is held | do not reset a node that a 24 h analysis is reading |
| `server_state` is `full`/`proposing` before the drill | there has to be a baseline to measure against |
| the host path mounted at `/var/lib/postfiatd/db` is an absolute, non-symlink directory at least 3 levels deep | the rename and the later `rm -rf` only ever touch that directory and its two siblings |
| `pft-maint status` works | if pft-maint is missing, the drill refuses (fails closed) |

If a drill also triggers alerts that pft-maint does not cover (for example a [`[MAINT]`](../maint/README.md) start/end message
going to your phone), point them at a throwaway topic. [`drill-sentry.sh`](drill-sentry.sh) does this for you (below).

## Files

| File | What |
|---|---|
| `pft-resync.sh` | `plan` (read-only), `drill --yes`, `report FILE [--json]` |
| `drill-sentry.sh` | one guarded live drill on a sentry: notifiers redirected to a throwaway topic, then a live no-window refusal, then window, drill, end, restore with a sha256 check, and the throwaway topic read back |
| `tests/run-tests.sh` | offline tests: stubbed docker/RPC/pft-maint, fake clock, and real renames on a temp DB dir; also runs shellcheck |
| `logs/` | unit-test output, the two live sentry drills, post-drill checks, run-1 regression proof (IPs redacted) |

## Use

```bash
sudo bash pft-resync.sh plan --container postfiatd-sentry          # read-only, says RUN or REFUSE
sudo pft-maint start --ttl 45m --reason "cold-resync drill" --no-sentry
sudo bash pft-resync.sh drill --yes --container postfiatd-sentry   # JSON lines + report
sudo pft-maint end
sudo bash pft-resync.sh report /var/lib/pft-resync/runs/<id>.jsonl
# or all of it, with notifiers redirected:  cd resync && sudo bash drill-sentry.sh
```

What `drill` does: `docker stop -t 60`, then it renames the DB dir to `<db>.resync-aside-<id>` (same parent, so it is a
rename and not a copy), creates an empty DB dir with the same owner and mode, runs `docker start`, and polls `server_info`
every `POLL_SEC` (5) s. Each event and each poll is one JSON line in `/var/lib/pft-resync/runs/<id>.jsonl` and on stdout.

- **PASS** (exit 0): `full` **and** a validated ledger above the pre-drill one, both within `--timeout` (1800 s).
  The old DB is then deleted, and the freed bytes are recorded (`--keep-old` keeps it).
- **TIMEOUT** (exit 1): stop, delete the half-synced fresh DB, rename the old DB back, start, then wait for `full`.
- **SIGINT/SIGTERM** after the DB was moved: same rollback, exit 6. Rollback failed: exit 5 (look at it by hand;
  the paths are in the JSONL).

Phases are seconds after `docker start`, timed when the `server_info` **answer** arrives (`rpc_s` per poll is how long
the answer took). States are ranked disconnected < connected < syncing < tracking < full, and "time to X" is the first
poll at rank X or higher. A node that jumps straight from connected to full therefore gets the same time for syncing,
tracking and full. The report's `states observed` line shows which states were actually seen. With 5 s polling, each
phase is accurate to about 5 s.

## Measured on the sentry (two live drills, 2026-10-24)

Testnet, `agtipft/postfiatd:testnet-light-latest` (ships `online_delete=512`, so the DB is small), 4 vCPU, 8 GB RAM.
Both drills ran inside a pft-maint window, with the sentry's watchdog, integrity and pft-maint notifiers pointed at a
throwaway topic.

| | run 1 ([log](logs/sentry-drill-1.log)) | run 2 ([log](logs/sentry-drill-2.log)) |
|---|---|---|
| DB moved aside / freed | 19,263,492 B | 12,893,272 B |
| container down (stop -> start) | 1 s | 1 s |
| time to connected | 5 s | 5 s |
| time to syncing (first seen) | 48 s | 50 s (not observed: went connected -> full) |
| time to first validated ledger | 48 s | 50 s |
| time to full | 54 s | 50 s |
| time to caught up (validated > pre-drill seq) | 48 s | 50 s |
| peers at full (pre-drill) | 3 (11) | 3 (11) |
| verdict | PASS | PASS |

**RTO for this sentry: about 1 minute from `docker start` to `full` with a current validated ledger.** Most of that
minute is spent `connected` with 3 peers and no ledger, waiting to acquire one. Peers then climb back to 11 over the next
minutes, and the validator re-peers the sentry through `[ips_fixed]` with its new node key
([post-drill checks](logs/post-drill-checks.log): `sentry_peered: true`, integrity PASS on both hosts, no leftovers).
A node with a large `online_delete`, or full history, keeps backfilling long after `full`. This tool measures time to
`full` and caught up, not time to full history.

**Found in run 1 and fixed before run 2:** run 1 (pft-resync.sh sha256 `7fe64261...`) timed each poll *before* the
`server_info` call. While the node was starting, one call took about 4 s to answer (poll `el:5` was answered at
`t`+9 s), so run 1's phase times can read up to about 4 s early. The fix (sha256 `e481d3b6...`, the committed version)
times each poll at the answer and records `rpc_s`. Test case `2b` is the regression test: it fails with the old code
(9/18 s instead of 13/22 s); see [`logs/regression-2b-run1-code.log`](logs/regression-2b-run1-code.log), which rebuilds
the run-1 script byte-identically and runs the suite against it. Run 1's log is published unchanged.

## Tests

```bash
bash resync/tests/run-tests.sh     # no root, no docker, no node; 36 checks incl. shellcheck
```

Cases: a passing sequence with exact phase times; skipped states; a slow RPC (2b); timeout followed by a rollback that restores
the old DB; a rollback whose restart fails (exit 5); refusals with nothing touched (no window, no `--yes`, window too short,
lock held, node not full, pft-maint missing); SIGTERM mid-drill (rollback, exit 6); `plan` making only `docker
inspect` calls; and a symlinked DB dir. Output: [`logs/unit-tests.log`](logs/unit-tests.log).
