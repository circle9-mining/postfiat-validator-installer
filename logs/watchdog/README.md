# watchdog logs

Raw output of commands run on the validator host and the sentry host (both Ubuntu 22.04.5 LTS), 2026-10-23.

| File | What |
|---|---|
| `1-unit-tests-prefix.log` | first `./test-watchdog.sh` run, 31/31 PASS. It still showed two real defects, fixed before run 2: case 18 passed only because a float `last_sent` caused a bash arithmetic error (see its stderr line), and future-ts heartbeats showed negative ages; the `rpc_down` detail read "180000s behind" |
| `2-unit-tests.log` | `./test-watchdog.sh` after the fixes: 33/33 PASS (two assertions added for the fixed paths) |
| `3-install-two-hosts.log` | `install.sh heartbeat` on the validator, `install.sh watchdog` on the sentry, file modes, forced-command `authorized_keys` line (key truncated), pinned vs actual host-key fingerprint |
| `4-drill.log` | `./drill.sh`: STALE -> RECOVERED, BADSIG -> RECOVERED on the live pair, throwaway ntfy topic |
| `4-drill-ntfy.json` | the messages on the throwaway test topic, as returned by the ntfy poll API |
| `5-integrity-rebaseline.log` | `pft-integrity verify` (3 expected WARN per host: the new script + 2 units) -> `accept` -> `verify` PASS on both hosts |

Redactions (only these): public IPs -> `<redacted-ip>`, the throwaway drill topic -> `pftwd-drill-<redacted>`,
the local checkout path -> `<repo>/`. The operator's ntfy topic was never used in tests or the drill.
