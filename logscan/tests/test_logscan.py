"""Unit tests for pft-logscan.py (run: python3 -m unittest discover -s logscan/tests -v)."""
import contextlib
import datetime as dt
import gzip
import importlib.util
import io
import json
import os
import re
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
spec = importlib.util.spec_from_file_location("pft_logscan", os.path.join(HERE, "..", "pft-logscan.py"))
ls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ls)

KEY = "n9FixtureKeyForTestsJust" + "A" * 27          # synthetic, valid base58, 51 chars
START = "2026-Oct-20 09:00:00.000000000 UTC Application:NFO Process starting: postfiatd-1.0.9, Instance Cookie: 1"
LATE = "2026-Oct-20 10:00:00.000000000 UTC "        # one hour after START: outside the startup grace
EARLY = "2026-Oct-20 09:01:00.000000000 UTC "       # one minute after START: inside the startup grace


def write(tmp, name, lines, gz=False):
    path = os.path.join(tmp, name)
    data = "\n".join(lines) + "\n"
    if gz:
        with gzip.open(path, "wt") as fh:
            fh.write(data)
    else:
        with open(path, "w") as fh:
            fh.write(data)
    return path


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def scan(self, lines, **kw):
        p = write(self.tmp, "debug.log", lines)
        return ls.analyze([p], kw.pop("since", None), kw.pop("until", None), kw, ls.Sanitizer("test"))

    def hit(self, line, detector, prefix=LATE):
        rep = self.scan([START, prefix + line])
        return rep["detectors"][detector]


class DetectorTests(Base):
    # Each case: (detector, positive line, expected level, negative line that must not count)
    CASES = [
        ("shutdown", "Application:WRN Server stopping: Signal: 15", "INFO",
         "Application:NFO Application starting. Version is 1.0.9"),
        ("state_change", "NetworkOPs:NFO STATE->tracking", "WARN",
         "NetworkOPs:NFO ConsensusLogger Heartbeat Timer: duration 0.0s. mode: full."),
        ("lost_sync", "NetworkOPs:WRN We are not running on the consensus ledger", "WARN",
         "LedgerConsensus:NFO Entering consensus process, watching, synced=yes"),
        ("ledger_jump", "LedgerConsensus:WRN View of consensus changed during establish mode=switchedLedger, A to B",
         "WARN", "NetworkOPs:NFO Heartbeat ... View of consensus changed during establish mode=switchedLedger"),
        ("amendment_blocked", "NetworkOPs:ERR One or more unsupported amendments activated: server blocked.",
         "CRIT", "Amendments:DBG Amendment ABC (AMM) is supported and will be up voted by default"),
        ("amendment_blocked", "NetworkOPs:WRN Amendment blocked: upgrade required", "CRIT",
         "Amendments:DBG Amendment ABC (fixAmendmentMajority) is supported"),
        ("peer_connect", "Peer:NFO [007] Public Key: " + KEY, "INFO",
         "Peer:NFO [007] Protocol: XRPL/2.2"),
        ("peer_disconnect", "Peer:NFO [007] Closed", "INFO", "Peer:NFO [007] Stop"),
        ("peer_disconnect", "Peer:WRN [007] onReadMessage from %s at 192.0.2.10:2559: stream truncated" % KEY,
         "INFO", "Peer:WRN [007] invokeProtocolMessage took 1200 ms"),
        ("peer_charge", "Peer:WRN [007] Charging peer 192.0.2.10:2559 fee=malformed_tx", "WARN",
         "Peer:NFO [007] compression enabled false"),
        ("resource_limit", "Resource:WRN Consumer 192.0.2.10 is over limit, dropping connection", "WARN",
         "Resource:NFO Consumer 192.0.2.10 balance 100"),
        ("peer_probe_failed", "PeerFinder:ERR Logic testing     192.0.2.10:51235 with error, Connection timed out",
         "INFO", "PeerFinder:ERR Logic failed to connect to 192.0.2.10:51235"),
        ("slow_job", "LoadMonitor:WRN Job: acceptLedger run: 40ms wait: 1200ms", "WARN",
         "LoadMonitor:NFO Job: sweep run: 120ms wait: 3ms"),
        ("nodestore_error", "NodeStore:ERR write error: No space left on device", "CRIT",
         "SQLiteDatabaseImp:NFO Transaction DB pathname: /var/lib/x.db; file size: 1 bytes"),
        ("nodestore_error", "NodeFamily:ERR Missing node in 6D0F66D33F4E99349F546A274E05EF8F", "CRIT",
         "NodeFamily:NFO Fetched node 6D0F66D33F4E99349F546A274E05EF8F"),
        ("clock_warning", "NetworkOPs:WRN Close time offset of 25s: clock may be wrong", "WARN",
         "NetworkOPs:NFO Set network adjusted time to 2026-Oct-20 10:00:00 UTC"),
    ]

    def test_positive_and_negative_per_detector(self):
        covered = set()
        for det, pos, level, neg in self.CASES:
            with self.subTest(detector=det, line=pos):
                d = self.hit(pos, det)
                self.assertEqual(d["count"], 1, pos)
                self.assertEqual(d["levels"], {level: 1})
            with self.subTest(detector=det, negative=neg):
                self.assertEqual(self.hit(neg, det)["count"], 0, neg)
            covered.add(det)
        covered.add("startup")  # covered by RestartTests
        self.assertEqual(covered, {d[0] for d in ls.DETECTORS})

    def test_startup_grace_downgrades_sync_and_missing_node(self):
        for det, line in [("lost_sync", "NetworkOPs:WRN Node count (0) has fallen below required minimum (1)."),
                          ("ledger_jump", "LedgerConsensus:WRN View of consensus changed during establish "
                                          "mode=switchedLedger, A to B"),
                          ("state_change", "NetworkOPs:NFO STATE->syncing")]:
            self.assertEqual(self.hit(line, det, EARLY)["levels"], {"INFO": 1}, det)
        d = self.hit("NodeFamily:ERR Missing node in ABCDEF", "nodestore_error", EARLY)
        self.assertEqual(d["levels"], {"WARN": 1})
        rep = self.scan([START, EARLY + "NodeFamily:ERR Missing node in ABCDEF"])
        self.assertEqual((rep["result"], rep["exit_code"]), ("WARN", 1))

    def test_slow_job_nfo_threshold(self):
        line = "LoadMonitor:NFO Job: advanceLedger run: 1500ms wait: 0ms"
        self.assertEqual(self.hit(line, "slow_job")["count"], 1)
        rep = self.scan([START, LATE + line], slow_ms=2000)
        self.assertEqual(rep["detectors"]["slow_job"]["count"], 0)

    def test_full_state_is_info(self):
        self.assertEqual(self.hit("NetworkOPs:NFO STATE->full", "state_change")["levels"], {"INFO": 1})


