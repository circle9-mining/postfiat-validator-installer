#!/usr/bin/env python3
"""Read-only amendment and fee-voting status for a local Post Fiat node.

Queries the node's admin RPC through `docker exec <container> curl` using only
read-only methods: feature (no params), server_info, server_state, fee and
ledger_entry (Amendments and FeeSettings singletons). Optionally reads the
[voting] / [veto_amendments] / [amendments] stanzas of the node config with `cat`.

Exit codes: 0 ok, 1 RPC/usage error, 2 amendment-blocked risk,
3 --compare found differences (and no risk).
"""
import argparse
import json
import os
import subprocess
import sys
import time

RIPPLE_EPOCH = 946684800
AMENDMENTS_INDEX = "7DB0788C020F02780A673DC74757F23823FA3014C1866E72CC4CD8B226CD6EF4"
FEE_SETTINGS_INDEX = "4BC50C9B0D8515D3EAAE1E74B29A95804346C491EE1A95BF25E4AAB854A6A651"
READ_ONLY_CALLS = {
    "feature": ("feature", {}),
    "server_info": ("server_info", {}),
    "server_state": ("server_state", {}),
    "fee": ("fee", {}),
    "amendments": ("ledger_entry", {"index": AMENDMENTS_INDEX, "ledger_index": "validated"}),
    "fees": ("ledger_entry", {"index": FEE_SETTINGS_INDEX, "ledger_index": "validated"}),
}
VOTING_KEYS = {"reference_fee": "base_fee", "account_reserve": "reserve_base",
               "owner_reserve": "reserve_inc"}
EXIT_OK, EXIT_ERR, EXIT_RISK, EXIT_DIFF = 0, 1, 2, 3
COUNT_KEYS = ("total", "enabled", "supported", "enabled_unsupported", "pending_majority",
              "voting_no", "obsolete")


class RPCError(Exception):
    pass


# ---------------------------------------------------------------- transport
def docker_rpc(container, url, method, params):
    body = json.dumps({"method": method, "params": [params]})
    cmd = ["docker", "exec", container, "curl", "-s", "--max-time", "10", url,
           "-X", "POST", "-H", "Content-Type: application/json", "-d", body]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RPCError(f"{method}: {e}") from e
    if out.returncode != 0 or not out.stdout.strip():
        raise RPCError(f"{method}: docker exec rc={out.returncode} {out.stderr.strip()}")
    return json.loads(out.stdout)


def fetch_live(container, url):
    raw = {}
    for key, (method, params) in READ_ONLY_CALLS.items():
        raw[key] = docker_rpc(container, url, method, params)
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


