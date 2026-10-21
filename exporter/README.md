# Post Fiat Prometheus exporter

Polls `server_info` on the local admin RPC (`127.0.0.1:5005`) and serves `/metrics` on `127.0.0.1:9877` (localhost by default).

Metrics: `pft_up`, `pft_server_state{state}` (0 disconnected … 6 proposing), `pft_peers`,
`pft_complete_ledgers_{lowest,highest,span}`, `pft_validated_ledger_age_seconds`, `pft_validated_ledger_seq`, `pft_build_info{version}`.

Install (systemd): copy `pft_exporter.py` to `/opt/pft-exporter/`, copy `pft-exporter.service` to `/etc/systemd/system/`, then `systemctl enable --now pft-exporter`.
Docker: `docker build -t pft-exporter . && docker run --network host pft-exporter` (host network so it reaches the localhost-only admin RPC; still binds 127.0.0.1).
Env: `PFT_RPC_URL`, `PFT_EXPORTER_ADDR` (default 127.0.0.1), `PFT_EXPORTER_PORT` (default 9877). Import `grafana-dashboard.json` into Grafana.
