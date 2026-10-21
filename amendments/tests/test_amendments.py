"""Unit tests for pft-amendments.py response parsing (run: python3 -m pytest -v amendments/tests)."""
import copy
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
spec = importlib.util.spec_from_file_location("pft_amendments",
                                              os.path.join(HERE, "..", "pft-amendments.py"))
pa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pa)
FAKE = "F" * 60 + "0001"


def raw(name):
    return pa.fetch_fixture(os.path.join(FIX, name))


def test_healthy_counts_and_exit_0(capsys):
    snap = pa.build_snapshot(raw("healthy"), 336)
    assert snap["counts"] == {"total": 3, "enabled": 1, "supported": 3, "enabled_unsupported": 0,
                              "pending_majority": 0, "voting_no": 1, "obsolete": 1}
    assert snap["risks"] == [] and snap["amendment_blocked"] is False
    assert pa.main(["--fixture", os.path.join(FIX, "healthy")]) == 0
    assert "OK: no enabled or pending amendment" in capsys.readouterr().out


def test_enabled_unsupported_exit_2():
    snap = pa.build_snapshot(raw("enabled-unsupported"), 336)
    assert snap["amendment_blocked"] is True
    assert any(r.startswith("ENABLED_UNSUPPORTED FixtureFutureAmendment") for r in snap["risks"])
    assert pa.main(["--fixture", os.path.join(FIX, "enabled-unsupported")]) == 2


def test_enabled_in_ledger_but_unknown_to_build_is_risk():
    r = raw("healthy")
    r["amendments"]["result"]["node"]["Amendments"].append(FAKE)
    snap = pa.build_snapshot(r, 336)
    row = next(x for x in snap["amendments"] if x["id"] == FAKE)
    assert row["enabled"] and not row["supported"] and row["name"] == "(unknown to this build)"
    assert snap["risks"] == ["ENABLED_UNSUPPORTED (unknown to this build) " + FAKE]


def test_pending_majority_eta_and_risk():
    r = raw("pending-unsupported")
    close = r["amendments"]["result"]["node"]["Majorities"][0]["Majority"]["CloseTime"]
    now = close + pa.RIPPLE_EPOCH + 36 * 3600
    snap = pa.build_snapshot(r, 336, now=now)
    row = next(x for x in snap["amendments"] if x["id"] == FAKE)
    assert row["hours_to_activation"] == 300.0
    assert snap["counts"]["pending_majority"] == 1
    assert snap["risks"][0].startswith("PENDING_UNSUPPORTED FixtureFutureAmendment")


def test_fee_settings_legacy_and_drops_formats():
    legacy = {"BaseFee": "a", "ReserveBase": 10000000, "ReserveIncrement": 2000000,
              "ReferenceFeeUnits": 10}
    assert pa.parse_fee_settings(legacy)["base_fee"] == 10
    drops = {"BaseFeeDrops": "12", "ReserveBaseDrops": "1000000", "ReserveIncrementDrops": "200000"}
    assert pa.parse_fee_settings(drops) == {"base_fee": 12, "reserve_base": 1000000,
                                            "reserve_inc": 200000, "format": "drops"}


def test_config_voting_parse_ignores_comments_and_other_sections():
    cfg = "[server]\nport_rpc\n[voting]\nreference_fee = 10  # drops\naccount_reserve 1000000\n" \
          "#owner_reserve = 5\n[veto_amendments]\nABC Foo\n"
    sec = pa.parse_config(cfg)
    assert set(sec) == {"voting", "veto_amendments"}
    assert pa.parse_voting(sec["voting"]) == {"base_fee": 10, "reserve_base": 1000000}


def test_rpc_error_is_reported():
    r = raw("healthy")
    r["fees"] = {"result": {"status": "error", "error": "entryNotFound"}}
    try:
        pa.build_snapshot(r, 336)
    except pa.RPCError as e:
        assert "entryNotFound" in str(e)
    else:
        raise AssertionError("expected RPCError")


def test_compare_detects_status_and_fee_changes(tmp_path):
    old = pa.build_snapshot(raw("healthy"), 336)
    new = copy.deepcopy(old)
    new["amendments"][2]["vetoed"] = False
    new["fees"]["network_fee_settings"]["base_fee"] = 12
    diffs = pa.compare(old, new)
    assert any(d.startswith("CHANGED  TokenEscrow: vetoed -> voting-yes") for d in diffs)
    assert "FEE      network_fee_settings.base_fee: 10 -> 12" in diffs
    assert pa.compare(old, old) == []
    p = tmp_path / "snap.json"
    p.write_text(json.dumps(old))
    assert pa.main(["--fixture", os.path.join(FIX, "healthy"), "--compare", str(p)]) == 0
    old["amendments"].pop()
    p.write_text(json.dumps(old))
    assert pa.main(["--fixture", os.path.join(FIX, "healthy"), "--compare", str(p)]) == 3
