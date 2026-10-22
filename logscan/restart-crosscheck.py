#!/usr/bin/env python3
"""Cross-check restarts found by pft-logscan.py against Docker and systemd records (read-only).

Sources, all read-only:
  - pft-logscan.py --json: "Server stopping" / "Process starting" timestamps from debug.log
  - journalctl -u docker: dockerd's per-container stop records ("ignoring event" / "ShouldRestart"),
    network attach on every container start ("sbJoin ... ep=<container>", also when dockerd restores
    the container after a reboot) and daemon stop/start (host reboots)
  - docker events --since/--until (only covers the current dockerd lifetime): container die/start
  - docker inspect: State.StartedAt / State.FinishedAt of the container
  - journalctl --list-boots: host boots

Every debug.log stop/start is matched to the nearest Docker record within --tolerance seconds.
Exit 0 if every restart in the window matched a Docker record, 1 otherwise.
Prints only UTC times, event names and match deltas: no hostnames, container IDs or addresses.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False,
                          env=dict(os.environ, TZ="UTC")).stdout


def parse_ts(s):
    s = re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", s.strip().replace("Z", "+00:00"))
    m = re.match(r"^(.*T\d\d:\d\d:\d\d)(\.\d+)?(.*)$", s)
    frac = (m.group(2) or ".0")[1:7].ljust(6, "0")
    t = dt.datetime.fromisoformat(m.group(1) + "." + frac + (m.group(3) or "+00:00"))
    return t.astimezone(dt.timezone.utc).replace(tzinfo=None)


def fmt(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z" if t else "-"


def docker_records(container, since, until):
    recs = []
    # IDs of existing containers with this name; a container recreated by `docker compose up` gets a new ID
    # and the old one is gone, so older journal records can only be labelled "removed/other container".
    known = set(run(["docker", "ps", "-a", "-q", "--no-trunc", "--filter", "name=^%s$" % container]).split())
    # dockerd journal: one "ignoring event" (+ "ShouldRestart failed") per container stop/die.
    out = run(["journalctl", "-u", "docker", "--no-pager", "-o", "short-iso-precise",
               "--since", since.strftime("%Y-%m-%d %H:%M:%S UTC"), "--until", until.strftime("%Y-%m-%d %H:%M:%S UTC")])
    for line in out.splitlines():
        m = re.search(r'time="([^"]+)" level=\w+ msg="ignoring event" container=(\w+).*topic=/tasks/delete', line)
        if m:
            who = container if m.group(2) in known else "removed/other container"
            recs.append(("stop", parse_ts(m.group(1)), "journal:dockerd task deleted (%s)" % who))
            continue
        # libnetwork joins the container's endpoint (named after the container) on every start, including
        # the restart-policy restore while dockerd boots, which emits no `docker events` start.
        m = re.search(r'time="([^"]+)" level=\w+ msg="sbJoin: [^"]*" eid=\w+ ep=(\S+)', line)
        if m:
            if m.group(2) == container:
                recs.append(("start", parse_ts(m.group(1)), "journal:dockerd sbJoin network attach (%s)" % container))
            continue
        m = re.match(r"^(\S+) \S+ systemd\[1\]: (Stopping|Started) Docker Application Container Engine", line)
        if m:
            recs.append(("daemon_" + ("stop" if m.group(2) == "Stopping" else "start"), parse_ts(m.group(1)),
                         "journal:systemd docker.service " + m.group(2).lower()))
    # --until in the future would make `docker events` stream until then, so clamp it to now.
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    out = run(["docker", "events", "--since", since.strftime("%Y-%m-%dT%H:%M:%SZ"),
               "--until", min(until, now).strftime("%Y-%m-%dT%H:%M:%SZ"), "--filter", "container=" + container,
               "--filter", "event=start", "--filter", "event=die", "--format", "{{.Action}} {{.TimeNano}}"])
    for line in out.splitlines():
        act, ns = line.split()
        t = dt.datetime.fromtimestamp(int(ns) / 1e9, dt.timezone.utc).replace(tzinfo=None)
        recs.append(("stop" if act == "die" else "start", t, "docker events " + act))
    out = run(["docker", "inspect", "-f", "{{.State.StartedAt}} {{.State.FinishedAt}}", container]).split()
    if len(out) == 2:
        recs.append(("start", parse_ts(out[0]), "docker inspect State.StartedAt"))
        if not out[1].startswith("0001"):
            recs.append(("stop", parse_ts(out[1]), "docker inspect State.FinishedAt"))
    return sorted(recs, key=lambda r: r[1])


def boots():
    # " 0 <boot-id> Wed 2026-10-21 20:20:36 UTC—..." (TZ=UTC; systemd 249 has no JSON output here)
    res = []
    for line in run(["journalctl", "--list-boots", "--no-pager"]).splitlines():
        m = re.search(r"\w{3} (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) UTC", line)
        if m:
            res.append(dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log-dir", default="/opt/postfiatd/logs")
    ap.add_argument("--container", default="postfiatd")
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--tolerance", type=float, default=10.0, help="max seconds between log and Docker record")
    a = ap.parse_args(argv)
    rep = json.loads(run([sys.executable, "-I", os.path.join(HERE, "pft-logscan.py"), "--log-dir", a.log_dir,
                          "--since", a.since, "--until", a.until, "--json"]))
    since, until = parse_ts(a.since), parse_ts(a.until)
    recs = docker_records(a.container, since, until)
    print("window %s .. %s  tolerance %.0fs" % (fmt(since), fmt(until), a.tolerance))
    print("host boots in window: " + (", ".join(fmt(b) for b in boots() if since <= b <= until) or "none"))
    print("docker records (%d):" % len(recs))
    for kind, t, src in recs:
        print("  %-12s %s  %s" % (kind, fmt(t), src))
    # dockerd's journal records every container stop; starts show up as sbJoin only for containers with
    # their own network endpoint (not network_mode: host). Otherwise starts are only in `docker events`
    # (in memory, lost when dockerd restarts) and `docker inspect` (latest start only), so unmatched
    # starts older than the current dockerd's start are reported as uncheckable.
    daemon_starts = [t for k, t, _ in recs if k == "daemon_start"]
    events_from = max(daemon_starts) if daemon_starts else since
    print("debug.log restarts vs docker records:")
    matched = unmatched = uncheckable = 0
    for r in rep["restarts"]:
        for kind, key in (("stop", "stopped"), ("start", "start")):
            if not r[key]:
                continue
            t = parse_ts(r[key])
            cands = [(abs((rt - t).total_seconds()), rt, src) for k, rt, src in recs if k == kind]
            best = min(cands) if cands else None
            if best and best[0] <= a.tolerance:
                matched += 1
                print("  MATCH       log %-5s %s  ~ %s  (%+.2fs, %s)" % (kind, r[key], fmt(best[1]),
                                                                        (best[1] - t).total_seconds(), best[2]))
            elif kind == "start" and t < events_from - dt.timedelta(seconds=a.tolerance):
                uncheckable += 1
                print("  UNCHECKABLE log start %s  (before dockerd start %s: no Docker start record kept)" % (
                    r[key], fmt(events_from)))
            else:
                unmatched += 1
                print("  NOMATCH     log %-5s %s  (nearest %s)" % (
                    kind, r[key], "%s %+.1fs" % (fmt(best[1]), (best[1] - t).total_seconds()) if best else "none"))
    print("RESULT: %s  matched=%d unmatched=%d uncheckable=%d" % (
        "ALL CHECKABLE MATCHED" if unmatched == 0 and matched else "UNMATCHED", matched, unmatched, uncheckable))
    return 0 if unmatched == 0 and matched else 1


if __name__ == "__main__":
    sys.exit(main())