class RestartTests(Base):
    def test_fixture_restart_cycle(self):
        rep = ls.analyze([os.path.join(FIX, "restart-cycle.log")], sanitize=ls.Sanitizer("test"))
        rs = [r for r in rep["restarts"] if r["start"]]
        self.assertEqual(len(rs), 2)
        self.assertEqual(rs[1]["stopped"], "2026-10-20T11:30:00.100Z")
        self.assertEqual(rs[1]["start"], "2026-10-20T11:30:05.000Z")
        self.assertEqual(rs[1]["downtime_s"], 4.9)
        self.assertEqual(rs[1]["version"], "postfiatd-1.0.10")
        self.assertTrue(all(r["clean"] for r in rs))
        self.assertEqual(rep["continuation_lines"], 2)
        self.assertEqual(rep["severity"]["ERR"], 1)
        # the only ERR is a Missing node 30 s after start -> WARN, not CRIT
        self.assertEqual((rep["result"], rep["exit_code"]), ("WARN", 1))

    def test_unclean_restart_is_warn(self):
        rep = self.scan([START, LATE + "Application:NFO Process starting: postfiatd-1.0.9, Instance Cookie: 2"])
        self.assertFalse(rep["restarts"][1]["clean"])
        self.assertEqual(rep["exit_code"], 1)

    def test_clean_window_is_ok(self):
        rep = self.scan([START, LATE + "NetworkOPs:NFO STATE->full", LATE + "Validations:NFO ok"])
        self.assertEqual((rep["result"], rep["exit_code"]), ("OK", 0))

    def test_unattributed_err_is_crit(self):
        rep = self.scan([START, LATE + "Something:ERR unexpected"])
        self.assertEqual(rep["exit_code"], 2)


    def test_failed_peer_probe_err_is_not_crit(self):
        probe = LATE + "PeerFinder:ERR Logic testing     192.0.2.10:51235 with error, Connection timed out"
        rep = self.scan([START, probe])
        self.assertEqual((rep["severity"]["ERR"], rep["result"], rep["exit_code"]), (1, "OK", 0))
        rep = self.scan([START, probe, LATE + "Something:ERR unexpected"])
        self.assertEqual(rep["exit_code"], 2)

    def test_non_err_nodestore_hit_does_not_excuse_other_err(self):
        # A WRN-level NodeStore hit is WARN; it must not offset an unrelated ERR line.
        rep = self.scan([START, LATE + "NodeStore:WRN write error: retrying", LATE + "Something:ERR unexpected"])
        self.assertEqual(rep["exit_code"], 2)


