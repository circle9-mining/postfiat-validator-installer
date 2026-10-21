# Post Fiat Prometheus exporter

Polls `server_info` on the local admin RPC (`127.0.0.1:5005`) and serves `/metrics` on `127.0.0.1:9877` (localhost by default).

Metrics: `pft_up`, `pft_server_state{state}` (0 disconnected … 6 proposing), `pft_peers`,
`pft_complete_ledgers_{lowest,highest,span,missing,ranges}`, `pft_validated_ledger_age_seconds`, `pft_validated_ledger_seq`,
`pft_load_factor`, `pft_close_time_offset_seconds`, `pft_last_close_converge_seconds`, `pft_uptime_seconds`, `pft_validator_configured`
(uptime drops on every postfiatd/container restart), `pft_disk_{size,avail}_bytes` (filesystem of `PFT_DISK_PATH`), `pft_build_info{version}`.
`pft_complete_ledgers_ranges` > 1 means `complete_ledgers` has gaps (e.g. `100-200,250-300`); `highest` is taken from the last range.
Alert rules for these metrics live in [`../alerts/`](../alerts/).

Install (systemd): copy `pft_exporter.py` to `/opt/pft-exporter/`, copy `pft-exporter.service` to `/etc/systemd/system/`, then `systemctl enable --now pft-exporter`.
Docker: `docker build -t pft-exporter . && docker run --network host pft-exporter` (host network so it reaches the localhost-only admin RPC; still binds 127.0.0.1).
Env: `PFT_RPC_URL`, `PFT_EXPORTER_ADDR` (default 127.0.0.1), `PFT_EXPORTER_PORT` (default 9877), `PFT_DISK_PATH` (default `/`; must be readable by the service user — under `DynamicUser=yes` `/var/lib/docker` is not, so use a mount point on the same filesystem as the Docker volumes). Import `grafana-dashboard.json` into Grafana.
