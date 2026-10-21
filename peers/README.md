# Peer diagnostics (`pft-peers.py`)

`pft-peers.py` checks the peer connections of your node. It reports how many peers you have and how
many you are allowed, which peers connected to you (inbound) and which ones you connected to (outbound),
which versions your peers run, peer latency and connection age, whether your peers are on the same ledger
as you, and, for a validator behind a sentry, whether the sentry is connected.

It is read-only. It uses only two admin RPC methods, via `docker exec <container> curl` to the loopback
admin port (`http://127.0.0.1:5005` inside the container):

| Method | Used for |
|--------|----------|
| `peers` | per-peer `inbound`, `version`, `latency`, `uptime`, `complete_ledgers`, `network_id`; `address` and `public_key` only to match fixed peers and to make labels |
| `server_info` | local `build_version`, `server_state`, `validated_ledger.seq`, `network_id`, `peers` |

The method names are on an allowlist in the script, so it cannot send any other method.
With `--read-config` it also reads the node config with `cat` (default `/etc/postfiatd/postfiatd.cfg` in
the container) to get `[peers_max]`, `[ips_fixed]` and `[peer_private]`. That is a file read, not an RPC call.
Python 3 standard library only, no dependencies.

```bash
sudo ./peers/pft-peers.py --read-config                        # validator (container postfiatd)
sudo ./peers/pft-peers.py --container postfiatd-sentry --read-config   # sentry host (sentry/ add-on)
sudo ./peers/pft-peers.py --fixed-peer <sentry-ip> --json      # require the sentry; JSON for scripts
```

## Checks

| Check | WARN when | FAIL when |
|-------|-----------|-----------|
| `local.state` | `server_state` is not `full`, `proposing` or `validating` | – |
| `peers.count` | fewer than `--min-peers` (default 5) | 0 peers |
| `peers.direction` | never (inbound/outbound split, for information) | – |
| `peers.versions` | more than `--max-outdated-pct` (default 20 %) of peers run an older build than yours | – |
| `peers.latency` | p90 latency above `--latency-p90-ms` (default 1000 ms) | – |
| `peers.uptime` | median peer connection age below `--min-median-uptime` (default 300 s): peers keep dropping | – |
| `peers.ledgers` | more than `--max-lagging-pct` (default 50 %) of peers are more than `--max-ledger-lag` (default 10) ledgers behind your validated ledger or report no ledgers; or any peer is on another `network_id` | – |
| `peers.fixed` | – | a fixed peer (`--fixed-peer`, or `[ips_fixed]` with `--read-config`) is not connected |
| `peers.private` | `[peer_private]=1` and peers outside the fixed set are connected | – |

The peer limit is `[peers_max]` from the config with `--read-config`, otherwise `--peers-max` (default 21,
the postfiatd default). If `[peer_private]=1` and fixed peers are set, the minimum peer count is the number of
fixed peers, because a private validator behind a sentry is expected to have only 1 peer.
Fixed peers are matched by host (IP or name) only; the port is ignored.
Percentiles are nearest-rank. A negative `LAG` means the peer has a newer ledger than your last validated ledger.
`RPC` errors (node down, container missing) are reported as a `FAIL`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | OK (all checks OK, INFO or SKIP) |
| 1 | WARN (at least one WARN, no FAIL) |
| 2 | FAIL (at least one FAIL, or the RPC call failed) |
| 64 | usage error (bad argument) |

Use it from cron or from the `monitor/` add-on, for example `pft-peers.py --fixed-peer <sentry-ip> >/dev/null || notify`.

## Privacy model

The output is safe to publish. It never prints peer IP addresses, ports, node public keys, ledger hashes
or `server_domain`. Each peer is shown as a label `p-` + the first 8 hex characters of
`sha256(salt + public_key)`. The salt is random for each run and is never printed, so labels cannot be
linked back to a key or matched between runs. To get the same labels in every run (to follow one peer over
time), set your own secret salt with `--salt` or `PFT_PEERS_SALT`, and keep it private.
Fixed peers are shown as `#1`, `#2`, … in the order you give them, not by address.
Your own command line can still contain the sentry IP: redact it before you publish a log.

## Limits

- `peers` shows only the peers connected right now. It does not show peers that failed to connect,
  or why. Read the node log for that.
- `version` is what the peer says it runs. A peer can send any value.
- `latency` and `uptime` are measured by the node and only cover the current connection.
- `complete_ledgers` from a peer is what that peer says it has. A light node keeps only a few hundred
  ledgers, so a short range is normal.
- The tool does not check the config itself (for example that `[ips_fixed]` is correct). It only checks
  that the fixed peers are connected.
- The live log in `logs/peers/` was taken while the validator was **not** behind the sentry, so the
  `peers.fixed` OK path with `[peer_private]=1` is proven only with fixtures (`tests/fixtures/sentry-ok`).

## Tests

```bash
python3 -m pytest -v peers/tests   # fixtures: healthy, warn-outdated, warn-low-count, sentry-ok, fail-sentry-missing, fail-no-peers
ruff check peers
```
The fixtures are made-up data (addresses `*.fixture.invalid`, keys `fixture-key-N`), not real peers.
