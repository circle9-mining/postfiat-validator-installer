#!/usr/bin/env python3
"""Read-only analyzer for postfiatd debug.log files.

Reads /opt/postfiatd/logs/debug.log plus its rotations (plain and .gz), never
writes to them, and reports:
  - per-severity and per-partition counts, top noisy partitions
  - operator-relevant events (see DETECTORS and README.md)
  - restarts (startup/shutdown pairs, unclean starts)
  - a per-hour WRN / ERR+FTL timeline

All text and JSON output is sanitized: IPv4/IPv6 addresses, ports and node
public keys are replaced with short salted SHA-256 labels (ip-xxxxxxxx,
port-xxxx, key-xxxxxxxx). The salt is random per run unless --salt is given.

Exit codes: 0 OK, 1 WARN (attention events), 2 CRIT (ERR/FTL lines,
amendment blocked, NodeStore errors outside the startup grace period) or the
input could not be read, 64 usage error.
"""
import argparse
import collections
import datetime as dt
import glob
import gzip
import hashlib
import ipaddress
import json
import os
import re
import secrets
import sys
import time

EXIT_OK, EXIT_WARN, EXIT_CRIT, EXIT_USAGE = 0, 1, 2, 64
LEVELS = {"INFO": 0, "WARN": 1, "CRIT": 2}
SEVERITIES = ("TRC", "DBG", "NFO", "WRN", "ERR", "FTL")
DEFAULTS = {
    "slow_ms": 1000,          # LoadMonitor NFO job counts as slow when run or wait >= this
    "startup_grace": 600,     # seconds after "Process starting" where Missing node is WARN, not CRIT
    "top": 10,                # top-N partitions shown
    "max_examples": 5,        # sanitized example messages kept per detector
}
MONTHS = {m: i for i, m in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1)}

# 2026-Oct-21 20:20:59.819232198 UTC Application:NFO Process starting: ...
# Partitions may contain a space ("gRPC Server:NFO").
HEADER_RE = re.compile(
    r"^(\d{4})-([A-Z][a-z]{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})(?:\.(\d+))? UTC "
    r"(.+?):(TRC|DBG|NFO|WRN|ERR|FTL) (.*)$")

