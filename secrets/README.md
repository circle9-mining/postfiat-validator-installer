# Secrets and config-exposure check (`pft-secrets-check.sh`)

`pft-secrets-check.sh` is a read-only check of where a Post Fiat node's secrets could leak and which
ports could be reached from outside. It complements [`audit/`](../audit/README.md), which covers SSH,
firewall and container hardening. This add-on looks at:

- `postfiatd.cfg` port sections and admin roles
- the `[validator_token]` / `[validation_seed]` files
- leak paths: `docker inspect`, container logs, `debug.log`, shell history, world-readable files, backups
- a probe from a second host you operate

It never prints a secret value. Output shows only file or container names, match counts, modes and owners.
User names in `/home/<name>` paths are masked unless you pass `--show-paths`.

```bash
sudo ./secrets/pft-secrets-check.sh                 # text report on the node host
sudo ./secrets/pft-secrets-check.sh --json | jq .   # machine-readable
sudo ./secrets/pft-secrets-check.sh --only leak.    # subset by id prefix
./secrets/pft-secrets-check.sh --list               # all check ids
# from a SECOND host you operate (e.g. the sentry), against the node's public address:
./secrets/pft-secrets-check.sh --probe <node-public-ip> --label validator-host
sudo ./secrets/positive-control.sh                  # plant dummy secrets, prove they are flagged, clean up
```

Exit codes are the same as `audit/`:

