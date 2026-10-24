# sysctl/ — kernel and network-stack hardening (`pft-sysctl.sh`)

`pft-sysctl.sh` checks, applies and rolls back a small sysctl hardening profile for Post Fiat
validator and sentry hosts running `postfiatd` in Docker. It does not overlap with `audit/`
(SSH, firewall, ports, container settings): it only covers `/proc/sys` keys and the
`sysctl.d` files that persist them.

| File | Purpose |
|---|---|
| `pft-sysctl.sh` | `check` (read-only, default), `apply`, `rollback`, `profile` |
| `test-sandbox.sh` | apply/rollback/negative controls inside a throwaway network namespace + fake `/proc/sys` |

## Modes

```
sudo ./pft-sysctl.sh check [--json]        # exit 0 PASS / 1 WARN / 2 FAIL
sudo ./pft-sysctl.sh apply --dry-run       # print the diff only
sudo ./pft-sysctl.sh apply                 # diff, backup, write conf, sysctl --system, re-check
sudo ./pft-sysctl.sh rollback [--from F]   # restore exact prior values, remove the conf
./pft-sysctl.sh profile                    # key, rule, value written, rationale
```

`check` reads two values for every key:

- **runtime**: the value in `/proc/sys` now.
- **persisted**: the last assignment to that key in `sysctl --system` order. That order is all
  `*.conf` files from `/etc/sysctl.d`, `/run/sysctl.d`, `/usr/local/lib/sysctl.d`,
  `/usr/lib/sysctl.d` and `/lib/sysctl.d`, sorted by basename (if two files share a name, the one
  in the earlier directory wins), then `/etc/sysctl.conf` last. Glob keys such as
  `net.ipv4.conf.*.rp_filter` count as matches. The `SOURCE` column names the file that wins.
  Two Ubuntu boot steps that run after `systemd-sysctl` count as later sources (see
  [Boot-time overrides](#boot-time-overrides-ufw-and-apport)): ufw's `IPT_SYSCTL` file and apport.

| State | Meaning |
|---|---|
| FAIL | the runtime value misses the profile, or a Docker guard is broken |
| WARN | the runtime value is fine but no file persists it (it falls back to the kernel default at reboot), or a later file overrides it with a weaker value |
| PASS | runtime and persisted values both meet the profile |
| INFO / SKIP | reported only (bridge-nf keys), or the key does not exist on this kernel (never written) |

`apply` takes these steps in order:

1. Refuses to run if `net.ipv4.ip_forward` is not 1.
2. Prints every runtime value that will change (`key: current -> target`) and a `diff -u` of
   `/etc/sysctl.d/90-postfiat-hardening.conf`.
3. Saves the current runtime value of every profile key, plus the previous conf file if one
   exists, to `/var/backups/pft-sysctl/sysctl-<UTC>.tsv` (directory 0700, files 0600).
4. Writes the conf file (0644) and runs `sysctl --system`.
5. Fixes the boot-time overrides: edits the offending lines of the ufw `IPT_SYSCTL` file to the
   profile value and sets `enabled=0` in `/etc/default/apport`. Both files are backed up first
   (listed in `sysctl-<UTC>.tsv.files`) and edited in place, so owner and mode stay the same.
   `--dry-run` shows a `diff -u` of each file.
6. Checks `ip_forward` again and sets it back to 1 if any file reset it, then exits FAIL.
7. Runs `check`.

If the profile is already applied (no runtime change, identical conf, no boot overrides), `apply` writes nothing
and takes no backup. Otherwise a re-apply would back up the hardened values, and `rollback`
would then restore nothing.

`rollback` writes back every value from the backup that differs from the current value. Then it
removes the conf file, or puts back the previous copy, and restores the ufw and apport files
byte-for-byte (with their mtime). It does **not** run `sysctl --system`,
because that would re-apply the distro values instead of the exact values that were live before
`apply`.

## Profile and rationale

| Key | Rule | Written | Why |
|---|---|---|---|
| `net.ipv4.conf.{all,default}.rp_filter` | = 2 | 2 | Reverse-path filter in **loose** mode. Strict mode (1) drops legitimate asymmetric replies on multi-homed and Docker hosts. Ubuntu already ships 2. |
| `net.ipv4.tcp_syncookies` | = 1 | 1 | Keeps the public peer port 2559 answering during a SYN flood. |
| `net.ipv4.conf.{all,default}.accept_redirects`, `secure_redirects`; `net.ipv6.conf.{all,default}.accept_redirects` | = 0 | 0 | ICMP redirects let anyone on the path rewrite the host's routes. A server with a static default route never needs them. |
| `net.ipv4.conf.{all,default}.send_redirects` | = 0 | 0 | The host is not a router for its LAN. Docker's bridge forwarding does not use redirects. |
| `net.ipv{4,6}.conf.{all,default}.accept_source_route` | = 0 | 0 | Source-routed packets bypass routing policy. |
| `net.ipv4.conf.{all,default}.log_martians` | = 1 | 1 | Logs packets with impossible source addresses (spoofing evidence). The kernel rate-limits these messages. |
| `net.ipv4.icmp_echo_ignore_broadcasts` | = 1 | 1 | No smurf amplification. |
| `net.ipv4.icmp_ignore_bogus_error_responses` | = 1 | 1 | Keeps bogus ICMP errors out of the kernel log. |
| `kernel.kptr_restrict` | = 2 | 2 | Hides kernel pointers in `/proc` from every user, which removes KASLR leaks. The cost: `perf` cannot resolve kernel symbols. |
| `kernel.dmesg_restrict` | = 1 | 1 | Kernel log readable only with CAP_SYSLOG. |
| `kernel.unprivileged_bpf_disabled` | ≥ 1 | 2 | No unprivileged eBPF (a recurring local-privilege-escalation surface). Writes **2** because 1 cannot be undone until reboot. An existing 1 is kept, because it cannot be lowered. |
| `kernel.yama.ptrace_scope` | ≥ 1 | 1 | Processes may only ptrace their own descendants, so one compromised user process cannot read another's memory. Never writes 3, which is irreversible. |
| `fs.protected_hardlinks`, `fs.protected_symlinks` | = 1 | 1 | Blocks link attacks in world-writable sticky directories. |
| `fs.protected_fifos` | ≥ 1 | 1 | Same protection for FIFOs (O_CREAT in sticky directories). |
| `fs.protected_regular` | ≥ 1 | 2 | Same protection for regular files. |
| `fs.suid_dumpable` | = 0 | 0 | No core dumps of setuid or credential-changing processes, which could hold key material. |

For `≥` rules, a stricter current value is kept and written as-is.

### Docker and peering compatibility

- **`net.ipv4.ip_forward` is a guard, never written.** Docker sets it to 1 at start, and the
  published peer port and container egress depend on it. `check` reports FAIL if it is 0 at
  runtime, or if any `sysctl.d` file would set it to 0 at the next `sysctl --system` or boot.
  `apply` refuses to run in either case.
- **`net.bridge.bridge-nf-call-*` are never touched.** Docker and `br_netfilter` own them, and
  `check` only reports their current value.
- **Conntrack is sized, not written.** Every forwarded container connection uses a conntrack
  entry. `check` compares `nf_conntrack_count` with `nf_conntrack_max`, reports WARN at 75% or
  more, and recommends a maximum of at least 4 × the current count (minimum 262144, rounded up to
  a power of two). This is a point-in-time reading, so take it at peak load.
- Peering is expected to keep working, because no profile key changes how TCP sessions on 2559
  or the sentry↔validator link are handled. The live run checks `server_state`, peer count and
  the sentry link before and after rather than taking this on trust.

### Ordering caveat

The file is named `90-…`, so any `99-*.conf` file loads after it and wins. On stock Ubuntu
22.04, `99-protect-links.conf` sets the same `fs.protected_*` values, so there is no conflict.
`check` names the winning file for every key, and shows WARN when a later file weakens a key.

### Boot-time overrides: ufw and apport

The first live reboot of the sentry (run 1) showed that `sysctl.d` is not the last word on
Ubuntu 22.04. Three keys that were PASS before the reboot came back weak:

| Key | After reboot | Set by |
|---|---|---|
| `net.ipv4.conf.{all,default}.log_martians` | 0 | ufw. At start it runs `sysctl -p` on `IPT_SYSCTL` (`/etc/default/ufw`, default `/etc/ufw/sysctl.conf`), which ships `log_martians=0`. ufw starts after `systemd-sysctl`. |
| `fs.suid_dumpable` | 2 | apport. Its init script runs `echo 2 > /proc/sys/fs/suid_dumpable` when `enabled=1` in `/etc/default/apport` (the default). |

The boot order is `systemd-sysctl` → ufw → apport. `check` therefore treats the ufw file (only
when `ENABLED=yes` in `/etc/ufw/ufw.conf`) and apport (only when its init script writes
`suid_dumpable` and `enabled` is not 0) as sources after every `sysctl.d` file, and reports
WARN with the reason. `apply` fixes both at the source:

- **ufw:** only the profile keys that the ufw file sets to a weaker value are rewritten. Every
  other line (for example `ip_forward`, which is commented out on Ubuntu) is left alone.
- **apport:** `enabled=0` stops the init script from setting `suid_dumpable=2` (and from
  installing its `core_pattern` pipe) at the next boot. The running service is not stopped,
  because the profile already set `suid_dumpable=0` at runtime. You lose apport crash reports,
  which a headless node does not upload anyway. To keep apport, set `KEEP_APPORT=1`. `check`
  will then keep showing WARN for `fs.suid_dumpable`, because a reboot really does reset it.

## Sandbox test

`sudo ./test-sandbox.sh` re-runs itself under `unshare --net`, so every `net.*` write goes to a
throwaway network namespace. The `kernel.*` and `fs.*` keys are global, so the test copies their
current host values into a fake `PROC_SYS` tree. Host `sysctl.d` files are copied too, and
`SYSCTL_SYSTEM` is the script's internal `_load`, which uses the same file order. Before
starting, the test emulates an Ubuntu boot (`boot()`): `_load`, then ufw's `IPT_SYSCTL`
file, then apport's `suid_dumpable=2`. It uses copies of the host's ufw and apport files (ufw
forced enabled, apport `enabled=1`). The host's own `90-postfiat-hardening.conf` is not copied,
so the sandbox starts from the pre-apply state.

The test then covers these cases:

1. Docker-guard negative control: with `ip_forward=0`, `check` reports FAIL and `apply` refuses
   without writing anything.
2. Checking before apply reports FAIL, and the `--json` output has the expected shape.
3. `apply --dry-run` writes nothing and changes nothing.
4. `apply` brings every key to PASS, and `ip_forward` stays 1.
5. A second `apply` is a no-op.
   - 5b. The ufw `log_martians` lines now read 1 and apport `enabled=0`. After an emulated
     reboot, `check` is still all PASS.
   - 5c. Negative control: the ufw file sets `log_martians=0` again. `check` reports WARN, and
     after an emulated reboot it reports FAIL.
   - 5d. Negative control: apport is re-enabled, and `check` reports WARN.
6. Negative control: a deliberately wrong runtime value (`kptr_restrict=0`) is reported as FAIL.
7. Negative control: a later `99-zz-override.conf` that weakens a key is reported as WARN.
8. Negative control: a `sysctl.d` file that sets `ip_forward=0` is reported as FAIL.
9. `rollback` restores state that is byte-identical (`cmp`) to the pre-apply snapshot, which
   covers every profile key plus all of `net/ipv4/conf` and `net/ipv6/conf`, and the sha256,
   mode and size of the ufw sysctl file and `/etc/default/apport`. The conf file is
   removed, and `check` returns the pre-apply result again.

Limit: the sandbox replaces procps `sysctl --system` with `_load`, and replaces the real ufw
and apport start with `boot()`. The live run on both hosts uses the real `sysctl --system`, and
the sentry reboot uses the real boot.

Logs: `logs/sysctl/1-4` are the first runs (before the boot-override fix). Run 5 had 3
failures, all caused by the test copying the host's own `90-postfiat-hardening.conf`, which an
earlier live apply had left there. The fix was to skip that file. Run 6 passes 26/26.

## Live two-host proof

`live-proof.sh [ttl]` runs on the validator (sentry reached as `ssh relay`). It runs inside a
`pft-maint` window with an Alertmanager silence (`alertname=~.+`, ttl + 10 min). Every ntfy
target that can fire (validator: pft-maint and postfiat-monitor; sentry: pft-watchdog) points
at a throwaway topic until the end. Steps: health before → per host `check`, `apply --dry-run`,
`apply`, `check`, health → integrity re-accept (only items whose name contains `sysctl`; anything
else is left for a human) → sentry `systemctl reboot` → `check` on the new boot → wait until
full and re-peered → end window, read back the topic (expect exactly `[MAINT] start` +
`[MAINT] end`), restore the targets (sha256 compared), expire the silence.
`PRE_ROLLBACK=1` first rolls back every backup on both hosts (newest first, so the oldest one
restores the true pre-hardening values), which makes the proof repeatable on hosts that are
already hardened.

Health = both nodes `full`, peer count within ±2 of before, validator has the sentry as a peer,
both containers reach the public RPC, all Prometheus targets up.

Found → fixed → verified (all fixed on both hosts before publishing):

| Run | Found | Fix |
|---|---|---|
| 1 (`logs/sysctl/7`) | after the sentry reboot `check` FAIL 3: ufw reset `log_martians=0`, apport reset `suid_dumpable=2` | boot-override handling (section above), applied live on both hosts (`10`, `11`) |
| 1 (`7`, `8`) | sentry not re-peered 30 min after the reboot; admin `connect` did nothing | both nodes sat at their outbound peer limit; the sentry is now an `[ips_fixed]` peer of the validator (`sentry/validator-setup.sh fixed`, `logs/sentry/5-fixed-peer-proof.log`) |
| 1 (`9`) | sentry `DOCKER-USER` chain empty after the reboot (2559 rate limits not persisted) | `postfiat-docker-user` unit; `13` shows the 5 rules back after the run-2 reboot |

Run 2 (`logs/sysctl/12`, 2026-10-24 01:08-01:13Z, `PRE_ROLLBACK=1`): before = FAIL 8 on both
hosts → apply → 30/30 PASS on both, health PASS (peers 11/11) → sentry reboot (boot_id
changed) → `check` 30/30 PASS on the new boot, health PASS → topic PASS, env files identical,
silence expired. The script's verdict line is still **FAIL**. The only reason is that its
post-reboot integrity step refused to accept `sshd:sshd_config changed mtime` on the sentry,
because the name does not contain `sysctl`. The guard is meant to refuse. `13` shows the
content sha256 is unchanged against the baseline, and that cloud-init's init stage touched the
file during the reboot (run 1 saw the same thing). After that check it was accepted by hand.

## Rollback procedure

```
sudo ./pft-sysctl.sh rollback                       # latest backup
sudo ls /var/backups/pft-sysctl/                    # or pick one
sudo ./pft-sysctl.sh rollback --from /var/backups/pft-sysctl/sysctl-<UTC>.tsv
sudo ./pft-sysctl.sh check
```

If the host does not come back after a reboot, boot into recovery, delete
`/etc/sysctl.d/90-postfiat-hardening.conf`, copy the `sysctl-<UTC>.tsv.f*` backups listed in
`sysctl-<UTC>.tsv.files` back to their paths, and reboot. Every key then falls back to the distro
or kernel default.

## Limits

- The profile is static. Keys that a given kernel lacks are reported SKIP, never written.
- `persisted` follows the procps `sysctl --system` order. At boot, `systemd-sysctl` reads the
  same directories (`/etc/sysctl.conf` arrives through the `99-sysctl.conf` symlink), so the
  winning file is the same on a stock system.
- Per-interface keys (`net.ipv4.conf.eth0.*`) are not managed. The kernel combines `all` with
  the per-interface value, and the rule differs per key (see the kernel's `ip-sysctl` docs).
  `default` only applies to interfaces created later, such as new Docker veths.