class InputTests(Base):
    def test_gzip_rotation_ordering_and_window(self):
        write(self.tmp, "debug.log-20261020-100000.gz",
              [START, "2026-Oct-20 09:30:00.000000000 UTC LedgerMaster:WRN SQL DB ledger sequence 5 mismatches"],
              gz=True)
        write(self.tmp, "debug.log-20261020-120000",
              ["2026-Oct-20 10:30:00.000000000 UTC LedgerMaster:WRN SQL DB ledger sequence 6 mismatches"])
        write(self.tmp, "debug.log",
              ["2026-Oct-20 11:30:00.000000000 UTC NodeStore:ERR write error: disk full"])
        write(self.tmp, ".logrotate.status", ["not a log"])
        paths = ls.discover(self.tmp)
        self.assertEqual([os.path.basename(p) for p in paths],
                         ["debug.log-20261020-100000.gz", "debug.log-20261020-120000", "debug.log"])
        rep = ls.analyze(paths, sanitize=ls.Sanitizer("t"))
        self.assertEqual(rep["entries"], 4)
        self.assertEqual(rep["timeline_hourly"], [{"hour": "2026-10-20T09:00Z", "wrn": 1, "err": 0},
                                                  {"hour": "2026-10-20T10:00Z", "wrn": 1, "err": 0},
                                                  {"hour": "2026-10-20T11:00Z", "wrn": 0, "err": 1}])
        win = ls.analyze(paths, ls.parse_when("2026-10-20T10:00:00Z"), ls.parse_when("2026-10-20T11:00:00Z"),
                         sanitize=ls.Sanitizer("t"))
        self.assertEqual(win["entries"], 1)
        self.assertEqual(win["window"]["first"], "2026-10-20T10:30:00.000Z")
        self.assertEqual(win["exit_code"], 0)
        self.assertEqual(rep["exit_code"], 2)

    def test_parse_when(self):
        now = dt.datetime(2026, 10, 22, 12, 0, 0)
        self.assertEqual(ls.parse_when("24h", now), dt.datetime(2026, 10, 21, 12, 0, 0))
        self.assertEqual(ls.parse_when("90m", now), dt.datetime(2026, 10, 22, 10, 30, 0))
        self.assertEqual(ls.parse_when("2026-10-21T04:00:00Z"), dt.datetime(2026, 10, 21, 4, 0, 0))
        self.assertEqual(ls.parse_when("2026-10-21T06:00:00+02:00"), dt.datetime(2026, 10, 21, 4, 0, 0))
        with self.assertRaises(ValueError):
            ls.parse_when("yesterday")

    def test_cli_exit_codes(self):
        p = os.path.join(FIX, "restart-cycle.log")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ls.main(["--file", p, "--salt", "t"]), 1)
            self.assertEqual(ls.main(["--file", p, "--until", "2026-10-20T10:00:10Z"]), 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(ls.main(["--file", p, "--since", "nonsense"]), 64)
            self.assertEqual(ls.main(["--log-dir", self.tmp]), 2)  # no logs found


class SanitizeTests(Base):
    LEAKS = [re.compile(r"(?<![\d.])(\d{1,3}\.){3}\d{1,3}(?![\d.])"),       # IPv4
             re.compile(r"\b2001:db8:[0-9a-f:]+", re.I),                    # IPv6 (doc prefix)
             re.compile(r"\bn[1-9A-HJ-NP-Za-km-z]{49,52}\b"),                # node public key
             re.compile(r":(2559|51235|5005|6006)\b"),                      # ports
             re.compile(r"\bport[ =:]+\d{2,5}\b", re.I)]

    def test_sanitizer_units(self):
        s = ls.Sanitizer("salt")
        out = s("from 192.0.2.10:51235 %s and [2001:db8::1]:2559 and 2001:db8::2 port 2559 ip=0.0.0.0:6006" % KEY)
        for rx in self.LEAKS:
            self.assertIsNone(rx.search(out), (rx.pattern, out))
        self.assertIn(s.label("ip", "192.0.2.10", 8), out)
        self.assertIn(s.label("key", KEY, 8), out)
        # stable per salt, different across salts
        self.assertEqual(s("192.0.2.10"), ls.Sanitizer("salt")("192.0.2.10"))
        self.assertNotEqual(s("192.0.2.10"), ls.Sanitizer("other")("192.0.2.10"))
        # not mangled: versions, timestamps, hashes, hex ids
        keep = "postfiatd-1.0.9 2026-10-21T04:19:54.305Z 20:21:40 6D0F66D33F4E9934 [007] STATE->full"
        self.assertEqual(s(keep), keep)

    def test_text_and_json_output_have_no_leaks_positive_control(self):
        lines = [START,
                 LATE + "Peer:WRN [001] onWriteMessage from %s at 192.0.2.44:2559: Connection reset by peer" % KEY,
                 LATE + "Protocol:WRN [002] Large manifest batch: 40 from [2001:db8::7]:51235 " + KEY,
                 LATE + "Peer:WRN [003] Charging peer 198.51.100.9:2559 fee=bad_data",
                 LATE + "Server:NFO Opened 'port_peer' (ip=0.0.0.0:2559, peer)"]
        p = write(self.tmp, "debug.log", lines)
        with open(p) as fh:
            raw = fh.read()
        for rx in self.LEAKS[:4]:
            self.assertIsNotNone(rx.search(raw), "positive control: raw input must contain " + rx.pattern)
        for args in ([], ["--json"]):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ls.main(["--file", p] + args)
            out = buf.getvalue()
            if args:
                json.loads(out)
            for rx in self.LEAKS:
                self.assertIsNone(rx.search(out), (args, rx.pattern, rx.search(out)))
            self.assertRegex(out, r"ip-[0-9a-f]{8}")


if __name__ == "__main__":
    unittest.main()