- `0`: every check PASS (INFO lines don't count)
- `1`: at least one WARN
- `2`: at least one FAIL
- `3`: usage error

Environment variables:

- `CONTAINER`: auto-detects the first running `postfiatd` container.
- `COMPOSE_DIR`: defaults to the container's compose project dir, then `/opt/<container>`, then `/opt/postfiatd`.
- `BACKUP_DIR` (`/var/backups/postfiat`), `PEER_PORT` (2559), `LOG_TAIL` (20000 docker log lines).

Runtime: about 11 s on the test host. Most of that is scanning roughly 100 MB of `debug.log`.

## Secret patterns

A match of any of these patterns is a FAIL wherever it is found (`SECRET_RX` in the script, PCRE):

| Pattern | Catches |
|---------|---------|
| `s` + 28 base58 chars, or `sEd` + 28, not inside a longer base58 word | XRPL-family seeds (`validation_seed`, wallet secrets) |
| `eyJtYW5pZmVzdCI6`, `eyJ2YWxpZGF0aW9uX3NlY3JldF9rZXki` | base64 of `{"manifest":` / `{"validation_secret_key"`, i.e. the start of a validator token blob |
| `validation_secret_key`, `master_seed` | `validator-keys` / `wallet_propose` output pasted somewhere |
| `-----BEGIN ... PRIVATE KEY-----` | PEM private keys |
| `ghp_…`, `github_pat_…`, `tk_…` | GitHub and ntfy access tokens |

`KNOWN_EXAMPLES` lists public documentation strings that match these patterns but aren't secrets. It holds one
entry: the example seed that the stock `postfiatd.cfg` prints in its comments. The first real run flagged that
seed (see "Found → fixed → verified").

Environment variables are also reported by name. A name containing SEED/SECRET/TOKEN/PASSW/PRIVATE/API_KEY/
NTFY/WEBHOOK with a non-empty value is reported. `NAME_FILE=/path` pointers (Docker's convention for file-based
secrets) are not reported.

## Checks

| Id | PASS when | Otherwise | Why / remediation |
|----|-----------|-----------|-------------------|
| `cfg.admin_roles` | every `admin=` / `secure_gateway=` value is loopback | FAIL | an admin role for a non-loopback source lets that source stop the node or change its config. Set `admin = 127.0.0.1` |
| `cfg.admin_exposure` | no section with an admin role is reachable on a public host address. Docker: `docker port`; host network or native install: the section's `ip` | FAIL | publish as `127.0.0.1:PORT:PORT` |
| `cfg.rpc_exposure` | no non-peer RPC/WS section is public | WARN | only run public RPC on purpose, and rate-limit it |
| `cfg.container_bind` | RPC/WS sections bind loopback inside the container, or bind `0.0.0.0` but no other container shares the node's Docker network | WARN when other containers share the network | Docker needs `ip = 0.0.0.0` in the container to publish a port, so the container's network is the real boundary. Keep `postfiatd` on its own network |
| `cfg.secret_sections` | token/seed present and every file holding it (including copies like `postfiatd.cfg.pre-*`) is owner-only | FAIL if group/world-readable; INFO if absent | `chmod 600` and delete stale copies. Values are never shown |
| `keys.validator_keys` | no `validator-keys*.json` on the host (INFO) | WARN if present 600, FAIL if readable beyond owner | keep the master key offline. Only the token belongs on the server |
| `leak.docker_env` | no credential-named env var and no secret-format value in env/cmd/args/labels of any running container | WARN (name), FAIL (value) | anyone who can run `docker inspect` can read env vars. Mount a 0400/0600 file instead |
| `leak.container_logs` | no secret-format string in the last `LOG_TAIL` lines of `docker logs` | FAIL | rotate the key, then recreate the container to drop its json log |
| `leak.debug_log` | no secret-format string in the node log dir (`debug.log*`, `*.log`, `*.gz`) | FAIL | rotate the key, then delete or truncate the affected logs |
| `leak.shell_history` | no secret-format string in `/root` and `/home/*` `.*history` files, all owner-only | FAIL (content), WARN (mode) | rotate the secret, delete the lines, use `HISTCONTROL=ignorespace` and a leading space |
| `leak.world_readable` | node dirs (compose dir + config volume) contain no world-writable file and no world-readable file that holds a secret | FAIL; WARN for world-readable files with credential-style names (`*.env`, `*token*`, `*.key`, …) that hold no secret today | `chmod 600` / `o-rwx` |
| `leak.backups` | backup dir is 700, every file is 600-or-stricter and owned by root, no plaintext `.tar.gz` holds a token | FAIL (modes), WARN (plaintext token) | the `backup/` add-on strips secrets by default and can gpg-encrypt |
| `probe.admin_ports` | from another host: 5005, 6005, 6006 and 50051 are closed or filtered | FAIL | admin/RPC must not be reachable from outside |
| `probe.peer_port` | from another host: the peer port is open | WARN | peers can't connect otherwise |

The probe opens one TCP connection per port, with a 3 s timeout, and sends no data. Only point it at hosts you
operate.

## Found → fixed → verified (this repo's two hosts)

| # | Host | Finding | Fix | Verified |
|---|------|---------|-----|----------|
| 0 | validator | Checker false positive in a first trial run (not captured to a log): `leak.world_readable` FAIL on `postfiatd.cfg` (2 matches) | Both matches were the public example seed in the stock config comments. Added it to `KNOWN_EXAMPLES` | log 1 onward: no hit |
| 1 | validator | `leak.docker_env` WARN: the `alerts/` ntfy bridge received `NTFY_URL` through `--env-file`, so the topic was readable with `docker inspect` | `alerts/run-stack.sh` now mounts the file read-only at `/run/secrets/ntfy.env` and runs the bridge as the file's unprivileged owner. `ntfy_bridge.py` reads it through `NTFY_URL_FILE`. A test alert was still delivered (HTTP 200) | log 3; logs 6/7 PASS |
| 2 | validator | `leak.world_readable` WARN: compose `.env` was 644. It holds no secret today, but compose secrets would go there | `chmod 600`. `install.sh` and `backup/pft-restore.sh` now create/restore `.env` as 0600 | log 3; logs 6/7 PASS |
| 3 | validator | Checker false positive after fix 1: `NTFY_URL_FILE` (a path) flagged by name | `NAME_FILE=/path` pointers are excluded | log 4 → log 6 |

The sentry host passed every check in both runs. Each host probed the other: admin/RPC ports were filtered and
the peer port was open.

## Logs (`logs/secrets/`)

Every log starts with an OS line. Public IP addresses are replaced with `<redacted-ip>`. Nothing else is
edited.

| File | Content |
|------|---------|
| `1-validator-before.log` | shellcheck, first full run (exit 1: 2 WARN), probe of the sentry |
| `2-sentry-before.log` | sentry run (exit 0), probe of the validator |
| `3-validator-fixes.log` | fixes 1 and 2, with diffs, the stack restart, a delivery test and the `.env` mode change |
| `4-validator-after-fixes.log` | re-run: `leak.world_readable` PASS, `leak.docker_env` still WARN because of the `_FILE` false positive (finding 3) |
| `5-sentry-after-fixes.log` | sentry re-run (exit 0) and probe |
| `6-validator-final.log` | final run: exit 0, plus JSON summary and JSON probe |
| `7-sentry-final.log` | final sentry run (exit 0) and probe |
| `8-positive-control.log` | dummy seed/token planted in a history file, a world-readable node-dir file and a container env var. Each is flagged FAIL, the probe of loopback reports open admin ports as FAIL, 0 dummy values appear in the output, then everything is removed and the checks PASS again |
