# pft-vlwatch logs (2026-10-24, Ubuntu 22.04.5)

| log | what |
|---|---|
| `2-lint.log` | shellcheck of all four scripts (exit 0; the only disables are listed) + `systemd-analyze verify` of the units |
| `3-tests.log` | offline suite `vlwatch/tests/run-tests.sh`: 48 passed, 0 failed |
| `4-live-validator.log` | live run on validator-host: 2 text runs (baseline, then seq vs saved state) + `--json`, all 11 PASS |
| `5-live-sentry.log` | the same on sentry-host (`--container postfiatd-sentry`), same script sha256 |
| `6-drill-run1-prefix.log` | first drill run. It passed (1 message), but it showed a display bug: the same expiry read "EXPIRED 2 day(s) ago" and then "3 day(s) ago" 2 s later (`floor()` of a negative day count). The fix rounds toward zero, and a regression test was added. Kept as found -> fixed. |
| `6-drill.log` | final drill with the fixed script: live capture -> PASS (silent) -> injected expired list + refresh error + seq rollback -> FAIL, exactly 1 message on a throwaway topic (`<redacted>`) -> unchanged FAIL (silent) |
| `7-install-sandbox.log` | `install.sh` in a throwaway ubuntu:22.04 container (systemctl stubbed): script-only, missing `--ntfy-env` error, timer install with root 0600 env file, uninstall |

Logs 2-6 (final drill) and 7 were run with script sha256 `a2f0744fca3201a05a481a8cd3e166098d1307ecf9233602975b4bef4c2f721a`.
The timer was not installed on either live host.
