# Validator upgrade script

`postfiat-upgrade.sh` pulls `agtipft/postfiatd:<network>-light-latest` (the rolling tag from Post Fiat's
official validator guide, not a pinned digest), restarts the container, and logs:

- image id / repo digest before and after
- `build_version` before and after (local admin RPC)
- `build_version` comparison with the foundation RPC (`rpc.testnet.postfiat.org`) - fails on mismatch
- the post-restart `postfiat-health` result

Run: `sudo ./upgrade/postfiat-upgrade.sh` (needs docker, curl, jq; main `install.sh` first).
Env overrides: `COMPOSE_DIR`, `NETWORK`, `FOUNDATION_RPC`, `LOCAL_RPC`, `HEALTH_CMD`, `WAIT_SECS`.

## Test log

`logs/upgrade/upgrade-run-1.log` - real run on Ubuntu 22.04.5. No newer image was published at that
time, so digest and build_version (1.0.9) were unchanged before/after; the pull, restart, foundation
match and health check all executed and passed. The script does not claim a version change when there is none.