def read_config(container, path):
    try:
        out = subprocess.run(["docker", "exec", container, "cat", path], capture_output=True,
                             text=True, timeout=20, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout if out.returncode == 0 else None


# ---------------------------------------------------------------- parsing
def result_of(resp, what):
    res = resp.get("result", resp)
    if res.get("status") == "error" or "error" in res:
        raise RPCError("{}: {}".format(what, res.get("error_message") or res.get("error")))
    return res


def parse_config(text):
    """Return {section: [lines]} for the stanzas we care about."""
    sections, cur = {}, None
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            sections.setdefault(cur, [])
        elif cur is not None:
            sections[cur].append(line)
    return {k: v for k, v in sections.items() if k in ("voting", "veto_amendments", "amendments")}


def parse_voting(lines):
    vote = {}
    for line in lines or []:
        parts = line.replace("=", " ").split()
        if len(parts) >= 2 and parts[0] in VOTING_KEYS and parts[1].isdigit():
            vote[VOTING_KEYS[parts[0]]] = int(parts[1])
    return vote


def parse_fee_settings(node):
    """FeeSettings uses legacy (BaseFee hex) or XRPFees-style (*Drops) fields."""
    if "BaseFeeDrops" in node:
        return {"base_fee": int(node["BaseFeeDrops"]),
                "reserve_base": int(node["ReserveBaseDrops"]),
                "reserve_inc": int(node["ReserveIncrementDrops"]), "format": "drops"}
    return {"base_fee": int(str(node["BaseFee"]), 16),
            "reserve_base": int(node["ReserveBase"]),
            "reserve_inc": int(node["ReserveIncrement"]),
            "reference_fee_units": node.get("ReferenceFeeUnits"), "format": "legacy"}


def build_snapshot(raw, majority_hours, now=None):
    now = time.time() if now is None else now
    features = result_of(raw["feature"], "feature").get("features", {})
    info = result_of(raw["server_info"], "server_info")["info"]
    state = result_of(raw["server_state"], "server_state")["state"]
    fee = result_of(raw["fee"], "fee")
    amd_node = result_of(raw["amendments"], "ledger_entry Amendments").get("node", {})
    fee_node = result_of(raw["fees"], "ledger_entry FeeSettings").get("node", {})

    ledger_enabled = set(amd_node.get("Amendments", []))
    majorities = {m["Majority"]["Amendment"]: m["Majority"]["CloseTime"]
                  for m in amd_node.get("Majorities", [])}
    rows = []
    for h in sorted(set(features) | ledger_enabled | set(majorities)):
        f = features.get(h, {})
        row = {"id": h, "name": f.get("name", "(unknown to this build)"),
               "enabled": bool(f.get("enabled")) or h in ledger_enabled,
               "supported": bool(f.get("supported", False)),
               "vetoed": f.get("vetoed", False)}
        for k in ("count", "threshold", "validations"):
            if k in f:
                row[k] = f[k]
        if h in majorities:
            gained = majorities[h] + RIPPLE_EPOCH
            row["majority_since"] = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(gained))
            eta = gained + majority_hours * 3600
            row["activation_eta"] = time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(eta))
            row["hours_to_activation"] = round((eta - now) / 3600, 1)
        rows.append(row)

    risks = []
    for r in rows:
        if r["enabled"] and not r["supported"]:
            risks.append("ENABLED_UNSUPPORTED {} {}".format(r["name"], r["id"]))
        elif "majority_since" in r and not r["supported"]:
            risks.append("PENDING_UNSUPPORTED {} {} activates ~{}".format(r["name"], r["id"],
                                                                     r["activation_eta"]))
    blocked = bool(info.get("amendment_blocked") or state.get("amendment_blocked"))
    if blocked:
        risks.insert(0, "SERVER_AMENDMENT_BLOCKED (server_info.amendment_blocked=true)")

    config = parse_config(raw.get("config"))
    vl = state.get("validated_ledger", {})
    snap = {
        "ledger": vl.get("seq"),
        "server_state": info.get("server_state"),
        "build_version": info.get("build_version"),
        "amendment_blocked": blocked,
        "counts": {
            "total": len(rows),
            "enabled": sum(r["enabled"] for r in rows),
            "supported": sum(r["supported"] for r in rows),
            "enabled_unsupported": sum(r["enabled"] and not r["supported"] for r in rows),
            "pending_majority": sum("majority_since" in r for r in rows),
            "voting_no": sum(r["vetoed"] is True and not r["enabled"] for r in rows),
            "obsolete": sum(r["vetoed"] == "Obsolete" for r in rows),
        },
        "amendments": rows,
        "fees": {
            "network_fee_settings": parse_fee_settings(fee_node),
            "validated_ledger": {k: vl.get(k) for k in ("base_fee", "reserve_base", "reserve_inc")},
            "open_ledger_drops": fee.get("drops", {}),
            "node_vote": parse_voting(config.get("voting")),
            "config_read": raw.get("config") is not None,
            "config_veto_amendments": config.get("veto_amendments", []),
            "config_amendments": config.get("amendments", []),
        },
        "risks": risks,
        "majority_hours_assumed": majority_hours,
    }
    return snap


# ---------------------------------------------------------------- output
def status_word(r):
    if r["enabled"]:
        return "ENABLED" if r["supported"] else "ENABLED!UNSUPPORTED"
    if "majority_since" in r:
        return "MAJORITY"
    if r["vetoed"] == "Obsolete":
        return "obsolete"
    return "vetoed" if r["vetoed"] is True else "voting-yes"


def render_table(snap):
    blocked = str(snap["amendment_blocked"]).lower()
    out = [(f"Post Fiat amendment status  ledger={snap['ledger']}  state={snap['server_state']}"
           f"  build={snap['build_version']}  amendment_blocked={blocked}"), ""]
    out.append(f"{'NAME':<40} {'STATUS':<20} {'SUPPORTED':<9} {'VETOED':<9} ID / MAJORITY")
    for r in sorted(snap["amendments"], key=lambda x: (not x["enabled"], x["name"].lower())):
        extra = r["id"][:16] + "…"
        if "majority_since" in r:
            extra += (f" majority {r['majority_since']}, ETA {r['activation_eta']}"
                      f" ({r['hours_to_activation']:+.1f}h)")
        if "count" in r:
            extra += " votes {}/{}".format(r["count"], r.get("threshold", "?"))
        vet = "Obsolete" if r["vetoed"] == "Obsolete" else ("yes" if r["vetoed"] else "no")
        sup = "yes" if r["supported"] else "NO"
        out.append(f"{r['name'][:40]:<40} {status_word(r):<20} {sup:<9} {vet:<9} {extra}")
    c = snap["counts"]
    out += ["", "Counts: " + " ".join(f"{k}={c[k]}" for k in COUNT_KEYS), ""]
    f = snap["fees"]
    net, vl, vote = f["network_fee_settings"], f["validated_ledger"], f["node_vote"]
    out.append("Fees (drops)        network(FeeSettings)  validated_ledger  this node's vote")
    for k in ("base_fee", "reserve_base", "reserve_inc"):
        v = vote.get(k)
        if v is None:
            v = "default (not set)" if f["config_read"] else "unknown (config not read)"
        elif v != net[k]:
            v = f"{v}  (differs)"
        out.append(f"  {k:<17} {net[k]!s:<21} {vl.get(k)!s:<17} {v}")
    drops = ", ".join(f"{k}={v}" for k, v in sorted(f["open_ledger_drops"].items()))
    out.append(f"  open ledger: {drops}")
    if f["config_veto_amendments"] or f["config_amendments"]:
        out.append(f"  config [veto_amendments]={len(f['config_veto_amendments'])} lines,"
                   f" [amendments]={len(f['config_amendments'])} lines")
    out.append("")
    if snap["risks"]:
        out.append("RISK: amendment-blocked risk detected (exit 2):")
        out += ["  - " + r for r in snap["risks"]]
    else:
        out.append("OK: no enabled or pending amendment is unsupported by this build")
    return "\n".join(out)


