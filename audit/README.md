# Read-only host audit (`pft-audit.sh`)

`pft-audit.sh` audits a running Post Fiat validator or sentry host and prints one line per check:
`PASS`, `WARN`, `FAIL` or `INFO`, the reason, and for WARN/FAIL a one-line fix hint.
It only reads (`sshd -T`, `ss`, `ufw status`, `iptables -S`, `docker inspect`, `stat`, `apt list`, `timedatectl`,
the node's `server_info` via `docker exec`). It changes nothing on the host. Output contains no IP addresses,
usernames or secrets, so it can be shared after a quick read.

```bash
sudo ./audit/pft-audit.sh                    # text report
sudo ./audit/pft-audit.sh --json | jq .      # machine-readable summary
sudo ./audit/pft-audit.sh --only ssh.,fw.    # subset by id prefix
./audit/pft-audit.sh --list                  # all check ids
```

Exit codes: `0` everything PASS (INFO lines do not count), `1` at least one WARN, `2` at least one FAIL, `3` usage error.
Use it from cron or a monitoring agent the same way as `postfiat-health`.

Environment: `CONTAINER` (default: first running `agtipft/postfiatd` container), `PEER_PORT` (2559),
`COMPOSE_DIR` (/opt/postfiatd), `BACKUP_DIR` (/var/backups/postfiat).

The script detects the host role: **sentry** (nginx stream listening on the peer port, see [`sentry/`](../sentry/README.md)),
**validator-behind-sentry** (`[peer_private]=1` and `[ips_fixed]` in `postfiatd.cfg`) or **standalone**.

## Checks

| Id | PASS when | Otherwise | Why it matters |
|----|-----------|-----------|----------------|
| `ssh.root_login` | `PermitRootLogin` is not `yes` | FAIL if root + password login are both allowed, WARN if root may log in with keys | root password login is the most brute-forced door on any VPS |
| `ssh.password_auth` | `PasswordAuthentication no` | WARN | keys cannot be guessed; note that in `sshd_config.d/` the first value wins (cloud-init often ships `yes`) |
| `ssh.empty_passwords` | `PermitEmptyPasswords no` | FAIL | |
| `ssh.x11_forwarding` | `X11Forwarding no` | WARN | not needed on a server; extra attack surface |
| `ssh.max_auth_tries` | `MaxAuthTries` <= 4 | WARN | fewer guesses per connection |
| `ports.admin_loopback` | 5005/6005/6006/50051 only on 127.0.0.1 | FAIL | admin RPC can stop the node or change its config |
| `ports.public_listeners` | only SSH and the peer port listen on non-loopback addresses | WARN (lists the ports) | a default-deny firewall is one rule away from exposing them |
| `fw.ufw_active` | ufw active with default deny incoming | FAIL | |
| `fw.ufw_peer_limit` | `LIMIT` rule on 2559/tcp | WARN if `ALLOW` or missing | per-source rate limit for host-level listeners (e.g. the sentry's nginx) |
| `fw.docker_user_limit` | 2559 published by Docker has connlimit + rate limit (or a fixed-source rule) in `DOCKER-USER` | FAIL; INFO if 2559 is served by a host process | Docker-published ports go through FORWARD and bypass ufw |
| `fw.docker_bypass` | no container port other than 2559 is published on a public address | FAIL | same bypass: ufw would not protect it |
| `docker.socket` | `/var/run/docker.sock` is `660 root:docker` | FAIL | socket access = root |
| `docker.group` | INFO: number of non-root docker group members | | each member is root-equivalent |
| `container.privileged` | not `--privileged` | FAIL | |
| `container.capabilities` | no `cap_add` | WARN | |
| `container.network` | not host network | WARN | host networking binds admin ports on the host directly |
| `container.no_new_privileges` | `no-new-privileges` set | WARN | the official image runs as root; this blocks setuid escalation |
| `container.restart` | `unless-stopped` or `always` | WARN | node must come back after a crash or reboot |
| `container.log_rotation` | log driver is not unbounded json-file | WARN | full disk stops the node |
| `container.user` | INFO: container user | | the official image runs as `0:0`; documented, not changed |
| `files.node_config` | `postfiatd.cfg` has no token/seed, or is mode x00/x40 | FAIL | a `[validator_token]` is the validator identity |
| `files.monitor_env` | `/etc/postfiat-monitor.env` is `600 root` (if present) | FAIL | holds the ntfy topic/token |
| `files.sshd_config` | `sshd_config` owned by root, not group/world-writable | FAIL | |
| `files.authorized_keys` | no `.ssh` dir or `authorized_keys` group/world-writable | FAIL | |
| `files.backups` | backup archives not readable by other users (if the dir exists) | WARN | archives contain the node config |
| `patch.unattended` | unattended-upgrades installed and enabled | WARN | |
| `patch.pending_security` | no `-security` upgrades pending (cached lists) | WARN | |
| `patch.reboot` | no `/var/run/reboot-required` | WARN (lists the packages) | an installed kernel fix is not active until reboot |
| `time.ntp` | `NTPSynchronized=yes` | FAIL | consensus and TLS depend on the clock |
| `node.state` | `server_state` full / proposing / validating | WARN syncing/connected, FAIL otherwise | |
| `node.peers` | peers > 0 | FAIL | |
| `relay.mode` | INFO: detected role | | |
| `relay.sentry_upstream` | (sentry) nginx forwards to a loopback upstream that is not also public | FAIL | the sentry node should only be reachable through the relay |
| `relay.sentry_http` | (sentry) nginx serves no public HTTP site | WARN | the stock default site is not needed on a relay |
| `relay.validator_private` | (validator-behind-sentry) `[peer_private]=1` with `[ips_fixed]` | | INFO on a standalone node |
| `relay.validator_fw` | (validator-behind-sentry) inbound 2559 restricted to the sentry in ufw and DOCKER-USER | WARN | |

## Limits

- `patch.pending_security` uses the cached package lists; run `apt-get update` first for a current answer.
- Ports are read from `ss`; a firewall rule allowing a port that nothing listens on is not reported.
- It does not test reachability from outside. Pair it with a probe from a different host when you change firewall rules.

## Proof

[`logs/audit/`](../logs/audit/): deliberate misconfigurations caught as FAIL (exit 2) and restored (exit 0) on both hosts.
In N2 the removal loop deleted 3 of the 4 DOCKER-USER rules: the connlimit rule could not be deleted from its `iptables -S`
form (`Bad rule`, visible in the log). The check still FAILs because it requires both connlimit and the rate-limit rule.
Kernel versions are redacted in published logs.

Live findings on both hosts, with what was fixed and the log that shows each rerun:
[`FINDINGS.md`](FINDINGS.md) (logs 2–11 in `logs/audit/`). The final runs on both hosts exit 0.
