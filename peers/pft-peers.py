#!/usr/bin/env python3
"""Read-only peer diagnostics for a local Post Fiat node.

Queries the node's admin RPC through `docker exec <container> curl` to the
loopback admin port using only the read-only methods `peers` and `server_info`.
With --read-config it also `cat`s the node config (read-only) to pick up
[peers_max], [ips_fixed] and [peer_private].

Output never contains peer IPs, ports, public keys, ledger hashes or server
domains: each peer is shown as a short salted SHA-256 label.

Exit codes: 0 OK, 1 WARN, 2 FAIL (including RPC errors), 64 usage error.
"""
import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys

READ_ONLY_CALLS = {"peers": "peers", "server_info": "server_info"}
EXIT_OK, EXIT_WARN, EXIT_FAIL = 0, 1, 2
LEVEL_EXIT = {"OK": EXIT_OK, "INFO": EXIT_OK, "SKIP": EXIT_OK, "WARN": EXIT_WARN, "FAIL": EXIT_FAIL}
DEFAULTS = {
    "min_peers": 5,           # WARN below this many peers (FAIL at 0)
    "peers_max": 21,          # postfiatd/rippled default when [peers_max] is unset
    "max_outdated_pct": 20,   # WARN if more than this % of peers run an older build than ours
    "latency_p90_ms": 1000,   # WARN if p90 peer latency exceeds this
    "min_median_uptime": 300,  # WARN if the median peer connection is younger (seconds): churn
    "max_ledger_lag": 10,     # a peer is "lagging" if its newest ledger is this far behind ours
    "max_lagging_pct": 50,    # WARN if more than this % of peers are lagging or report no ledgers
}


class RPCError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):  # keep exit 2 reserved for FAIL
        self.print_usage(sys.stderr)
        sys.stderr.write(f"{self.prog}: error: {message}\n")
        sys.exit(64)


# ---------------------------------------------------------------- transport
def docker_exec(container, args, timeout=20):
    cmd = ["docker", "exec", container] + args
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RPCError(f"docker exec {container}: {e}") from e
    if out.returncode != 0 or not out.stdout.strip():
        raise RPCError(f"docker exec {container} rc={out.returncode} {out.stderr.strip()}")
    return out.stdout


def docker_rpc(container, url, method):
    if method not in READ_ONLY_CALLS.values():
        raise RPCError(f"refusing non-allowlisted method {method}")
    body = json.dumps({"method": method, "params": [{}]})
    out = docker_exec(container, ["curl", "-s", "--max-time", "10", url, "-X", "POST",
                                  "-H", "Content-Type: application/json", "-d", body])
    try:
        return json.loads(out)
    except ValueError as e:
        raise RPCError(f"{method}: invalid JSON from node") from e


def fetch_live(container, url, config_path=None):
    raw = {key: docker_rpc(container, url, method) for key, method in READ_ONLY_CALLS.items()}
    raw["config"] = docker_exec(container, ["cat", config_path]) if config_path else None
    return raw


def fetch_fixture(path):
    raw = {}
    for key in READ_ONLY_CALLS:
        with open(os.path.join(path, key + ".json"), encoding="utf-8") as f:
            raw[key] = json.load(f)
    cfg = os.path.join(path, "postfiatd.cfg")
    raw["config"] = None
    if os.path.exists(cfg):
        with open(cfg, encoding="utf-8") as f:
            raw["config"] = f.read()
    return raw


# ---------------------------------------------------------------- parsing
def result_of(resp, what):
    res = resp.get("result", resp) if isinstance(resp, dict) else {}
    if res.get("status") == "error" or "error" in res:
        raise RPCError("{}: {}".format(what, res.get("error_message") or res.get("error")))
    return res


def parse_config(text):
    """Return {section: [non-comment lines]} for an rippled-style ini file."""
    sections, cur = {}, None
    for line in (text or "").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("[") and s.endswith("]"):
            cur = s[1:-1].strip()
            sections.setdefault(cur, [])
        elif cur is not None:
            sections[cur].append(s)
    return sections


