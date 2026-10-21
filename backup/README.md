# Backup and restore add-on

Back up a Post Fiat node's configuration to a verifiable archive and rebuild the node on a fresh host from it.
Built for the `/opt/postfiatd` Docker install from this repo (Ubuntu 22.04).

## Files
- `pft-backup.sh` – timestamped `pft-backup-<UTC>.tar.gz` + `MANIFEST.sha256` inside + sidecar `<archive>.sha256`; secrets excluded by default; `--include-secrets` encrypts with `gpg --symmetric` (AES256); retention pruning (`--keep N`, default 14).
- `pft-restore.sh` – verifies sidecar and manifest (unlisted files are refused too), restores compose files and node config, starts the container and waits for `server_state: full` (`--timeout`, default 900 s). `--dry-run` verifies and prints every action without changing the host. Exit codes: 0 ok, 1 error, 2 usage, 3 verification failed, 4 timeout.
- `pft-backup.service`, `pft-backup.timer` – daily backup at 03:17 (±15 min).

## What is backed up, and why

| Item | Source | Why |
|---|---|---|
| `postfiatd.cfg`, `validators.txt` | config volume, via `docker cp` | the node's whole behaviour: peers, ports, `[peer_private]`, UNL source |
| `docker-compose.yml`, `.env` | `/opt/postfiatd` | image tag, loopback-only admin ports, network |
| add-on units + scripts | `postfiat-monitor.*`, `postfiat-docker-user.service`, `pft-exporter.service`, `/usr/local/bin/postfiat-health`, `/usr/local/bin/postfiat-monitor`, `/usr/local/sbin/postfiat-docker-user.sh`, `/opt/pft-exporter/pft_exporter.py` | rebuild monitoring/hardening without re-running each installer; `units-enabled.txt` records which were enabled |
| firewall | `/etc/ufw/user.rules`, `user6.rules`, `ufw status verbose`, `iptables -S DOCKER-USER` | reference copy of the 2559 rate limits |

**Not backed up:**
- the ledger database (`postfiatd-data` volume): it is large and a light node re-syncs in minutes (47 s to `full` in the drill below);
- by default, secrets: the `[validator_token]`, `[validation_seed]`, `[node_seed]` sections are stripped from `postfiatd.cfg`, and `/etc/postfiat-monitor.env` (ntfy topic) is left out. `META.txt` in the archive lists what was excluded.

`--include-secrets` keeps them and encrypts the whole archive. Keep the passphrase somewhere other than the backup.
Never run two nodes with the same `[validator_token]`: restore a secrets archive only after the old validator is stopped for good.
Your offline `validator-keys.json` is not on the node and is not handled here; keep it offline.

## Usage

```bash
# backup (as root)
sudo ./pft-backup.sh                       # /var/backups/postfiat, keep 14
sudo ./pft-backup.sh --keep 30 --dest /mnt/offsite
sudo PFT_BACKUP_PASSPHRASE_FILE=/root/.pft-backup-pass ./pft-backup.sh --include-secrets

# daily timer
sudo install -m 0755 pft-backup.sh /usr/local/sbin/pft-backup.sh
sudo install -m 0644 pft-backup.service pft-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now pft-backup.timer
```

Retention: after each run, the newest `KEEP` archives (plain and `.gpg` together, ordered by the UTC timestamp in the name) are kept and the
rest are deleted along with their `.sha256`. Change it with `Environment=KEEP=` in the service. Copy archives off the host
(e.g. `rsync` to another machine); a backup that lives only on the node does not survive losing the node.

## Restore procedure (fresh Ubuntu 22.04 host)

1. Install Docker and the compose plugin (`apt-get install docker.io docker-compose-v2`), or run this repo's `install.sh`. `pft-restore.sh` stops before changing anything if the plugin is missing.
2. Copy the archive **and** its `.sha256` to the host.
3. `sudo ./pft-restore.sh --dry-run <archive>` – check the verification result and the action list.
4. Make sure nothing else listens on 2559, then `sudo ./pft-restore.sh --timeout 900 <archive>`. Encrypted: set `PFT_BACKUP_PASSPHRASE_FILE`.
5. Optional: `--with-units` installs the add-on units/scripts (not enabled; the log shows what was enabled on the source), `--with-firewall` installs the saved ufw rules and reloads ufw. Both are off by default because a source host's firewall can lock you out of a different host. Check the rules first.
6. `sudo postfiat-health`.

Existing compose files and ufw rules are kept as `*.pre-restore-<UTC>`.

## Test results (`../logs/backup/`, Ubuntu 22.04.5, two hosts)
- `1-backup-run.log` – shellcheck clean; three plain backups and one `--include-secrets` backup with `--keep 3` (the oldest is pruned), archive listing, manifest, `META.txt`, gpg file type.
- `2-restore-drill.log` – on the second host (normally a sentry relay): dry-runs (plain + encrypted), then the live restore. **The first attempt failed** because that host had no `docker compose` plugin. I added the preflight check, installed `docker-compose-v2` and re-ran it: manifest OK, container started, `server_state: full` after 47 s, restored config hashes match the manifest. Then the drill node and its volumes were removed, nginx was restarted and the sentry was back to `full`.
- `3-negative-test.log`, `4-negative-test-rerun.log` – a byte flipped in the archive, an edited `postfiatd.cfg` with a regenerated sidecar, an unlisted extra file, and a wrong gpg passphrase are all rejected with exit 3 and nothing is restored. The rerun follows a cosmetic `die()` fix (the exit code was echoed into the message).
- `5-shellcheck-timer.log` – final shellcheck (exit 0), timer installed and verified, one timer-triggered backup, validator healthy.

Limitations: `--with-units` and `--with-firewall` were only exercised in `--dry-run` (applying the validator's firewall to the live
relay would have changed its role). The drill restored onto a host with the image already cached.