# Detectors: (name, level, partitions or None for any, minimum severity, regex, operator response).
# Level may be refined in classify() (state changes, startup grace, slow NFO jobs).
DETECTORS = [
    ("startup", "INFO", {"Application"}, "NFO",
     r"^Process starting: (?P<version>[^\s,]+)",
     "Expected after upgrades/reboots; unexpected ones mean a crash loop or OOM kill."),
    ("shutdown", "INFO", {"Application"}, "NFO",
     r"^Server stopping(?:: (?P<reason>.*))?",
     "Expected for planned restarts; otherwise check who/what sent the signal."),
    ("state_change", "INFO", {"NetworkOPs"}, "TRC",
     r"STATE->(?P<state>\w+)",
     "full is healthy; disconnected/connected/syncing after startup means lost sync."),
    ("lost_sync", "WARN", {"NetworkOPs", "LedgerConsensus", "LedgerMaster"}, "WRN",
     r"We are not running on the consensus ledger|Need consensus ledger|"
     r"Node count \(\d+\) has fallen below required minimum|fell behind|out of sync",
     "INFO within the startup grace; otherwise check peers (peers/), disk latency and clock."),
    ("ledger_jump", "WARN", {"LedgerConsensus", "LedgerMaster"}, "NFO",
     r"^View of consensus changed during \w+ mode=switchedLedger|^[Ll]edger jump|^[Jj]umping to ledger",
     "Node had to switch to the network's ledger; INFO within the startup grace, WARN otherwise."),
    ("amendment_blocked", "CRIT", None, "NFO",
     r"(?i)amendment.?blocked|unsupported amendment|has been enabled.*not supported",
     "Upgrade postfiatd now (upgrade/); an amendment-blocked node cannot follow the network."),
    ("peer_connect", "INFO", {"Peer"}, "NFO",
     r"^\[\d+\] Public Key: ",
     "Informational: completed peer handshakes."),
    ("peer_disconnect", "INFO", {"Peer"}, "NFO",
     r"^\[\d+\] (?:Closed|onReadMessage .*|onWriteMessage .*|Unable to upgrade to peer protocol.*)$",
     "Informational unless peer count drops; then check firewall and peer port 2559."),
    ("peer_charge", "WARN", {"Peer", "Resource", "Overlay", "PeerFinder"}, "NFO",
     r"(?i)\bcharg(?:e|ing)\b|\bfee=",
     "A peer (or this node) is being charged for bad/expensive traffic; repeated charges precede drops."),
    ("resource_limit", "WARN", {"Peer", "Resource", "Overlay", "PeerFinder", "Server"}, "NFO",
     r"(?i)resource limit|over ?limit|balance.*exceed|dropping (?:peer|connection)|too many (?:connections|peers)|"
     r"slots? full",
     "Check peers_max / rate limits (UFW and DOCKER-USER) and whether a peer is misbehaving."),
    ("slow_job", "WARN", {"LoadMonitor"}, "NFO",
     r"^Job: (?P<job>.+?) run: (?P<run>\d+)ms wait: (?P<wait>\d+)ms",
     "CPU/disk saturation; check load, iowait and disk latency if frequent."),
    ("nodestore_error", "CRIT", {"NodeStore", "NodeFamily", "SHAMapStore", "SQLiteDatabaseImp", "Database",
                                 "NodeObject", "LedgerMaster", "Application"}, "NFO",
     r"(?i)missing node|write (?:error|fail)|no space left|disk full|database (?:is )?(?:locked|corrupt)|"
     r"i/o error|cannot open|failed to (?:write|store|open)",
     "Check free disk, filesystem errors and node_db; Missing node shortly after startup is normal."),
    ("clock_warning", "WARN", None, "WRN",
     r"(?i)\bclock\b|close.?time (?:offset|skew|drift)|time (?:skew|jump|offset)|"
     r"close time.*(?:behind|ahead)",
     "Check chrony/timesyncd (exporter clock metric); consensus needs an accurate clock."),
]
SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}
_COMPILED = [(n, lvl, parts, SEV_RANK[ms], re.compile(rx), resp) for n, lvl, parts, ms, rx, resp in DETECTORS]

# --- sanitization -------------------------------------------------------------------------
B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
NODEKEY_RE = re.compile(r"\bn[%s]{49,52}\b" % B58)
V6_BRACKET_RE = re.compile(r"\[([0-9A-Fa-f:.]+)\](?::(\d{1,5}))?")
V4_RE = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))?(?![\d.])")
V6_RE = re.compile(r"(?<![\w:.])([0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:\.\d{1,3}){0,3})(?![\w:])")
PORTWORD_RE = re.compile(r"(?i)\b(port[ =:]+)(\d{2,5})\b")