def host_of(addr):
    """Host part of 'ip:port', '[v6]:port', 'host port' or bare host; lowercased."""
    a = (addr or "").strip().lower()
    if a.startswith("["):
        return a[1:a.index("]")] if "]" in a else a[1:]
    if " " in a:
        return a.split()[0]
    if a.count(":") == 1:
        return a.split(":")[0]
    return a  # bare host or bare IPv6


def version_tuple(v):
    """'1.0.9' / 'postfiatd-1.0.9-rc1' -> (1, 0, 9); None if unparseable."""
    v = (v or "").split("-")
    for part in v:
        nums = part.split(".")
        if len(nums) >= 2 and all(n.isdigit() for n in nums):
            return tuple(int(n) for n in nums)
    return None


def newest_ledger(ranges):
    """Highest seq in a complete_ledgers string like '7354150 - 7354662,7354670'."""
    best = None
    for chunk in (ranges or "").replace(" ", "").split(","):
        if not chunk or chunk == "empty":
            continue
        try:
            hi = int(chunk.split("-")[-1])
        except ValueError:
            continue
        best = hi if best is None else max(best, hi)
    return best


def percentile(values, pct):
    """Nearest-rank percentile; None for an empty list."""
    if not values:
        return None
    s = sorted(values)
    k = max(1, -(-len(s) * pct // 100))  # ceil(n*pct/100)
    return s[int(k) - 1]


def label(salt, peer):
    ident = peer.get("public_key") or peer.get("address") or json.dumps(peer, sort_keys=True)
    return "p-" + hashlib.sha256((salt + ident).encode()).hexdigest()[:8]


# ---------------------------------------------------------------- analysis
def build_report(raw, opts, salt):
    info = result_of(raw["server_info"], "server_info").get("info", {})
    peers = result_of(raw["peers"], "peers").get("peers") or []
    cfg = parse_config(raw.get("config")) if raw.get("config") is not None else None
    checks = []

    def check(name, level, msg):
        checks.append({"check": name, "level": level, "message": msg})

    local_build = info.get("build_version")
    local_tuple = version_tuple(local_build)
    local_seq = (info.get("validated_ledger") or {}).get("seq")
    state = info.get("server_state")
    check("local.state", "OK" if state in ("full", "proposing", "validating") else "WARN",
          f"server_state={state} build={local_build} validated_ledger={local_seq}")

    # peer limits: config beats flag beats default
    peers_max, src = opts["peers_max"], "flag/default"
    if cfg and cfg.get("peers_max"):
        try:
            peers_max, src = int(cfg["peers_max"][0]), "config"
        except ValueError:
            pass
    # a private validator ([peer_private]=1) only talks to its fixed peers, so expect just those
    fixed = list(opts["fixed_peer"]) or (cfg.get("ips_fixed", []) if cfg else [])
    peer_private = cfg["peer_private"][0] == "1" if cfg and cfg.get("peer_private") else None
    min_peers = min(opts["min_peers"], len(fixed)) if (peer_private and fixed) else opts["min_peers"]
    n = len(peers)
    reported = info.get("peers")
    level = "OK"
    if n == 0:
        level = "FAIL"
    elif n < min_peers:
        level = "WARN"
    msg = f"{n} peers (min {min_peers}, peers_max {peers_max} from {src})"
    if reported is not None and reported != n:
        msg += f"; server_info reports {reported} (changed between calls?)"
    if n > peers_max:
        msg += "; above peers_max (fixed/cluster peers do not count toward the limit)"
    check("peers.count", level, msg)

    inbound = sum(1 for p in peers if p.get("inbound"))
    check("peers.direction", "INFO", f"{inbound} inbound / {n - inbound} outbound")

    # versions
    dist, outdated, unknown = {}, 0, 0
    for p in peers:
        v = p.get("version") or "unknown"
        dist[v] = dist.get(v, 0) + 1
        t = version_tuple(p.get("version"))
        if t is None:
            unknown += 1
        elif local_tuple and t < local_tuple:
            outdated += 1
    pct = 100.0 * outdated / n if n else 0.0
    level = "WARN" if n and pct > opts["max_outdated_pct"] else "OK"
    vtxt = ", ".join(f"{v}x{c}" for v, c in sorted(dist.items(), key=lambda kv: (-kv[1], kv[0])))
    check("peers.versions", level,
          f"{outdated}/{n} older than local {local_build} ({pct:.0f}%, warn >{opts['max_outdated_pct']}%);"
          f" {unknown} unknown; dist: {vtxt or 'none'}")

    # latency
    lat = [p["latency"] for p in peers if isinstance(p.get("latency"), (int, float))]
    p50, p90, mx = percentile(lat, 50), percentile(lat, 90), (max(lat) if lat else None)
    if not lat:
        check("peers.latency", "SKIP" if n == 0 else "INFO", "no latency reported")
    else:
        check("peers.latency", "WARN" if p90 > opts["latency_p90_ms"] else "OK",
              f"p50={p50}ms p90={p90}ms max={mx}ms over {len(lat)} peers (warn p90>{opts['latency_p90_ms']}ms)")

    # uptime
    up = [p["uptime"] for p in peers if isinstance(p.get("uptime"), (int, float))]
    if not up:
        check("peers.uptime", "SKIP" if n == 0 else "INFO", "no uptime reported")
    else:
        med = percentile(up, 50)
        check("peers.uptime", "WARN" if med < opts["min_median_uptime"] else "OK",
              f"min={min(up)}s p50={med}s max={max(up)}s (warn p50<{opts['min_median_uptime']}s)")

    # ledger coverage
    lagging, empty, net_mismatch = 0, 0, 0
    local_net = info.get("network_id")
    for p in peers:
        hi = newest_ledger(p.get("complete_ledgers"))
        p["_newest"] = hi
        if hi is None:
            empty += 1
        elif local_seq and local_seq - hi > opts["max_ledger_lag"]:
            lagging += 1
        if local_net is not None and p.get("network_id") not in (None, str(local_net), local_net):
            net_mismatch += 1
    bad_pct = 100.0 * (lagging + empty) / n if n else 0.0
    if n == 0:
        check("peers.ledgers", "SKIP", "no peers")
    else:
        level = "WARN" if bad_pct > opts["max_lagging_pct"] or net_mismatch else "OK"
        check("peers.ledgers", level,
              f"{lagging} lagging >{opts['max_ledger_lag']} behind local {local_seq}, {empty} report no ledgers"
              f" ({bad_pct:.0f}%, warn >{opts['max_lagging_pct']}%); {net_mismatch} on a different network_id")

    # fixed / sentry peers
    peer_hosts = {host_of(p.get("address")) for p in peers}
    if not fixed:
        check("peers.fixed", "SKIP", "no fixed/sentry peer configured (--fixed-peer or [ips_fixed] via --read-config)")
    else:
        missing = [i for i, f in enumerate(fixed, 1) if host_of(f) not in peer_hosts]
        level = "FAIL" if missing else "OK"
        msg = f"{len(fixed) - len(missing)}/{len(fixed)} fixed peers connected"
        if missing:
            msg += " (missing fixed peer #" + ", #".join(str(i) for i in missing) + ": validator cut off from its sentry)"
        check("peers.fixed", level, msg)
        if peer_private:
            fixed_hosts = {host_of(f) for f in fixed}
            extra = sum(1 for p in peers if host_of(p.get("address")) not in fixed_hosts)
            check("peers.private", "WARN" if extra else "OK",
                  f"peer_private=1; {extra} peers outside the fixed set")

    worst = max((LEVEL_EXIT[c["level"]] for c in checks), default=EXIT_OK)
    rows = []
    for p in peers:
        hi = p.pop("_newest", None)
        rows.append({
            "label": label(salt, p),
            "dir": "in" if p.get("inbound") else "out",
            "version": p.get("version") or "unknown",
            "latency_ms": p.get("latency"),
            "uptime_s": p.get("uptime"),
            "newest_ledger": hi,
            "lag": (local_seq - hi) if (local_seq and hi is not None) else None,
        })
    rows.sort(key=lambda r: r["label"])
    return {
        "local": {"build_version": local_build, "server_state": state, "validated_ledger": local_seq,
                  "network_id": local_net, "peer_private": peer_private},
        "summary": {"peers": n, "inbound": inbound, "outbound": n - inbound, "peers_max": peers_max,
                    "outdated": outdated, "latency_ms": {"p50": p50, "p90": p90, "max": mx},
                    "lagging": lagging, "no_ledgers": empty},
        "checks": checks,
        "peers": rows,
        "result": {EXIT_OK: "OK", EXIT_WARN: "WARN", EXIT_FAIL: "FAIL"}[worst],
        "exit_code": worst,
    }


# ---------------------------------------------------------------- output
def fmt(v):
    return "-" if v is None else str(v)


def print_table(rep):
    loc = rep["local"]
    print(f"local: build {loc['build_version']}  state {loc['server_state']}  "
          f"validated {loc['validated_ledger']}  network_id {loc['network_id']}")
    print(f"{'PEER':<12} {'DIR':<4} {'VERSION':<10} {'LAT_MS':>7} {'UPTIME_S':>9} {'NEWEST':>9} {'LAG':>5}")
    for r in rep["peers"]:
        print(f"{r['label']:<12} {r['dir']:<4} {r['version']:<10} {fmt(r['latency_ms']):>7} "
              f"{fmt(r['uptime_s']):>9} {fmt(r['newest_ledger']):>9} {fmt(r['lag']):>5}")
    print()
    for c in rep["checks"]:
        print(f"[{c['level']}] {c['check']}: {c['message']}")
    print(f"RESULT: {rep['result']} (exit {rep['exit_code']})")


def parse_args(argv):
    ap = Parser(description=__doc__.splitlines()[0])
    ap.add_argument("--container", default="postfiatd", help="docker container (e.g. postfiatd-sentry)")
    ap.add_argument("--url", default="http://127.0.0.1:5005", help="admin RPC URL inside the container")
    ap.add_argument("--json", action="store_true", help="print JSON instead of the table")
    ap.add_argument("--fixture", help="read peers.json/server_info.json[/postfiatd.cfg] from a directory")
    ap.add_argument("--read-config", nargs="?", const="/etc/postfiatd/postfiatd.cfg", metavar="PATH",
                    help="also cat the node config inside the container (default %(const)s)")
    ap.add_argument("--fixed-peer", action="append", default=[], metavar="HOST[:PORT]",
                    help="peer that must be connected (sentry); repeatable; overrides [ips_fixed]")
    ap.add_argument("--salt", default=os.environ.get("PFT_PEERS_SALT"),
                    help="label salt (env PFT_PEERS_SALT); default random per run, never printed")
    for k, v in DEFAULTS.items():
        ap.add_argument("--" + k.replace("_", "-"), type=int, default=v, help=f"default {v}")
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    opts = {k: getattr(a, k) for k in DEFAULTS}
    opts["fixed_peer"] = a.fixed_peer
    salt = a.salt or secrets.token_hex(16)
    try:
        raw = fetch_fixture(a.fixture) if a.fixture else fetch_live(a.container, a.url, a.read_config)
        rep = build_report(raw, opts, salt)
    except (RPCError, OSError, ValueError, KeyError) as e:
        rep = {"checks": [{"check": "rpc", "level": "FAIL", "message": str(e)}],
               "result": "FAIL", "exit_code": EXIT_FAIL}
        if a.json:
            print(json.dumps(rep, indent=2))
        else:
            print(f"[FAIL] rpc: {e}\nRESULT: FAIL (exit {EXIT_FAIL})")
        return EXIT_FAIL
    if a.json:
        print(json.dumps(rep, indent=2))
    else:
        print_table(rep)
    return rep["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
