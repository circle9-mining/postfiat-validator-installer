# Amendment and fee-voting status (`pft-amendments.py`)

`pft-amendments.py` shows which amendments are enabled on the network, which ones your build supports,
how your node votes, any amendment that has a majority and when it would activate, and the current fee
settings next to your node's fee vote. It warns you before your node becomes **amendment-blocked**.

It is read-only. It uses only these admin RPC methods, via `docker exec <container> curl` to the
loopback admin port:

| Method | Used for |
|--------|----------|
| `feature` (no parameters, so nothing is changed) | name, `enabled`, `supported`, `vetoed` for every amendment the build knows |
| `server_info` | `amendment_blocked`, `server_state`, `build_version` |
| `server_state` | validated ledger `base_fee` / `reserve_base` / `reserve_inc` in drops |
| `fee` | open-ledger fee levels |
| `ledger_entry` `index=7DB0…6EF4` (Amendments) | `Amendments` (enabled on the network) and `Majorities` (pending) |
| `ledger_entry` `index=4BC5…A651` (FeeSettings) | network fee and reserve settings |

It also reads the node config with `cat` (default `/etc/postfiatd/postfiatd.cfg` in the container)
to show your `[voting]` stanza. That is a file read, not an RPC call. Use `--no-config` to skip it.
Python 3 standard library only, no dependencies.

```bash
sudo ./amendments/pft-amendments.py                          # table
sudo ./amendments/pft-amendments.py --json > snap.json       # machine-readable snapshot
sudo ./amendments/pft-amendments.py --compare snap.json      # what changed since the snapshot
sudo ./amendments/pft-amendments.py --container postfiatd-sentry   # on a sentry host (see ../sentry/)
./amendments/pft-amendments.py --fixture amendments/tests/fixtures/enabled-unsupported   # offline demo, exit 2
```

Options: `--container` (default `postfiatd`, env `PFT_CONTAINER`), `--rpc-url` (as seen from inside the
container, default `http://localhost:5005/`, env `PFT_RPC_URL`), `--config`, `--no-config`, `--fixture DIR`,
`--majority-hours` (default 336), `--json`, `--compare SNAPSHOT`.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | OK. No enabled or pending amendment is unsupported by this build. With `--compare`, nothing changed. |
| `1` | RPC, usage or snapshot-read error. Nothing was judged. |
| `2` | Amendment-blocked risk. Any of these: `server_info.amendment_blocked` is true; an amendment is enabled on the network but not supported by this build (this includes one that is enabled in the ledger but unknown to the build); an unsupported amendment holds a majority and will activate. |
| `3` | `--compare` found differences, and there is no risk. Code `2` takes priority over `3`. |

You can run it from cron or a monitoring agent next to `postfiat-health` and alert on exit code `2`.
A daily `--json` snapshot plus `--compare` against yesterday's snapshot shows you vote changes, new
majorities and fee changes.

## Reading the output

`STATUS` column:

- `ENABLED`: active on the network, and your build supports it.
- `ENABLED!UNSUPPORTED`: active on the network, but your build does not support it. Your node is (or soon
  will be) **amendment-blocked**. It stops tracking the validated ledger and cannot validate. Fix: upgrade
  `postfiatd` to a release that supports the amendment (see [`../upgrade/`](../upgrade/)), then re-run until you
  get exit code `0`.
- `MAJORITY`: has a majority of trusted validators but is not active yet. The ETA is `majority_since + --majority-hours`.
  If the row is also `SUPPORTED NO`, upgrade **before** the ETA. A `PENDING_UNSUPPORTED` risk line is printed for it.
- `voting-yes` / `vetoed`: not enabled. This is how your server votes. `vetoed` (`feature` reports `vetoed: true`)
  covers amendments you explicitly vetoed as well as default-no amendments you have not voted for.
- `obsolete`: retired amendments that can never be enabled. You can ignore these.

Risk lines look like `ENABLED_UNSUPPORTED <name> <64-hex id>` and `PENDING_UNSUPPORTED <name> <id> activates ~<UTC>`.

The fee table shows the network value from the FeeSettings ledger object (both the legacy `BaseFee`
hex format and the newer `*Drops` fields are parsed), the validated-ledger value, and your node's vote:

- `default (not set)`: your config has no `[voting]` entry, so the node votes its compiled-in defaults.
  RPC does not report those defaults.
- `(differs)`: your vote is not the current network setting. That is expected while a fee vote is in progress.

## Setting votes

All votes are set in `postfiatd.cfg`. They only matter on a validator with a validator token, because
non-validating nodes do not vote. Restart the container after you edit the file. Values are in drops
(1 PFT = 1,000,000 drops):

```ini
[voting]
reference_fee = 10
account_reserve = 10000000
owner_reserve = 2000000

[veto_amendments]
<64-hex amendment id> <Name>

[amendments]
<64-hex amendment id> <Name>
```

`[veto_amendments]` votes against an amendment and `[amendments]` votes for it. Coordinate any vote with the
other Post Fiat validators before you change it. You can also change votes at runtime with the admin
`feature <name> accept|reject` command, which this tool never sends. A runtime change is lost on restart
unless you also put it in the config.

## Tests

```bash
python3 -m pytest -v amendments/tests     # parsing, risk detection, ETA, fee formats, config parsing, --compare
ruff check amendments/
```

Fixtures in `tests/fixtures/` are a sanitized subset of real testnet responses (no node keys, host ids or IPs):

- `healthy/`: three real amendments, exit `0`.
- `enabled-unsupported/`: adds an enabled amendment that the build does not support. Its id is fake
  (`FFFF…0001`, `FixtureFutureAmendment`), and `amendment_blocked=true` is set. Exit `2`.
- `pending-unsupported/`: the same fake amendment holding a majority, plus a `[voting]` config. Exit `2`.

## Known limits

- The majority hold time is not exposed over RPC. The ETA assumes `--majority-hours` (default 336 h, the
  upstream XRPL-family default). Override it if Post Fiat uses a different value.
- `count` / `threshold` vote tallies are shown only when `feature` returns them. That depends on the node
  having seen a flag-ledger vote.
- The fee vote comes from the config file. A runtime change made with admin commands is not visible.
- On a light/non-validating node, `vetoed` reflects the node's local stance. It does not vote on the network.
- The tool judges the node it runs against. Run it on each validator and sentry host, because each can
  run a different build.

Example run against a synced testnet node, with the negative tests: [`../logs/amendments/`](../logs/amendments/).
Testnet amendment state from that run: [`REPORT.md`](REPORT.md).
