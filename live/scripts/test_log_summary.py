import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import log_summary  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "dogfood-sample.log")

# Expected counts for fixtures/dogfood-sample.log (author both together):
#   vm_starts 3 | reloads 2 (fanout 3 + 5) | modules_reloaded 8 | fanout_max 5
#   compile_errors 1 | rollbacks manual 1 (reason=manual), auto 1 (raise)
#   guard_failures attributed 1, unattributed 1 | tests passed 1, failed 1, stale 1
#   syncs 7 modules | handoffs crash 2, graceful 1, failed 1 | handoff ms 15,40,90
#   crashes local_client 2, session 1, store 1 | layout_resets 1 (store restored)
#   session_losses 1 | unparsed 1 (ts=oops)
EXPECTED = {
    "vm_starts": 3,
    "reloads": 2,
    "modules_reloaded": 8,
    "fanout_max": 5,
    "compile_errors": 1,
    "rollbacks": {"manual": 1, "auto": 1},
    "rollback_reasons": {"manual": 1, "raise": 1},
    "guard_failures": {"attributed": 1, "unattributed": 1},
    "tests": {"passed": 1, "failed": 1, "stale": 1},
    "syncs": {"modules": 7},
    "handoffs": {"crash": 2, "graceful": 1, "failed": 1},
    "handoff_ms_p50": 40,
    "handoff_ms_p95": 90,
    "handoff_ms_max": 90,
    "crashes": {"local_client": 2, "session": 1, "store": 1},
    "layout_resets": 1,
    "session_losses": 1,
    "unparsed": 1,
}


def run(*args, env=None):
    e = dict(os.environ, **(env or {}))
    return subprocess.run(
        [sys.executable, os.path.join(HERE, "log_summary.py"), *args],
        capture_output=True, text=True, env=e,
    )


class LogSummaryTest(unittest.TestCase):
    def test_fixture_counts(self):
        r = run(FIXTURE, "--json")
        self.assertEqual(r.returncode, 0)
        got = json.loads(r.stdout)
        for k, v in EXPECTED.items():
            self.assertEqual(got[k], v, k)
        self.assertEqual(got["period"], "2026-10-20T09:59:00Z .. 2026-10-20T10:09:00Z")

    def test_text_output_order_and_exit_line(self):
        out = run(FIXTURE).stdout.splitlines()
        keys = [l.split(":")[0] for l in out]
        self.assertEqual(keys, [
            "period", "vm_starts", "reloads", "modules_reloaded", "fanout_max",
            "compile_errors", "rollbacks", "rollback_reasons", "guard_failures", "tests",
            "syncs", "handoffs", "handoff_ms_p50", "handoff_ms_p95", "handoff_ms_max",
            "crashes", "layout_resets", "session_losses", "unparsed", "exit_criterion"])
        self.assertIn("rollbacks: manual 1, auto 1", out)
        self.assertIn("handoffs: crash 2, graceful 1, failed 1", out)
        self.assertEqual(out[-1], "exit_criterion: session_losses=0 -> FAIL (1)")

    def test_since_drops_earlier_events(self):
        got = json.loads(run(FIXTURE, "--json", "--since", "2026-10-20T10:05:00Z").stdout)
        self.assertEqual(got["reloads"], 0)
        self.assertEqual(got["rollbacks"], {"manual": 0, "auto": 0})
        self.assertEqual(got["vm_starts"], 2)
        self.assertEqual(got["session_losses"], 1)
        self.assertTrue(got["period"].startswith("2026-10-20T10:05:00Z"))

    def test_empty_log(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("2026-10-20 10:00:00.000 [info] nothing here\n")
            f.flush()
            out = run(f.name).stdout
        self.assertIn("reloads: 0\n", out)
        self.assertTrue(out.rstrip().endswith("exit_criterion: session_losses=0 -> OK"))

    def test_unreadable_log_exits_2(self):
        self.assertEqual(run("/nonexistent/herdr.log").returncode, 2)

    def test_default_path_from_env(self):
        r = run("--json", env={"HERDR_LIVE_LOG": FIXTURE})
        self.assertEqual(json.loads(r.stdout)["reloads"], 2)

    def test_quoted_values_parse_back(self):
        line = ('x [info] herdr-event rollback ts=5 batch=1 reason=raise '
                'detail="say \\"hi\\" in C:\\\\tmp\\\\a b" next=ok')
        kind, ts, f = log_summary.parse_line(line)
        self.assertEqual((kind, ts), ("rollback", 5))
        self.assertEqual(f["detail"], 'say "hi" in C:\\tmp\\a b')
        self.assertEqual(f["next"], "ok")

    def test_fixture_quoted_compile_error_value(self):
        with open(FIXTURE) as fh:
            line = next(l for l in fh if "compile_error" in l)
        f = log_summary.parse_line(line)[2]
        self.assertEqual(
            f["msg"],
            'undefined function foo/1 (expected "Mod" to define it; path C:\\tmp\\x.ex)')

    def test_malformed_and_plain_lines(self):
        self.assertIsNone(log_summary.parse_line("just a log line"))
        self.assertIs(log_summary.parse_line("herdr-event x ts=abc"), False)
        self.assertIs(log_summary.parse_line('herdr-event x ts=1 a="unterminated'), False)


if __name__ == "__main__":
    unittest.main()