class Sanitizer:
    def __init__(self, salt):
        self.salt = salt

    def label(self, kind, value, n):
        return "%s-%s" % (kind, hashlib.sha256((self.salt + "|" + value).encode()).hexdigest()[:n])

    def _v6(self, m):
        cand = m.group(1)
        if cand.count(":") < 2:
            return m.group(0)
        try:
            ipaddress.IPv6Address(cand)
        except ValueError:
            return m.group(0)
        return self.label("ip", cand.lower(), 8)

    def _v6b(self, m):
        try:
            ipaddress.IPv6Address(m.group(1))
        except ValueError:
            return m.group(0)
        out = "[%s]" % self.label("ip", m.group(1).lower(), 8)
        if m.group(2):
            out += ":" + self.label("port", m.group(2), 4)
        return out

    def _v4(self, m):
        try:
            ipaddress.IPv4Address(m.group(1))
        except ValueError:
            return m.group(0)
        out = self.label("ip", m.group(1), 8)
        if m.group(2):
            out += ":" + self.label("port", m.group(2), 4)
        return out

    def __call__(self, text):
        if text is None:
            return None
        text = NODEKEY_RE.sub(lambda m: self.label("key", m.group(0), 8), text)
        text = V6_BRACKET_RE.sub(self._v6b, text)
        text = V4_RE.sub(self._v4, text)
        text = V6_RE.sub(self._v6, text)
        text = PORTWORD_RE.sub(lambda m: m.group(1) + self.label("port", m.group(2), 4), text)
        return text

    def deep(self, obj):
        if isinstance(obj, str):
            return self(obj)
        if isinstance(obj, list):
            return [self.deep(x) for x in obj]
        if isinstance(obj, dict):
            return {self(k): self.deep(v) for k, v in obj.items()}
        return obj


# --- input --------------------------------------------------------------------------------
def parse_when(s, now=None):
    """ISO-8601 UTC timestamp, YYYY-MM-DD, or a relative age like 24h / 90m / 7d / 3600s."""
    if s is None:
        return None
    now = now or dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    m = re.fullmatch(r"(\d+)([smhd])", s.strip())
    if m:
        mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        return now - dt.timedelta(seconds=int(m.group(1)) * mult)
    t = s.strip().replace("Z", "+00:00")
    try:
        v = dt.datetime.fromisoformat(t)
    except ValueError:
        raise ValueError("bad time %r (use ISO-8601 UTC like 2026-10-21T04:00:00Z or 24h/90m/7d)" % s)
    if v.tzinfo is not None:
        v = v.astimezone(dt.timezone.utc).replace(tzinfo=None)
    return v


def open_log(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return open(path, "rt", encoding="utf-8", errors="replace")


def first_ts(path):
    try:
        with open_log(path) as fh:
            for i, line in enumerate(fh):
                m = HEADER_RE.match(line)
                if m:
                    return to_dt(m)
                if i > 1000:
                    break
    except (OSError, EOFError):
        return None
    return None


def to_dt(m):
    frac = (m.group(7) or "0")[:6].ljust(6, "0")
    return dt.datetime(int(m.group(1)), MONTHS[m.group(2)], int(m.group(3)),
                       int(m.group(4)), int(m.group(5)), int(m.group(6)), int(frac))


def discover(log_dir):
    """debug.log and rotations (debug.log-*, debug.log.N, with or without .gz), oldest first."""
    paths = set(glob.glob(os.path.join(log_dir, "debug.log"))) | set(glob.glob(os.path.join(log_dir, "debug.log[-.]*")))
    paths = [p for p in paths if os.path.isfile(p) and not p.endswith((".status", ".tmp"))]
    keyed = []
    for p in paths:
        ts = first_ts(p)
        keyed.append((ts or dt.datetime.max, p == os.path.join(log_dir, "debug.log"), p))
    keyed.sort()
    return [p for _, _, p in keyed]


def iter_entries(paths, stats):
    """Yield (ts, partition, severity, message) for each header line; continuation lines are counted."""
    for p in paths:
        try:
            fh = open_log(p)
        except OSError as e:
            stats["errors"].append("%s: %s" % (os.path.basename(p), e.strerror))
            continue
        with fh:
            try:
                for line in fh:
                    stats["lines"] += 1
                    m = HEADER_RE.match(line)
                    if not m:
                        stats["continuation_lines"] += 1
                        continue
                    yield to_dt(m), m.group(8), m.group(9), m.group(10).rstrip("\n")
            except (OSError, EOFError) as e:
                stats["errors"].append("%s: %s" % (os.path.basename(p), e))


# --- analysis -----------------------------------------------------------------------------
def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000) if t else None


