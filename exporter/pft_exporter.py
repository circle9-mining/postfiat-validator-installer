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
STATES = ["disconnected", "connected", "syncing", "tracking", "full", "validating", "proposing"]


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def fetch_info():
    body = json.dumps({"method": "server_info", "params": [{}]}).encode()
    req = urllib.request.Request(RPC_URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)["result"]["info"]


def render():
    out = []
    try:
        info = fetch_info()
    except Exception:
        return "# HELP pft_up 1 if server_info was fetched\n# TYPE pft_up gauge\npft_up 0\n"
    state = info.get("server_state", "unknown")
    out += ["# HELP pft_up 1 if server_info was fetched", "# TYPE pft_up gauge", "pft_up 1",
            "# HELP pft_server_state Numeric server_state (index in disconnected..proposing, -1 unknown)",
            "# TYPE pft_server_state gauge",
            'pft_server_state{state="%s"} %d' % (esc(state), STATES.index(state) if state in STATES else -1),
            "# HELP pft_peers Connected peers", "# TYPE pft_peers gauge",
            "pft_peers %d" % int(info.get("peers", 0))]
    m = re.match(r"^(\d+)-(\d+)", info.get("complete_ledgers", ""))
    if m:
        lo, hi = int(m.group(1)), int(m.group(2))
        out += ["# TYPE pft_complete_ledgers_lowest gauge", "pft_complete_ledgers_lowest %d" % lo,
                "# TYPE pft_complete_ledgers_highest gauge", "pft_complete_ledgers_highest %d" % hi,
                "# TYPE pft_complete_ledgers_span gauge", "pft_complete_ledgers_span %d" % (hi - lo + 1)]
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
