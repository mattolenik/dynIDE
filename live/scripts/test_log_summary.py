import json
import os
import re
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
#   crashes local_client 2, session 1, store 1 | store_restarts 1 (store restored)
#   session_losses 3 (broker session_lost, store session_lost, unclean broker restart
#   pid=102 after pid=101 with no broker_stop) | unparsed 1 (ts=oops)
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
    "store_restarts": 1,
    "session_losses": 3,
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
        self.assertEqual(got["period"], "2026-10-20T09:59:00Z .. 2026-10-20T10:10:10Z")

    def test_text_output_order_and_exit_line(self):
        out = run(FIXTURE).stdout.splitlines()
        keys = [l.split(":")[0] for l in out]
        self.assertEqual(keys, [
            "period", "vm_starts", "reloads", "modules_reloaded", "fanout_max",
            "compile_errors", "rollbacks", "rollback_reasons", "guard_failures", "tests",
            "syncs", "handoffs", "handoff_ms_p50", "handoff_ms_p95", "handoff_ms_max",
            "crashes", "store_restarts", "restores", "persist_writes",
            "persist_scrollback_writes", "persist_errors", "api", "clients", "operator_kills",
            "session_losses", "unparsed",
            "exit_criterion"])
        self.assertIn("rollbacks: manual 1, auto 1", out)
        self.assertIn("handoffs: crash 2, graceful 1, failed 1", out)
        self.assertEqual(out[-1], "exit_criterion: session_losses=0 -> FAIL (3)")

    def test_since_drops_earlier_events(self):
        got = json.loads(run(FIXTURE, "--json", "--since", "2026-10-20T10:05:00Z").stdout)
        self.assertEqual(got["reloads"], 0)
        self.assertEqual(got["rollbacks"], {"manual": 0, "auto": 0})
        self.assertEqual(got["vm_starts"], 2)
        self.assertEqual(got["session_losses"], 3)
        self.assertTrue(got["period"].startswith("2026-10-20T10:05:00Z"))

    def test_empty_log(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("2026-10-20 10:00:00.000 [info] nothing here\n")
            f.flush()
            out = run(f.name).stdout
        self.assertIn("reloads: 0\n", out)
        self.assertTrue(out.rstrip().endswith("exit_criterion: session_losses=0 -> OK"))

    def test_clean_broker_restart_is_not_a_loss(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("herdr-event broker_start ts=1 pid=1\n"
                    "herdr-event broker_stop ts=2 pid=1\n"
                    "herdr-event broker_start ts=3 pid=2\n"
                    "herdr-event crash ts=4 proc=store reason=killed action=restored\n")
            f.flush()
            got = json.loads(run(f.name, "--json").stdout)
        self.assertEqual(got["session_losses"], 0)
        self.assertEqual(got["store_restarts"], 1)

    def summary(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write(text)
            f.flush()
            return json.loads(run(f.name, "--json").stdout)

    def test_operator_kill_is_not_a_loss(self):
        got = self.summary("herdr-event broker_start ts=100000 pid=1\n"
                           "herdr-event session_lost ts=109900 reason=broker_died\n"
                           "herdr-event broker_killed ts=110000 signal=9\n"
                           "herdr-event broker_start ts=120000 pid=2\n")
        self.assertEqual(got["session_losses"], 0)
        self.assertEqual(got["operator_kills"], 1)

    def test_kill_far_from_loss_still_counts(self):
        got = self.summary("herdr-event broker_start ts=100000 pid=1\n"
                           "herdr-event session_lost ts=110000 reason=fallback_restore\n"
                           "herdr-event broker_killed ts=170000 signal=9\n"
                           "herdr-event broker_start ts=180000 pid=2\n")
        self.assertEqual(got["session_losses"], 1)
        self.assertEqual(got["operator_kills"], 1)

    def test_unclean_restart_without_kill_still_counts(self):
        got = self.summary("herdr-event broker_start ts=1 pid=1\n"
                           "herdr-event broker_start ts=2 pid=2\n")
        self.assertEqual(got["session_losses"], 1)
        self.assertEqual(got["operator_kills"], 0)

    def test_persist_events(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("herdr-event persist_restore ts=1 source=none reason=boot\n"
                    "herdr-event persist_write ts=2 panes=2 bytes=900 us=40\n"
                    "herdr-event persist_write ts=3 kind=scrollback panes=2 bytes=4000 us=90\n"
                    "herdr-event persist_restore ts=4 source=disk reason=boot panes=2 scrollback=1 ms=8\n"
                    "herdr-event persist_error ts=5 op=write reason=enospc\n"
                    "herdr-event session_lost ts=6 reason=fallback_restore\n"
                    "herdr-event persist_restore ts=7 source=disk reason=fallback panes=2 scrollback=2 ms=9\n")
            f.flush()
            got = json.loads(run(f.name, "--json").stdout)
            out = run(f.name).stdout.splitlines()
        self.assertEqual(got["restores"], {"disk": 2, "boot": 1, "fallback": 1, "none": 1})
        # the layout write and the scrollback round are counted apart
        self.assertEqual(got["persist_writes"], 1)
        self.assertEqual(got["persist_scrollback_writes"], 1)
        self.assertEqual(got["persist_errors"], 1)
        # a fallback restore still follows a lost session: the rule is unchanged
        self.assertEqual(got["session_losses"], 1)
        self.assertIn("restores: disk=2 (boot=1 fallback=1) none=1", out)
        self.assertIn("persist_writes: 1", out)
        self.assertIn("persist_scrollback_writes: 1", out)
        self.assertIn("persist_errors: 1", out)

    def test_fixture_has_no_persist_events(self):
        got = json.loads(run(FIXTURE, "--json").stdout)
        self.assertEqual(got["restores"], {"disk": 0, "boot": 0, "fallback": 0, "none": 0})
        self.assertEqual((got["persist_writes"], got["persist_scrollback_writes"],
                          got["persist_errors"]), (0, 0, 0))

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

    def test_api_section(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("herdr-event api_connect ts=1 conns=1\n"
                    "herdr-event api_connect ts=2 conns=2\n"
                    "herdr-event api_connect ts=3 conns=1\n"
                    "herdr-event api_denied ts=4 method=agent.list code=not_available\n"
                    "herdr-event api_denied ts=5 method=nope code=unknown_method\n"
                    "herdr-event api_denied ts=6 method=agent.get code=not_available\n"
                    'herdr-event api_error ts=7 method=pane.read code=timeout msg="slow pane"\n')
            f.flush()
            got = json.loads(run(f.name, "--json").stdout)
            out = run(f.name).stdout.splitlines()
        self.assertEqual(got["api"], {
            "connects": 3, "conns_max": 2,
            "denied": {"not_available": 2, "unknown_method": 1},
            "errors": {"timeout": 1}})
        self.assertIn("api: connects 3, conns_max 2, denied not_available 2, unknown_method 1, "
                      "errors timeout 1", out)

    def test_api_section_empty(self):
        got = json.loads(run(FIXTURE, "--json").stdout)
        self.assertEqual(got["api"], {"connects": 0, "conns_max": 0, "denied": {}, "errors": {}})
        self.assertIn("api: connects 0, conns_max 0, denied none, errors none", run(FIXTURE).stdout)

    def test_clients_section(self):
        with tempfile.NamedTemporaryFile("w", suffix=".log") as f:
            f.write("herdr-event client_attach ts=1 id=aabbccdd kind=term target=session cols=80 rows=24\n"
                    "herdr-event client_attach ts=2 id=11223344 kind=term target=session cols=80 rows=24\n"
                    "herdr-event client_detach ts=3 id=aabbccdd reason=grace_expired\n"
                    "herdr-event client_detach ts=4 id=11223344 reason=session_ended\n"
                    "herdr-event client_detach ts=5 id=11223344 reason=grace_expired\n"
                    "herdr-event client_reconnect ts=6 id=aabbccdd away_ms=120\n"
                    "herdr-event client_reconnect ts=7 id=aabbccdd away_ms=900\n"
                    'herdr-event client_refused ts=8 reason="bad version"\n'
                    "herdr-event client_held ts=9 id=aabbccdd carried=true\n"
                    "herdr-event client_held ts=10 id=11223344 carried=false\n"
                    "herdr-event client_held ts=11 id=55667788 carried=true\n"
                    "herdr-event client_handoff_freeze ts=12 conns=3\n")
            f.flush()
            got = json.loads(run(f.name, "--json").stdout)
            out = run(f.name).stdout.splitlines()
        self.assertEqual(got["clients"], {
            "attaches": 2, "detaches": {"grace_expired": 2, "session_ended": 1},
            "reconnects": 2, "reconnect_ms_max": 900, "refused": {"bad version": 1},
            "held": 3, "held_carried": 2, "held_not_carried": 1, "freezes": 1})
        self.assertEqual(got["session_losses"], 0)
        self.assertIn("clients: attaches 2, detaches grace_expired 2, session_ended 1, "
                      "reconnects 2, reconnect_ms_max 900, refused bad version 1, "
                      "held 3 (carried 2, not carried 1), freezes 1", out)

    def test_clients_section_empty(self):
        got = json.loads(run(FIXTURE, "--json").stdout)["clients"]
        self.assertEqual(got["attaches"], 0)
        self.assertIsNone(got["reconnect_ms_max"])
        self.assertIn("clients: attaches 0, detaches none, reconnects 0, reconnect_ms_max n/a, "
                      "refused none, held 0 (carried 0, not carried 0), freezes 0",
                      run(FIXTURE).stdout)

    def test_malformed_and_plain_lines(self):
        self.assertIsNone(log_summary.parse_line("just a log line"))
        self.assertIs(log_summary.parse_line("herdr-event x ts=abc"), False)
        self.assertIs(log_summary.parse_line('herdr-event x ts=1 a="unterminated'), False)


LIVE = os.path.dirname(HERE)
# a launch of bin/herdr-live on a non-comment line: the path followed by a quote, space or
# end of line (sh, exs), or os.path.join(..., "bin", "herdr-live") (python)
LAUNCH = re.compile(r"""bin/herdr-live(['"]|\s|$)""" + r'|"bin", "herdr-live"')


def launchers():
    for top in ("scripts", "bench"):
        for d, _dirs, files in os.walk(os.path.join(LIVE, top)):
            for name in files:
                path = os.path.join(d, name)
                if path == os.path.abspath(__file__) or not name.endswith((".sh", ".py", ".exs")):
                    continue
                with open(path, encoding="utf-8", errors="replace") as f:
                    text = f.read()
                code = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
                if any(LAUNCH.search(l) for l in code):
                    yield os.path.relpath(path, LIVE), "\n".join(code)


class LaunchIsolationTest(unittest.TestCase):
    """Every scripted launch keeps its session file away from the human's (M8)."""

    def test_every_launch_sets_a_state_dir(self):
        found = dict(launchers())
        for known in ("scripts/launcher_smoke.sh", "scripts/attached_smoke.sh",
                      "scripts/tty_harness.py", "bench/handoff/driver.exs", "bench/gate/glass.py"):
            self.assertIn(known, found, "launch detection missed a known launcher")
        missing = sorted(p for p, code in found.items() if "HERDR_LIVE_STATE_DIR" not in code)
        self.assertEqual(missing, [], "these launch bin/herdr-live without HERDR_LIVE_STATE_DIR")


if __name__ == "__main__":
    unittest.main()
