# Cross-host watchdog add-on (dead-man's switch)

Every other add-on in this repo alerts from the validator host itself. If that host is down, frozen, partitioned
or has lost power, it can't report that. This add-on puts the check on a second host (here the sentry):

```
validator host                                         watchdog host (sentry)
pft-heartbeat.timer (60s)                              pft-watchdog.timer (60s)
  server_info @127.0.0.1:5005                            verify spooled heartbeats (HMAC, replay, clock)
  -> {"v":1,"node","ts","server_state",                  age of the last good heartbeat  -> STALE
      "validated_ledger","peers","build_version"}        ledger close_time on public RPC  -> LAGGING
  HMAC-SHA256(body, shared key)                          bad / forged / replayed message   -> BADSIG
  ssh -i /etc/pft-watchdog/id_ed25519 pftwd@sentry  ---> forced command `pft-watchdog receive` -> spool
                                                         ntfy on state change (+ RECOVERED)
```

| File | Host | What |
|---|---|---|
| `pft-heartbeat.sh` | validator | builds, signs and sends one heartbeat (`--print` = dry run) |
| `pft-heartbeat.{service,timer}` | validator | every 60s |
| `pft-watchdog.sh` | watchdog | `receive` (forced command), `check [--notify] [--json]`, `status` |
| `pft-watchdog.{service,timer}` | watchdog | every 60s |
| `install.sh` | both | `heartbeat --relay HOST`, `watchdog --pubkey F --hmac-key F --ntfy-env F`, `uninstall heartbeat\|watchdog [--purge]` |
| `test-watchdog.sh` | either | sandbox tests of every state transition (no root, ntfy to a file) |
| `drill.sh` | validator | live two-host drill on a throwaway ntfy topic |

## Install

```bash
# validator host
sudo ./install.sh heartbeat --relay <sentry-ip> --label validator
#   prints the pinned host-key fingerprint; compare it on the sentry:
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# copy /etc/pft-watchdog/hmac.key and /etc/pft-watchdog/id_ed25519.pub to the sentry over your existing
# admin SSH session (pipe them through stdin, don't paste the key into a command line), then on the sentry:
sudo ./install.sh watchdog --pubkey id_ed25519.pub --hmac-key hmac.key --ntfy-env ntfy.env
#   ntfy.env:  NTFY_SERVER=https://ntfy.sh
#              NTFY_TOPIC=<your topic>
#              NTFY_TOKEN=<optional access token>
sudo pft-watchdog status
```

Both hosts need `curl`, `jq` and `sha256sum` (stock Ubuntu 22.04 + the base installer). Uninstall with
`sudo ./install.sh uninstall heartbeat` / `uninstall watchdog` (`--purge` also deletes keys and state).
If you run the [integrity monitor](../integrity/README.md), re-baseline both hosts after installing:
`sudo pft-integrity accept --reason "watchdog add-on installed"`.

## Alert states

`check` verifies every spooled message (oldest first), then picks one state, in this order:

| State | Condition | ntfy priority | exit |
|---|---|---|---|
| `BADSIG` | a message this run failed: `hmac_mismatch`, `malformed` (not 2 lines / sig not 64 hex / >4 KiB), `bad_fields`, `replay` (ts not newer than the last good one), `ts_future` (ts more than `SKEW_TOL_SEC` ahead) | high | 2 |
| `STALE` | no valid heartbeat for `STALE_AFTER_SEC` (180). A fresh install gets one `STALE_AFTER_SEC` grace period before the first heartbeat | high | 2 |
| `LAGGING` | the heartbeat's validated ledger closed more than `LAG_MAX_SEC` (60) before the heartbeat was taken, or the heartbeat has no validated ledger (e.g. `server_state` `rpc_down`: the host is up but postfiatd is not) | default | 1 |
| `OK` | none of the above | - | 0 |
| `RECOVERED` | the first `OK` after any of the above | default | 0 |

Lag is `heartbeat ts - close_time(validated_ledger)`, with `close_time` taken from the public RPC
(`PUBLIC_RPC`, default `https://rpc.testnet.postfiat.org`, `ledger` method). A node stuck on ledger N keeps sending
fresh heartbeats, but N's close time keeps getting older, so lag grows. **If the public RPC is unreachable, or doesn't
have that ledger, lag is `unknown` and the state can't become `LAGGING`.** An outage on Post Fiat's side never pages
you about your validator. Staleness and signatures are still checked.

ntfy rules:
- One message when an incident state is entered. No repeats while it lasts, and no reminders.
- A change from one incident state to another (e.g. `LAGGING` -> `BADSIG`) is a new incident and gets its own message.
- Per-state cooldown (`COOLDOWN_SEC`, 3600): if the same state comes back within the cooldown (flapping), it's suppressed.
- `RECOVERED` is sent only if that incident's alert was sent. A suppressed incident never gets a stray recovery message.
- The topic and token are read from `/etc/pft-watchdog/ntfy.env`, which must be root-owned and `0600`, otherwise
  nothing is sent. They reach curl through a config file on a file descriptor (`curl -K <(...)`), so they never
  appear in argv (`ps`) or the environment (`/proc/*/environ`, `systemctl show`).

