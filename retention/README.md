# Ledger retention and disk-capacity add-on (`pft-retention.sh`)

A Post Fiat node keeps every ledger it has validated unless `[node_db] online_delete` is set. With it set, the node
deletes old history by itself. `pft-retention.sh` measures how fast the ledger store grows on your host, tells you how
many days of free disk you have left and which `online_delete` value fits your disk, and changes that value with a
backup, a validation step, one restart and an automatic rollback.

```bash
sudo install -m 755 retention/pft-retention.sh /usr/local/bin/pft-retention
sudo install -m 644 retention/pft-retention-sample.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pft-retention-sample.timer   # one sample every 10 min

sudo pft-retention measure                         # after >= 6h of samples; add --json for machine output
sudo pft-retention watch-rotation --raise-log      # wait for the next rotation and show what it freed
sudo pft-retention apply --online-delete 2048      # WRITES: backup, edit [node_db], restart once, wait for full
sudo pft-retention rollback                        # WRITES: restore the latest backup, restart once, wait for full
```

Run `sudo pft-retention --help` for every option.

## Modes

| Mode | Writes | What it does |
|------|--------|--------------|
| `sample` | `/var/lib/pft-retention/samples.csv` only | One CSV row: `server_state`, validated seq, `complete_ledgers` bounds, NuDB and SQLite bytes, free/total bytes of the filesystem, NuDB backend dir names. Run by the timer. |
| `measure` | nothing (reads samples, takes one more) | Least-squares growth of the store over `--window` hours (default 24), days until the filesystem is full, bytes per held ledger, ledger interval, and a recommended `online_delete`. |
| `watch-rotation` | nothing (`--raise-log` changes a runtime log level) | Waits up to `--max-wait` seconds for the `complete_ledgers` lower bound to jump, then prints the SHAMapStore log lines and the store size before/after. |
| `apply` | `postfiatd.cfg` in the container, a 0600 backup, one restart | See [Apply and rollback](#apply-and-rollback). |
| `rollback` | `postfiatd.cfg`, one restart | Restores the latest backup (or `--from FILE`) and waits for `full`. |
| `can-delete` | node state (admin RPC) | Pass-through to `can_delete`, only useful with `advisory_delete=1`. |

Exit codes for `measure`: `0` OK, `1` WARN (disk full in < 30 days, fewer than 6 hours of samples, or node not
`full`), `2` FAIL (disk full in < 7 days, or an error).

## How online deletion works

- The node writes ledgers into two NuDB backends: a *writable* one and an *archive* one (the two
  `postfiatdb.<hex>` directories under the database path).
- Once the validated ledger is `online_delete` ledgers past the last rotation, the node *rotates*: it copies the
  current state map into a fresh backend, drops the old archive, makes the old writable backend the archive, and
  deletes rows below the new lower bound from the SQLite ledger and transaction databases.
- So the node holds between `online_delete` and `2 x online_delete` ledgers, and `complete_ledgers` moves up in
  steps. The store size is a sawtooth, which is why `measure` refuses to project disk-full from less than 6 hours of
  samples.
- `online_delete` must be at least 256. `[ledger_history]` must not be larger than `online_delete`, or the node
  refuses to start; `apply` checks this before it writes anything.
- With `advisory_delete=1` the node rotates only after an operator (or a script) allows it with the `can_delete`
  admin RPC. With `0` (the default) it rotates by itself.
- Rotations are logged only at SHAMapStore `debug` level. `watch-rotation --raise-log` runs
  `log_level partition=SHAMapStore severity=debug` first. That change lasts until the next restart.

The `testnet-light` image ships with `online_delete=512`, so a stock node already prunes. On that image the add-on
is mainly useful for `measure` (how much disk the chosen value costs) and for raising the value when you need more
local history (for example to answer `ledger`/`tx` queries further back).

## Sizing

`measure` derives two limits and recommends the smaller one (never below 256):

- **target** = `--target-days` (default 7) of ledgers at the measured ledger interval;
- **budget** = the number of ledgers that fit in `--budget-pct` (default 50) of free + current DB space, counting
  `2 x online_delete` ledgers at the measured bytes per ledger (the archive backend doubles it).

It also prints the steady-state size of the current setting (`2 x online_delete x bytes/ledger + SQLite`).

## Apply and rollback

`apply --online-delete N [--advisory-delete 0|1]`:

1. Preflight: runs as root, `jq`/`awk`/`sha256sum` present, container exists and has `curl`.
2. No-op (exit 0, no restart) if the values are already set.
3. Copies the live config to `/var/backups/pft-retention/postfiatd.cfg.<UTC>` (directory 0700, file 0600).
4. Edits only `online_delete`/`advisory_delete` inside `[node_db]`, then validates the result: exactly one
   `[node_db]`, the new values present, `path` still set, `ledger_history <= online_delete`, and no other line
   changed (diff).
5. Prints the diff, installs the file atomically with its original mode and checks its sha256.
6. Restarts the container once and waits for `server_state=full` (`--timeout`, default 900 s). If the node does not
   reach `full` in time, it restores the backup, restarts again and exits non-zero.

`rollback` restores the latest backup (recorded in `/var/backups/pft-retention/LATEST`) the same way.

Both modes restart `postfiatd`. Don't run them while another tool is collecting data from the local node.

## Interaction with other add-ons

- [`backup/`](../backup/) saves `postfiatd.cfg`, including `online_delete`. Restoring an older backup also restores
  its `online_delete` value. The ledger database itself is not backed up; after a restore the node re-syncs.
- [`integrity/`](../integrity/) hashes the files in the config volume. After `apply` or `rollback`, run
  `sudo pft-integrity accept --reason "online_delete change"` so the intended change doesn't alert.
- [`alerts/`](../alerts/) fires `RPCDown` if a restart takes longer than its `for:` window.

## Tests

`test-sandbox.sh` runs `apply`/`rollback` against a throwaway container from the same image (entrypoint `sleep`,
stub `curl`), never against the live node: apply 1024, 0600 backup, no-op re-apply, rollback and no-op rollback,
adding `advisory_delete=1`, rejected values (`online_delete` 100, `ledger_history` > `online_delete`), and
auto-rollback when the node never reaches `full` (11/11 PASS). Log:
[`logs/retention/1-sandbox-apply-rollback.log`](../logs/retention/1-sandbox-apply-rollback.log).

## Known limits

- `watch-rotation` reads `debug.log` from the line count at start. If logrotate rotates the file during the wait, the
  log lines are missed (the `complete_ledgers` check still works).
- Growth is measured on the filesystem that holds the database. Other writers on the same filesystem show up as
  growth too.