def classify(name, base_level, m, ctx, opts):
    """Return the effective level for a detector hit, or None to ignore it."""
    if name == "state_change":
        st = m.group("state")
        ctx["last_state"] = st
        if st == "full":
            return "INFO"
        since_start = (ctx["ts"] - ctx["last_start"]).total_seconds() if ctx["last_start"] else None
        if since_start is not None and since_start <= opts["startup_grace"]:
            return "INFO"
        return "WARN"
    if name in ("lost_sync", "ledger_jump"):
        # Expected while the node (re)joins the network right after a start.
        since_start = (ctx["ts"] - ctx["last_start"]).total_seconds() if ctx["last_start"] else None
        return "INFO" if since_start is not None and since_start <= opts["startup_grace"] else "WARN"
    if name == "slow_job":
        if ctx["sev"] == "NFO" and max(int(m.group("run")), int(m.group("wait"))) < opts["slow_ms"]:
            return None
        return "WARN"
    if name == "nodestore_error":
        since_start = (ctx["ts"] - ctx["last_start"]).total_seconds() if ctx["last_start"] else None
        if ("issing node" in ctx["msg"] and since_start is not None and since_start <= opts["startup_grace"]):
            return "WARN"
        return "CRIT" if SEV_RANK[ctx["sev"]] >= SEV_RANK["ERR"] else "WARN"
    return base_level


