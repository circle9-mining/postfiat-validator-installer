"""Unit tests for pft-peers.py over sanitized fixtures (run: python3 -m pytest -v peers/tests)."""
import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
spec = importlib.util.spec_from_file_location("pft_peers", os.path.join(HERE, "..", "pft-peers.py"))
pp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pp)


def run(name, *extra):
    return pp.main(["--fixture", os.path.join(FIX, name), "--salt", "test"] + list(extra))


def levels(name, *extra):
    opts = dict(pp.DEFAULTS, fixed_peer=list(extra))
    rep = pp.build_report(pp.fetch_fixture(os.path.join(FIX, name)), opts, "test")
    return rep, {c["check"]: c["level"] for c in rep["checks"]}


def test_healthy_exit_0_and_summary():
    rep, lv = levels("healthy")
    assert rep["exit_code"] == 0 and rep["result"] == "OK"
    assert rep["summary"]["inbound"] == 3 and rep["summary"]["outbound"] == 5
    assert rep["summary"]["latency_ms"] == {"p50": 260, "p90": 340, "max": 340}
    assert lv["peers.fixed"] == "SKIP"
    assert run("healthy") == 0


def test_warn_outdated_versions_exit_1(capsys):
    rep, lv = levels("warn-outdated")
    assert lv["peers.versions"] == "WARN" and rep["summary"]["outdated"] == 3
    assert run("warn-outdated") == 1
    assert "[WARN] peers.versions: 3/8 older than local 1.0.9" in capsys.readouterr().out


def test_warn_low_peer_count_exit_1():
    _, lv = levels("warn-low-count")
    assert lv["peers.count"] == "WARN"
    assert run("warn-low-count") == 1


def test_fail_sentry_missing_exit_2(capsys):
    rep, lv = levels("fail-sentry-missing")
    assert lv["peers.fixed"] == "FAIL" and lv["peers.private"] == "WARN"
    assert rep["local"]["peer_private"] is True
    assert run("fail-sentry-missing") == 2
    out = capsys.readouterr().out
    assert "[FAIL] peers.fixed: 0/1 fixed peers connected" in out
    assert "[WARN] peers.private: peer_private=1; 6 peers outside the fixed set" in out


def test_sentry_ok_exit_0():
    # private validator with only its sentry connected: 1 peer is expected, not a low-count WARN
    _, lv = levels("sentry-ok")
    assert lv["peers.count"] == "OK" and lv["peers.fixed"] == "OK" and lv["peers.private"] == "OK"
    assert run("sentry-ok") == 0


def test_fixed_peer_flag_overrides_and_fails():
    assert run("healthy", "--fixed-peer", "sentry.fixture.invalid:2559") == 2
    assert run("healthy", "--fixed-peer", "peer1.fixture.invalid") == 0


def test_no_peers_fail_exit_2():
    _, lv = levels("fail-no-peers")
    assert lv["peers.count"] == "FAIL"
    assert run("fail-no-peers") == 2


def test_rpc_error_is_fail(tmp_path):
    (tmp_path / "peers.json").write_text(json.dumps({"result": {"status": "error", "error": "noPermission"}}))
    (tmp_path / "server_info.json").write_text(json.dumps({"result": {"info": {}}}))
    assert pp.main(["--fixture", str(tmp_path)]) == 2


def test_output_has_no_addresses_or_keys(capsys):
    for name in ("healthy", "fail-sentry-missing"):
        run(name)
        run(name, "--json")
    out = capsys.readouterr().out
    assert "fixture.invalid" not in out and "fixture-key" not in out
    assert "p-" in out


def test_labels_salted_and_stable():
    p = {"public_key": "fixture-key-0"}
    assert pp.label("a", p) == pp.label("a", p) != pp.label("b", p)


def test_parsers():
    assert pp.newest_ledger("7354150 - 7354662,7354670") == 7354670
    assert pp.newest_ledger("empty") is None
    assert pp.version_tuple("postfiatd-1.0.9-rc1") == (1, 0, 9)
    assert pp.host_of("[2001:db8::1]:2559") == "2001:db8::1"
    assert pp.host_of("sentry.fixture.invalid 2559") == "sentry.fixture.invalid"
    assert pp.percentile([1, 2, 3, 4], 50) == 2 and pp.percentile([], 50) is None


def test_usage_error_exit_64():
    try:
        pp.main(["--bogus"])
    except SystemExit as e:
        assert e.code == 64