def compare(old, new):
    diffs = []
    o = {r["id"]: r for r in old.get("amendments", [])}
    n = {r["id"]: r for r in new.get("amendments", [])}
    for h in sorted(set(o) | set(n)):
        if h not in o:
            diffs.append("NEW      {} ({})".format(n[h]["name"], status_word(n[h])))
        elif h not in n:
            diffs.append("REMOVED  {}".format(o[h]["name"]))
        else:
            a, b = status_word(o[h]), status_word(n[h])
            if a != b or o[h]["supported"] != n[h]["supported"]:
                diffs.append("CHANGED  {}: {} -> {}{}".format(n[h]["name"], a, b,
                             " (supported {} -> {})".format(o[h]["supported"], n[h]["supported"])
                             if o[h]["supported"] != n[h]["supported"] else ""))
    for sect in ("network_fee_settings", "node_vote"):
        a, b = old.get("fees", {}).get(sect, {}), new["fees"][sect]
        for k in sorted(set(a) | set(b)):
            if a.get(k) != b.get(k):
                diffs.append(f"FEE      {sect}.{k}: {a.get(k)} -> {b.get(k)}")
    if old.get("amendment_blocked") != new["amendment_blocked"]:
        diffs.append("BLOCKED  amendment_blocked: {} -> {}".format(old.get("amendment_blocked"),
                                                             new["amendment_blocked"]))
    return diffs


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--container", default=os.environ.get("PFT_CONTAINER", "postfiatd"))
    p.add_argument("--rpc-url", default=os.environ.get("PFT_RPC_URL", "http://localhost:5005/"),
                   help="admin RPC URL as seen from inside the container")
    p.add_argument("--config", default="/etc/postfiatd/postfiatd.cfg",
                   help="config path inside the container (read with cat for [voting])")
    p.add_argument("--no-config", action="store_true", help="do not read the node config")
    p.add_argument("--fixture", metavar="DIR", help="read saved RPC responses instead of the node")
    p.add_argument("--majority-hours", type=float, default=336.0,
                   help="hours a majority must hold before activation (default 336 = 2 weeks)")
    p.add_argument("--json", action="store_true", help="print the snapshot as JSON")
    p.add_argument("--compare", metavar="SNAPSHOT", help="diff against a saved --json snapshot")
    a = p.parse_args(argv)
    try:
        if a.fixture:
            raw = fetch_fixture(a.fixture)
        else:
            raw = fetch_live(a.container, a.rpc_url)
            raw["config"] = None if a.no_config else read_config(a.container, a.config)
        snap = build_snapshot(raw, a.majority_hours)
    except (RPCError, KeyError, ValueError, OSError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return EXIT_ERR
    diffs = None
    if a.compare:
        try:
            with open(a.compare, encoding="utf-8") as f:
                diffs = compare(json.load(f), snap)
        except (OSError, ValueError) as e:
            print(f"ERROR: cannot read snapshot {a.compare}: {e}", file=sys.stderr)
            return EXIT_ERR
    if a.json:
        if diffs is not None:
            snap["compare"] = {"against": a.compare, "differences": diffs}
        print(json.dumps(snap, indent=2, sort_keys=True))
    else:
        print(render_table(snap))
        if diffs is not None:
            print(f"\nCompare vs {a.compare}: {len(diffs)} difference(s)")
            if diffs:
                print("\n".join("  " + d for d in diffs))
    if snap["risks"]:
        return EXIT_RISK
    return EXIT_DIFF if diffs else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