def analyze(paths, since=None, until=None, opts=None, sanitize=None):
    opts = dict(DEFAULTS, **(opts or {}))
    sanitize = sanitize or Sanitizer(secrets.token_hex(8))
    stats = {"lines": 0, "continuation_lines": 0, "errors": []}
    sev = collections.Counter()
    part = collections.Counter()
    part_wrn = collections.Counter()
    hourly = collections.defaultdict(lambda: {"WRN": 0, "ERR": 0})
    det = {n: {"count": 0, "levels": collections.Counter(), "first": None, "last": None, "examples": []}
           for n, *_ in DETECTORS}
    restarts, states = [], []
    ctx = {"last_start": None, "last_state": None, "ts": None, "sev": None, "msg": None}
    pending_stop = None
    first = last = None
    entries = 0
    by_part = collections.defaultdict(list)
    anyp = []
    for d in _COMPILED:
        if d[2] is None:
            anyp.append(d)
        else:
            for p in d[2]:
                by_part[p].append(d)
    for ts, p, s, msg in iter_entries(paths, stats):
        if since and ts < since:
            continue
        if until and ts > until:
            continue
        entries += 1
        first = first or ts
        last = ts
        sev[s] += 1
        part[p] += 1
        r = SEV_RANK[s]
        if r >= 3:
            part_wrn[p] += 1
            hourly[ts.strftime("%Y-%m-%dT%H:00Z")]["WRN" if s == "WRN" else "ERR"] += 1
        ctx.update(ts=ts, sev=s, msg=msg)
        for name, lvl, _parts, minsev, rx, _resp in by_part.get(p, []) + anyp:
            if r < minsev:
                continue
            m = rx.search(msg)
            if not m:
                continue
            level = classify(name, lvl, m, ctx, opts)
            if level is None:
                continue
            d = det[name]
            d["count"] += 1
            d["levels"][level] += 1
            d["first"] = d["first"] or ts
            d["last"] = ts
            if len(d["examples"]) < opts["max_examples"]:
                d["examples"].append({"ts": iso(ts), "level": level, "msg": sanitize(msg[:240])})
            if name == "startup":
                restarts.append({"start": iso(ts), "version": m.group("version"),
                                 "stopped": iso(pending_stop) if pending_stop else None,
                                 "downtime_s": round((ts - pending_stop).total_seconds(), 1) if pending_stop else None,
                                 "clean": pending_stop is not None})
                ctx["last_start"] = ts
                pending_stop = None
            elif name == "shutdown":
                pending_stop = ts
            elif name == "state_change":
                states.append({"ts": iso(ts), "state": m.group("state"), "level": level})
            if name in ("startup", "shutdown"):
                break
    # A startup is "unclean" when it was not preceded by a "Server stopping" line in the window
    # (crash, OOM kill, power loss). The very first line of the window being a start is treated as clean.
    for i, rs in enumerate(restarts):
        if rs["stopped"] is None:
            if i == 0 and rs["start"] == iso(first):
                rs["clean"] = True
            else:
                det["startup"]["levels"]["WARN"] += 1
    if pending_stop:
        restarts.append({"start": None, "version": None, "stopped": iso(pending_stop), "downtime_s": None,
                         "clean": True})
    level = 0
    for n, d in det.items():
        for lv in d["levels"]:
            level = max(level, LEVELS[lv])
    if sev["ERR"] + sev["FTL"] > 0:
        # ERR/FTL lines are CRIT unless every one of them was a NodeStore hit downgraded by the startup grace.
        graced = det["nodestore_error"]["levels"]["WARN"]
        level = max(level, LEVELS["CRIT"] if sev["ERR"] + sev["FTL"] > graced else LEVELS["WARN"])
    if stats["errors"]:
        level = LEVELS["CRIT"]
    result = {v: k for k, v in LEVELS.items()}[level]
    span_h = round((last - first).total_seconds() / 3600, 2) if first and last else 0
    rep = {
        "tool": "pft-logscan",
        "files": [os.path.basename(p) for p in paths],
        "window": {"since": iso(since), "until": iso(until), "first": iso(first), "last": iso(last),
                   "span_hours": span_h},
        "lines": stats["lines"], "entries": entries, "continuation_lines": stats["continuation_lines"],
        "read_errors": stats["errors"],
        "severity": {s: sev[s] for s in SEVERITIES},
        "partitions_top": [{"partition": p, "count": c} for p, c in part.most_common(opts["top"])],
        "partitions_top_wrn_err": [{"partition": p, "count": c} for p, c in part_wrn.most_common(opts["top"])],
        "detectors": {n: {"count": d["count"], "levels": dict(d["levels"]), "first": iso(d["first"]),
                          "last": iso(d["last"]), "examples": d["examples"]} for n, d in det.items()},
        "restarts": restarts,
        "state_changes": states,
        "timeline_hourly": [{"hour": h, "wrn": v["WRN"], "err": v["ERR"]} for h, v in sorted(hourly.items())],
        "result": result,
        "exit_code": {"OK": EXIT_OK, "INFO": EXIT_OK, "WARN": EXIT_WARN, "CRIT": EXIT_CRIT}[result],
    }
    rep["result"] = "OK" if result == "INFO" else result
    return sanitize.deep(rep)


