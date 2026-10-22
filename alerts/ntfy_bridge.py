#!/usr/bin/env python3
"""Alertmanager webhook -> ntfy bridge (stdlib only, listens on 127.0.0.1).

Logs one line per alert in every webhook (status, alertname, severity, startsAt, endsAt).
If NTFY_URL (e.g. https://ntfy.sh/<topic>) is set (directly or via a file named by NTFY_URL_FILE), also posts each alert to ntfy:
critical -> priority high, resolved -> priority low. NTFY_URL is never logged.
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

ADDR = os.environ.get("BRIDGE_ADDR", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "9095"))


def ntfy_url():
    """NTFY_URL from the file named by NTFY_URL_FILE (a mounted NTFY_URL=... file), else the environment.

    The file keeps the topic out of `docker inspect` output.
    """
    path = os.environ.get("NTFY_URL_FILE", "")
    if path:
        with open(path) as f:
            for line in f:
                if line.startswith("NTFY_URL="):
                    return line.split("=", 1)[1].strip()
        return ""
    return os.environ.get("NTFY_URL", "")


NTFY_URL = ntfy_url()


def log(msg):
    print(msg, flush=True)


def ntfy(alert, status):
    sev = alert.get("labels", {}).get("severity", "warning")
    name = alert.get("labels", {}).get("alertname", "?")
    prio = "low" if status == "resolved" else ("high" if sev == "critical" else "default")
    body = alert.get("annotations", {}).get("summary", name).encode()
    req = urllib.request.Request(NTFY_URL, data=body, headers={
        "Title": "[%s] %s" % (status.upper(), name), "Priority": prio, "Tags": "rotating_light"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            log("ntfy %s %s -> HTTP %d" % (status, name, r.status))
    except Exception as e:  # never crash the webhook on delivery errors
        log("ntfy %s %s -> ERROR %s" % (status, name, type(e).__name__))


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(n))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        for a in payload.get("alerts", []):
            st = a.get("status", "?")
            lb = a.get("labels", {})
            log("webhook status=%s alertname=%s severity=%s startsAt=%s endsAt=%s" % (
                st, lb.get("alertname"), lb.get("severity"), a.get("startsAt"), a.get("endsAt")))
            if NTFY_URL:
                ntfy(a, st)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    log("bridge listening on %s:%d ntfy=%s" % (ADDR, PORT, "on" if NTFY_URL else "off"))
    sys.stdout.flush()
    HTTPServer((ADDR, PORT), H).serve_forever()
