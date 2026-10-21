# Audit findings — validator-host and sentry-host (2026-10-21)

Tool: [`audit/pft-audit.sh`](pft-audit.sh). Both hosts run Ubuntu 22.04.5 LTS. Logs are in [`logs/audit/`](../logs/audit/).
Only public IPs and version strings are redacted. Nothing else in the logs was changed.

Result: every WARN/FAIL from the first runs was fixed and checked again. Final runs on both hosts: **0 WARN, 0 FAIL**
(validator-host 29 pass / 4 info, sentry-host 27 pass / 5 info). No finding was left as an accepted risk.

| # | Check | Host | Severity | Found in | Fix | Verified in |
|---|-------|------|----------|----------|-----|-------------|
| 1 | `ssh.root_login` | both | FAIL (high) | 2, 3 | Operator installed an SSH key for root and set `PasswordAuthentication no`. Then the agent added `PermitRootLogin prohibit-password` to `sshd_config.d/40-pft-hardening.conf`, ran `sshd -t`, reloaded sshd and confirmed a new key login works | 7 (WARN: keys only), 8, 9, 10 (PASS) |
| 2 | `ssh.password_auth` | both | WARN (high) | 2, 3 | `PasswordAuthentication no` (done by the operator, after a key login was confirmed) | 7, 9, 10 |
| 3 | `ssh.x11_forwarding` | both | WARN (low) | 2, 3 | `X11Forwarding no` in a drop-in placed before the cloud-init file (in `sshd_config.d/` the first value wins) | 4, 5, 6 |
| 4 | `ssh.max_auth_tries` | both | WARN (low) | 2, 3 | `MaxAuthTries 4` (same drop-in) | 4, 5, 6 |
| 5 | `container.no_new_privileges` | both | WARN (medium) | 2, 3 | validator: `docker-compose.override.yml` with `security_opt: no-new-privileges:true`; sentry: container recreated by `sentry/sentry-node.sh` | 4, 5, 6 |
| 6 | `container.log_rotation` | sentry | WARN (low) | 3 | json-file `max-size=100m`, `max-file=10` when the sentry container is recreated | 4, 6 |
| 7 | `ports.public_listeners` | sentry | WARN (medium) | 3 | Removed the nginx default HTTP site. Only 22 and 2559 listen on public addresses | 4, 6 |
| 8 | `relay.sentry_http` | sentry | WARN (low) | 3 | Same fix as #7 | 6 |
| 9 | `fw.ufw_peer_limit` | sentry | WARN (medium) | 3 | The ufw rule for 2559/tcp changed from `ALLOW` to `LIMIT` | 4, 6 |
| 10 | `patch.reboot` | both | WARN (medium) | 2, 3 | sentry: rebooted by the agent (log 4). validator: rebooted by the operator. The installed kernel is now running on both | 6, 7 |
| 11 | `patch.pending_security` | both | WARN (medium) | 7 | Installed the pending security update with `apt-get install --only-upgrade` on both hosts | 8, 9, 10 |

Log key (`logs/audit/`):

- `1-negative-fail-demos.log` — deliberate misconfigurations that make the tool print FAIL, followed by the restore step
- `2-validator-before.log`, `3-sentry-before.log` — first runs
- `4-fixes-round1.log` — fix commands and output (first round)
- `5-validator-after-round1.log`, `6-sentry-after-round1.log` — reruns after round 1. Items 1, 2 and 10 (validator) are
  still open here, because disabling password login before the operator had a key would have locked them out
- `7-validator-after-operator-ssh-change.log` — validator rerun after the operator's key install, password-auth change and reboot
- `8-fixes-round2.log` — `prohibit-password` and the security update on both hosts. Contains one transient
  `Connection refused` during the sshd reload; the retry in the same log succeeds
- `9-validator-final.log`, `10-sentry-final.log`, `11-json-final.log` — final runs (text and `--json`), all exit 0

Lesson: fix SSH last, and only after a key login for the operator has been confirmed. A sudden switch to key-only
login is the easiest way to lock yourself out of a VPS.
