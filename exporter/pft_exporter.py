#!/usr/bin/env python3
"""Prometheus exporter for a local Post Fiat node (polls server_info on admin RPC)."""
import json
import os
import re
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

RPC_URL = os.environ.get("PFT_RPC_URL", "http://127.0.0.1:5005")
LISTEN_ADDR = os.environ.get("PFT_EXPORTER_ADDR", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("PFT_EXPORTER_PORT", "9877"))
DISK_PATH = os.environ.get("PFT_DISK_PATH", "/")
STATES = ["disconnected", "connected", "syncing", "tracking", "full", "validating", "proposing"]


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def fetch_info():
    body = json.dumps({"method": "server_info", "params": [{}]}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)["result"]["info"]


def disk_lines():
    try:
        st = os.statvfs(DISK_PATH)
    except OSError:
        return []
    return ["# HELP pft_disk_size_bytes Size of the filesystem holding PFT_DISK_PATH",
            "# TYPE pft_disk_size_bytes gauge", "pft_disk_size_bytes %d" % (st.f_blocks * st.f_frsize),
            "# HELP pft_disk_avail_bytes Bytes available to unprivileged users on that filesystem",
            "# TYPE pft_disk_avail_bytes gauge", "pft_disk_avail_bytes %d" % (st.f_bavail * st.f_frsize)]


def render():
    out = disk_lines()
    try:
        info = fetch_info()
    except Exception:
        out += ["# HELP pft_up 1 if server_info was fetched", "# TYPE pft_up gauge", "pft_up 0"]
        return "\n".join(out) + "\n"
    state = info.get("server_state", "unknown")
    out += ["# HELP pft_up 1 if server_info was fetched", "# TYPE pft_up gauge", "pft_up 1",
            "# HELP pft_server_state Numeric server_state (index in disconnected..proposing, -1 unknown)",
            "# TYPE pft_server_state gauge",
            'pft_server_state{state="%s"} %d' % (esc(state), STATES.index(state) if state in STATES else -1),
            "# HELP pft_peers Connected peers", "# TYPE pft_peers gauge",
            "pft_peers %d" % int(info.get("peers", 0))]
    ranges = re.findall(r"(\d+)(?:-(\d+))?", info.get("complete_ledgers", ""))
    out += ["# HELP pft_complete_ledgers_ranges Number of comma-separated ranges in complete_ledgers "
            "(1 = contiguous, >1 = gaps, 0 = empty)",
            "# TYPE pft_complete_ledgers_ranges gauge", "pft_complete_ledgers_ranges %d" % len(ranges)]
    if ranges:
        lo = int(ranges[0][0])
        hi = int(ranges[-1][1] or ranges[-1][0])
        held = sum(int(b or a) - int(a) + 1 for a, b in ranges)
        out += ["# TYPE pft_complete_ledgers_lowest gauge", "pft_complete_ledgers_lowest %d" % lo,
                "# TYPE pft_complete_ledgers_highest gauge", "pft_complete_ledgers_highest %d" % hi,
                "# TYPE pft_complete_ledgers_span gauge", "pft_complete_ledgers_span %d" % (hi - lo + 1),
                "# HELP pft_complete_ledgers_missing Ledgers missing between lowest and highest",
                "# TYPE pft_complete_ledgers_missing gauge",
                "pft_complete_ledgers_missing %d" % (hi - lo + 1 - held)]
    lc = info.get("last_close") or {}
    out += ["# HELP pft_load_factor server_info load_factor (1 = unloaded)", "# TYPE pft_load_factor gauge",
            "pft_load_factor %s" % float(info.get("load_factor", 1)),
            "# HELP pft_close_time_offset_seconds server_info close_time_offset (0 when absent)",
            "# TYPE pft_close_time_offset_seconds gauge",
            "pft_close_time_offset_seconds %s" % float(info.get("close_time_offset", 0)),
            "# HELP pft_last_close_converge_seconds Consensus converge time of the last close",
            "# TYPE pft_last_close_converge_seconds gauge",
            "pft_last_close_converge_seconds %s" % float(lc.get("converge_time_s", 0)),
            "# HELP pft_uptime_seconds postfiatd process uptime (resets on restart)",
            "# TYPE pft_uptime_seconds gauge", "pft_uptime_seconds %d" % int(info.get("uptime", 0)),
            "# HELP pft_validator_configured 1 if a validator key is loaded (pubkey_validator set)",
            "# TYPE pft_validator_configured gauge",
            "pft_validator_configured %d" % (info.get("pubkey_validator", "none") not in ("", "none"))]
    vl = info.get("validated_ledger")
    if vl:
        out += ["# HELP pft_validated_ledger_age_seconds Age of newest validated ledger",
                "# TYPE pft_validated_ledger_age_seconds gauge",
                "pft_validated_ledger_age_seconds %s" % vl.get("age", 0),
                "# TYPE pft_validated_ledger_seq gauge", "pft_validated_ledger_seq %s" % vl.get("seq", 0)]
    out += ["# HELP pft_build_info Build version (info metric)", "# TYPE pft_build_info gauge",
            'pft_build_info{version="%s"} 1' % esc(info.get("build_version", "unknown"))]
    return "\n".join(out) + "\n"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        data = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    HTTPServer((LISTEN_ADDR, LISTEN_PORT), H).serve_forever()