# --- output -------------------------------------------------------------------------------
def render_text(rep):
    out = []
    w = rep["window"]
    out.append("pft-logscan  files=%d  lines=%d  entries=%d  continuation=%d" % (
        len(rep["files"]), rep["lines"], rep["entries"], rep["continuation_lines"]))
    out.append("window  first=%s  last=%s  span=%.2fh  (since=%s until=%s)" % (
        w["first"], w["last"], w["span_hours"], w["since"] or "-", w["until"] or "-"))
    out.append("files   " + " ".join(rep["files"]))
    for e in rep["read_errors"]:
        out.append("READ ERROR  " + e)
    out.append("")
    out.append("severity  " + "  ".join("%s=%d" % (s, rep["severity"][s]) for s in SEVERITIES))
    out.append("top partitions (all):     " + ", ".join("%s=%d" % (x["partition"], x["count"])
                                                       for x in rep["partitions_top"]))
    out.append("top partitions (WRN+):    " + (", ".join("%s=%d" % (x["partition"], x["count"])
                                                         for x in rep["partitions_top_wrn_err"]) or "-"))
    out.append("")
    out.append("%-18s %7s  %-24s %-24s %s" % ("detector", "count", "first", "last", "levels"))
    for n, d in rep["detectors"].items():
        lv = ",".join("%s=%d" % kv for kv in sorted(d["levels"].items())) or "-"
        out.append("%-18s %7d  %-24s %-24s %s" % (n, d["count"], d["first"] or "-", d["last"] or "-", lv))
    out.append("")
    out.append("restarts (%d):" % len([r for r in rep["restarts"] if r["start"]]))
    for r in rep["restarts"]:
        out.append("  stop=%-24s start=%-24s down=%-8s %s %s" % (
            r["stopped"] or "-", r["start"] or "-", "%ss" % r["downtime_s"] if r["downtime_s"] is not None else "-",
            "clean" if r["clean"] else "UNCLEAN", r["version"] or ""))
    out.append("state changes (%d): " % len(rep["state_changes"]) +
               " ".join("%s>%s" % (s["ts"][11:19], s["state"]) for s in rep["state_changes"][-30:]))
    out.append("")
    out.append("examples (sanitized):")
    for n, d in rep["detectors"].items():
        if d["levels"].get("WARN") or d["levels"].get("CRIT"):
            for ex in d["examples"][:3]:
                out.append("  [%s] %s %s  %s" % (n, ex["ts"], ex["level"], ex["msg"][:160]))
    out.append("")
    out.append("hourly WRN/ERR timeline:")
    peak = max([t["wrn"] + t["err"] for t in rep["timeline_hourly"]] or [1]) or 1
    for t in rep["timeline_hourly"]:
        bar = "#" * max(1, round(40 * (t["wrn"] + t["err"]) / peak))
        out.append("  %s  wrn=%5d err=%3d  %s" % (t["hour"], t["wrn"], t["err"], bar))
    out.append("")
    out.append("RESULT: %s (exit %d)" % (rep["result"], rep["exit_code"]))
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Read-only postfiatd debug.log analyzer (sanitized output).")
    ap.add_argument("--log-dir", default="/opt/postfiatd/logs", help="directory with debug.log and rotations")
    ap.add_argument("--file", action="append", help="analyze these files instead of --log-dir (repeatable)")
    ap.add_argument("--since", help="ISO-8601 UTC or relative (24h, 90m, 7d)")
    ap.add_argument("--until", help="ISO-8601 UTC or relative")
    ap.add_argument("--json", action="store_true", help="print the JSON report")
    ap.add_argument("--salt", help="fixed salt for labels (default: random per run)")
    ap.add_argument("--slow-ms", type=int, default=DEFAULTS["slow_ms"])
    ap.add_argument("--startup-grace", type=int, default=DEFAULTS["startup_grace"])
    ap.add_argument("--top", type=int, default=DEFAULTS["top"])
    ap.add_argument("--stats", action="store_true", help="print runtime and peak RSS to stderr")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return EXIT_USAGE if e.code else 0
    try:
        since, until = parse_when(a.since), parse_when(a.until)
    except ValueError as e:
        print("pft-logscan: %s" % e, file=sys.stderr)
        return EXIT_USAGE
    paths = a.file or discover(a.log_dir)
    if not paths:
        print("pft-logscan: no debug.log files found in %s" % a.log_dir, file=sys.stderr)
        return EXIT_CRIT
    t0 = time.monotonic()
    rep = analyze(paths, since, until, {"slow_ms": a.slow_ms, "startup_grace": a.startup_grace, "top": a.top},
                  Sanitizer(a.salt if a.salt is not None else secrets.token_hex(8)))
    print(json.dumps(rep, indent=2) if a.json else render_text(rep))
    if a.stats:
        import resource
        size = sum(os.path.getsize(p) for p in paths)
        print("stats: files=%d bytes_on_disk=%d lines=%d runtime_s=%.2f peak_rss_mb=%.1f" % (
            len(paths), size, rep["lines"], time.monotonic() - t0,
            resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024), file=sys.stderr)
    return rep["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
