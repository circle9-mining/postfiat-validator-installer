# Hardened Post Fiat Testnet Validator Installer

One command to deploy a Post Fiat testnet validator node on Ubuntu 22.04+ with Docker. Admin/RPC ports are locked to localhost, the firewall is default-deny with a rate-limited peer port, and the install finishes with a health check.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/install.sh | sudo bash
```

Custom SSH port or directory:

```bash
curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/install.sh | sudo SSH_PORT=2222 POSTFIATD_DIR=/opt/postfiatd bash
```

Read the script before piping it to a shell.

## Prerequisites

- Ubuntu Server 22.04 LTS or newer
- 2 CPU cores, 4 GB RAM, 100 GB storage (official minimum)
- Root / sudo access
- Inbound TCP 2559 reachable from the internet (check your provider's cloud firewall too)
- Use a fresh or dedicated host: the installer sets UFW to default-deny incoming. It allows your SSH port first and does not reset existing rules, but other services on the box will need their own `ufw allow` rules.

## What it does

1. Installs Docker, Compose v2, UFW, curl, jq, python3
2. Firewall:
   - UFW: allow SSH, `limit` TCP 2559, default deny incoming / allow outgoing
   - `DOCKER-USER` iptables chain: per-IP connection cap (50) and new-connection rate limit (100/s, burst 50) on 2559, persisted by the `postfiat-docker-user` systemd unit
3. Downloads the official compose file from `postfiatorg/postfiatd`, rewrites admin/RPC ports to `127.0.0.1`, and verifies the resolved config before starting
4. Pulls and starts `agtipft/postfiatd:testnet-light-latest`, logging the resolved image digest
5. Installs `postfiat-health` and runs it

## Port map

| Port  | Purpose              | Binding        | Public |
|-------|----------------------|----------------|--------|
| 2559  | Peer protocol        | 0.0.0.0        | Yes (rate-limited) |
| 5005  | Admin JSON-RPC       | 127.0.0.1      | No |
| 6005  | WebSocket            | 127.0.0.1      | No |
| 6006  | Admin WebSocket      | 127.0.0.1      | No |
| 50051 | gRPC                 | 127.0.0.1      | No |
| SSH   | Remote access        | host           | Yes |

## Health check

```bash
sudo postfiat-health
```

Checks: container running; admin ports on 127.0.0.1 only; peer port listening; UFW active with a LIMIT rule on 2559; DOCKER-USER rate limit present; RPC responding with `server_state`, build version, peers and ledgers; build compared with the foundation RPC. Exits 0 when healthy, 1 otherwise, so it works in cron or monitoring.

A fresh node reports `full` or `syncing`. It reports `proposing` only after you add a validator token (next section).

## Monitoring add-on (ntfy alerts)

A systemd service + timer that runs `postfiat-health` every 5 minutes and pushes an alert to [ntfy](https://ntfy.sh) when the node is unhealthy, then a single recovery notice when it's back.

**Alert rules**
- Unhealthy = `postfiat-health` fails **or** `server_state` is not `full`/`proposing`
- One alert when it goes unhealthy; repeat cycles are suppressed (optional reminder via `REMIND_MINUTES`)
- One recovery alert when it returns to healthy, with approximate downtime

**Install** (requires the main installer above):

```bash
curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/monitor/install-monitor.sh | sudo bash
```

Optional: `... | sudo NTFY_TOPIC=your-long-random-topic NODE_LABEL=pft-01 bash`. If no topic is given, a random one is generated. Get it with `sudo grep NTFY_TOPIC /etc/postfiat-monitor.env` and subscribe in the ntfy app. Topics on ntfy.sh are readable by anyone who knows the name, so keep it random and private.

**Config:** `/etc/postfiat-monitor.env` (mode 600). See [`monitor/postfiat-monitor.env.example`](monitor/postfiat-monitor.env.example) for `NTFY_TOPIC`, `NTFY_SERVER`, `NTFY_TOKEN`, `NODE_LABEL`, `HEALTHY_STATES`, `REMIND_MINUTES`.

**Files**

| Repo file | Installed to |
|-----------|--------------|
| `monitor/postfiat-monitor.sh` | `/usr/local/bin/postfiat-monitor` |
| `monitor/postfiat-monitor.service` | `/etc/systemd/system/postfiat-monitor.service` |
| `monitor/postfiat-monitor.timer` | `/etc/systemd/system/postfiat-monitor.timer` (every 5 min) |
| `monitor/postfiat-monitor.env.example` | `/etc/postfiat-monitor.env` |

**Use**

```bash
systemctl list-timers postfiat-monitor.timer   # next run
sudo systemctl start postfiat-monitor.service  # run a check now
tail -f /var/log/postfiat-monitor.log          # history
```

**Test end to end** (stops and restarts the container): `sudo bash monitor/test-monitor.sh 2>&1 | tee monitor-test.log`. See [`logs/monitor-test.log`](logs/monitor-test.log).

**Uninstall**

```bash
curl -fsSL https://raw.githubusercontent.com/darkmatter-sudo/postfiat-validator-installer/main/monitor/install-monitor.sh | sudo bash -s -- --uninstall
```

Removes the units, script and state; keeps `/etc/postfiat-monitor.env` and the log.

## Becoming a proposing validator

This installer sets up a hardened, synced node. Validator identity is deliberately left to you, so private keys are never handled by a script or written to logs. Follow steps 5–8 of the [official guide](https://postfiat.org/validator-setup/):

- generate keys and back up `validator-keys.json` offline
- run `set_domain` and inject the `[validator_token]` into `postfiatd.cfg`
- publish `/.well-known/pft-ledger.toml` on your domain

Never paste keys or tokens into chats or issues.

## Security notes

- **Why both UFW and DOCKER-USER?** Docker-published ports are routed through the FORWARD chain and bypass UFW's INPUT rules. The UFW `limit` rule covers host-level traffic; the DOCKER-USER rules are what actually rate-limit traffic to the container.
- **Image tag:** uses the official rolling `testnet-light-latest` tag, as the Post Fiat guide requires (version-pinned tags silently miss hotfixes). The installer refuses any other tag and logs the exact digest it ran.
- Admin ports are bound to loopback in the compose file itself, so they stay private even if the firewall is changed.
- Logs: `/var/log/postfiat-installer.log`. Node data: `/opt/postfiatd`.

## Backup and restore add-on

[`backup/`](backup/README.md): `pft-backup.sh` writes a timestamped tar.gz of the node config (postfiatd.cfg, validators.txt,
compose file, add-on units, firewall rules) with a SHA-256 manifest, retention pruning and a daily systemd timer. Secrets are
excluded unless you pass `--include-secrets`, which encrypts the archive with gpg. `pft-restore.sh` verifies the archive, restores it and
waits for `server_state: full`, and has a `--dry-run` mode. Restore drill onto a second host and tamper tests: [`logs/backup/`](logs/backup/).

```bash
sudo ./backup/pft-backup.sh && sudo ./backup/pft-restore.sh --dry-run /var/backups/postfiat/pft-backup-<UTC>.tar.gz
```

## Security audit add-on

[`audit/`](audit/README.md): `pft-audit.sh` is a read-only audit of a validator or sentry host: SSH hardening, loopback-only
admin ports, ufw and DOCKER-USER limits on 2559, Docker daemon/container posture, file permissions, patching, time sync,
node health and sentry/relay mode. One PASS/WARN/FAIL line per check with a fix hint, `--json` summary, exit codes 0/1/2.
Every check is documented in [`audit/README.md`](audit/README.md); FAIL-detection demos are in [`logs/audit/`](logs/audit/).

```bash
sudo ./audit/pft-audit.sh            # or: --json | jq .
```

## Secrets and config-exposure check add-on

[`secrets/`](secrets/README.md): `pft-secrets-check.sh` complements `audit/` with secret-leak and exposure checks.
It checks `postfiatd.cfg` admin roles and port exposure (via `docker port`), and `[validator_token]`/`[validation_seed]`
file modes, including stale copies. It scans `docker inspect` env/cmd, container logs, `debug.log`, shell history,
world-readable node files and backup archives for secret-format strings, printing counts only, never values.
A `--probe` mode runs from a second host and makes one TCP connect per admin/RPC port and the peer port.
Exit codes 0/1/2, `--json`. `positive-control.sh` plants dummy secrets and shows they are flagged.
Found → fixed → verified runs on both hosts: [`logs/secrets/`](logs/secrets/).

```bash
sudo ./secrets/pft-secrets-check.sh   # from another host: ./secrets/pft-secrets-check.sh --probe <node-ip>
```

## Integrity monitor add-on

[`integrity/`](integrity/README.md): `pft-integrity.sh` records a root-only 0600 manifest (hashes, modes, owners,
mtimes; never contents) of compose files, config-volume files, add-on units, `/usr/local/bin`, sshd config, UFW and
DOCKER-USER rules, the running image vs its registry digest, local image tags and the container's effective config.
`verify` reports added/removed/changed items with the changed fields (exit 0/1/2, `--json`). `accept --reason` re-baselines
and logs who/why. An optional hourly timer sends ntfy only when findings change. The four-change tamper drill on
both hosts is in [`logs/integrity/`](logs/integrity/).

```bash
sudo install -m 755 integrity/pft-integrity.sh /usr/local/bin/pft-integrity && sudo pft-integrity baseline
sudo pft-integrity verify
```

## Amendment and fee-voting status add-on

[`amendments/`](amendments/README.md): `pft-amendments.py` is a read-only report of every amendment's state
(enabled / supported / vetoed / pending majority with an activation ETA) and of the network fee settings
next to your node's `[voting]` vote. It uses only read-only admin RPC methods (`feature`, `server_info`,
`server_state`, `fee`, `ledger_entry`). Exit code `2` warns of amendment-blocked risk: an amendment that is
enabled or about to activate but is not supported by your build. `--json` writes snapshots and `--compare`
diffs against one. Live run and negative tests: [`logs/amendments/`](logs/amendments/).

```bash
sudo ./amendments/pft-amendments.py  # or: --json > snap.json; later --compare snap.json
```

## Peer diagnostics add-on

[`peers/`](peers/README.md): `pft-peers.py` checks your node's peers: count vs `[peers_max]`, inbound/outbound,
peer build versions (older than yours), latency p50/p90/max, connection age, ledger coverage, and whether a
validator's fixed sentry peer is connected. It uses only the read-only admin RPC methods `peers` and
`server_info`. Exit codes `0` OK, `1` WARN, `2` FAIL; `--json` for scripts. The output never contains peer IPs,
ports or public keys, only short salted-hash labels. Live run on both hosts and tests: [`logs/peers/`](logs/peers/).

```bash
sudo ./peers/pft-peers.py --read-config   # sentry host: --container postfiatd-sentry
```

## Alert rules add-on

[`alerts/`](alerts/README.md): 16 Prometheus alert rules for the exporter's metrics. They cover node/RPC down,
not full or not proposing, peers, validated-ledger age and stall, complete_ledgers gaps, close-time drift,
load_factor, container restarts and disk. Each rule has a severity label, a `for:` duration and a runbook link to
its threshold rationale and operator response. The add-on includes promtool unit tests (firing and non-firing per
alert). `run-stack.sh` runs Prometheus and Alertmanager in Docker on loopback only, with optional ntfy delivery.
Live stop-the-node drill: [`logs/alerts/`](logs/alerts/).

```bash
cd alerts && DOCKER="sudo docker" ./run-stack.sh up   # optional: NTFY_ENV_FILE=~/.pft-ntfy.env
```

## Upgrade

```bash
cd /opt/postfiatd && docker compose pull && docker compose up -d && sudo postfiat-health
```

## Uninstall

```bash
cd /opt/postfiatd && docker compose down
sudo systemctl disable --now postfiat-docker-user.service
sudo rm -f /etc/systemd/system/postfiat-docker-user.service /usr/local/sbin/postfiat-docker-user.sh /usr/local/bin/postfiat-health
sudo ufw delete limit 2559/tcp
```

Back up any validator keys before deleting `/opt/postfiatd`.

## Test run log

See [`logs/test-run.log`](logs/test-run.log) for a full run on a clean Ubuntu 22.04 host.