Tunables are environment variables of `pft-watchdog` (set them with `systemctl edit pft-watchdog.service`):
`STALE_AFTER_SEC`, `LAG_MAX_SEC`, `SKEW_TOL_SEC`, `COOLDOWN_SEC`, `PUBLIC_RPC`.

## Clock-skew tolerance

Heartbeat age and lag use the validator's signed `ts`, so both hosts need NTP (stock `systemd-timesyncd` is enough).
- Validator clock **ahead** by up to `SKEW_TOL_SEC` (30s): accepted. Age is clamped at 0. Lag reads up to 30s high,
  which is why `LAG_MAX_SEC` (60) is set above `SKEW_TOL_SEC`. More than 30s ahead: `BADSIG ts_future`. This
  stops a captured message with a future timestamp from holding off `STALE`.
- Validator clock **behind**: age reads high (a 60s-behind clock reaches `STALE` 60s early), and lag reads low,
  clamped at 0.
- Ledger `close_time` is rounded to the network's close-time resolution (up to 10s). On this testnet, a healthy
  node shows 0-6s lag (see the logs).

## Threat model

| Threat | Mitigation |
|---|---|
| Validator host dies or loses network | that's what `STALE` is for. The check runs on another host |
| postfiatd down or stuck, host up | heartbeat still sent with `server_state rpc_down` -> `LAGGING`. A stuck ledger -> `LAGGING` via close time |
| Someone forges heartbeats to hide an outage | HMAC-SHA256 over the exact JSON line with a 32-byte shared key. A forged message is `BADSIG` **and** never refreshes the last good heartbeat, so a forger can't hold off `STALE` either |
| Replay of a captured valid heartbeat | `ts` must strictly increase (`replay`), and can be at most 30s ahead (`ts_future`) |
| Theft of the heartbeat SSH key | it only reaches `pftwd`, whose `authorized_keys` line is `restrict,command="pft-watchdog receive"`: no shell, PTY or forwarding. Messages are capped at 4 KiB, with at most 200 waiting files. `pftwd` has a locked password and never reads the HMAC key (root `0600`), so the key alone can't produce a valid heartbeat |
| Signature oracle / timing | `receive` answers nothing about validity, and verification runs later in a separate root process |
| Secrets leaking through `ps` / env / logs | the HMAC is computed with bash builtins (`printf %b`) piped into `sha256sum`, so the key never appears in argv or env. ntfy topic/token go through `curl -K` on an fd. Heartbeats contain only public node status |
| MITM of the SSH transport | the watchdog host key is pinned in `/etc/pft-watchdog/known_hosts` with `StrictHostKeyChecking=yes` |
| Watchdog host itself dies | not covered. Nobody watches the watchdog. Pair it with an external uptime check, or run the [integrity](../integrity/README.md) and [monitor](../README.md#monitoring-add-on-ntfy-alerts) add-ons on it |

Limits: the HMAC compare is a plain string compare (no oracle, see above). The key is shared, not asymmetric, so
anyone with root on the watchdog host can forge heartbeats, and that person could also simply disable the watchdog.
The heartbeat is one-way, so the validator doesn't learn that the watchdog is down. The public-RPC lag check trusts
`rpc.testnet.postfiat.org`.

## Tests and drill

- `./test-watchdog.sh`: 20 cases, 33 assertions, unprivileged, in a temp dir. Messages are signed with
  `openssl dgst -hmac` (an independent HMAC implementation) and the bash HMAC is checked against RFC 4231 test case 2.
  Covers OK, STALE (+dedupe), RECOVERED, a forged-HMAC negative control (also checks that the forged ledger isn't used),
  replay with a suppressed paired recovery, `ts_future` vs inside-tolerance, malformed/oversize, **public RPC down via
  `https_proxy=http://127.0.0.1:9` -> lag unknown, not LAGGING**, the same heartbeat with the RPC back -> LAGGING,
  LAGGING -> BADSIG -> RECOVERED, `rpc_down` heartbeat, cooldown suppression, a key-permission refusal, and exit codes.
  It uses the real public RPC and, for case 3, the real `pft-heartbeat --print` against the local node.
- `./drill.sh <drill-ntfy.env>`: on the live pair, points the watchdog at a throwaway ntfy topic, stops
  `pft-heartbeat.timer` -> `STALE`, starts it -> `RECOVERED`, sends one heartbeat signed with a random wrong key ->
  `BADSIG` -> `RECOVERED`, fetches the test topic's messages as JSON, checks that exactly STALE, RECOVERED, BADSIG,
  RECOVERED were sent, and restores the previous ntfy target. It doesn't touch postfiatd.

Raw logs: [`../logs/watchdog/`](../logs/watchdog/).
