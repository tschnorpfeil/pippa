"""Tests the acceptance runner with fake executables. These are not live acceptance runs of Pippa."""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts/quality/run-acceptance.py"

# A fake "Pippa": the first argument picks the behavior, the rest is recorded literally.
FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
log = os.environ.get("FAKE_LOG")
if log:
    open(log, "a").write(json.dumps(args) + "\n")
mode = args[1] if len(args) > 1 else ""
if args[0] == "--make-pdf":
    print("pdf ready"); sys.exit(0)
def marker(s): print('PIPPA_ASK_RESULT ' + json.dumps({"status": s}))
if mode == "ok": print("answer"); marker("completed")
elif mode == "legacy": print("answer")
elif mode == "access": print("no"); marker("needs_access"); sys.exit(2)
elif mode == "input": marker("needs_input"); sys.exit(3)
elif mode == "wrongaccess": marker("needs_access"); sys.exit(1)
elif mode == "wronginput": marker("needs_input"); sys.exit(2)
elif mode == "fail": print("boom"); marker("failed"); sys.exit(1)
elif mode == "nonzero": print("boom"); sys.exit(7)
elif mode == "bad": print("PIPPA_ASK_RESULT {nope")
elif mode == "dup": marker("completed"); marker("failed")
elif mode == "notfinal": marker("completed"); print("ordinary output after result")
elif mode == "badfinal": marker("completed"); print("PIPPA_ASK_RESULT")
elif mode == "unicode": print('answer\u2028PIPPA_ASK_RESULT {"status":"completed"}')
elif mode == "carriage": print('answer\rPIPPA_ASK_RESULT {"status":"completed"}')
elif mode == "mismatch": marker("completed"); sys.exit(2)
elif mode == "hang":
    marker("completed"); print("partial", flush=True)
    # Foundation Process also creates a new process group in the same session.
    g = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], preexec_fn=os.setpgrp)
    open(os.environ["GRANDCHILD_PID"], "w").write(str(g.pid))
    time.sleep(60)
'''


class AcceptanceRunner(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.app = self.tmp / "fake-pippa"
        self.app.write_text(FAKE)
        self.app.chmod(0o755)
        self.log = self.tmp / "calls.log"
        self.env = {**os.environ, "FAKE_LOG": str(self.log), "GRANDCHILD_PID": str(self.tmp / "gc.pid")}

    def manifest(self, cases, app=True):
        data = {"cases": [{"id": i, "argv": a} for i, a in cases.items()]}
        if app:
            data["app"] = str(self.app)
        path = self.tmp / "manifest.json"
        path.write_text(json.dumps(data))
        return str(path)

    def runner(self, *args):
        return subprocess.run([sys.executable, str(RUNNER), *args], capture_output=True, text=True,
                              env=self.env, check=False, timeout=60, cwd=self.tmp)

    def run_cases(self, cases, *extra):
        out = str(self.tmp / "out")
        result = self.runner("--manifest", self.manifest(cases), "--run", "--out", out, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((pathlib.Path(out) / "report.json").read_text())
        return result, report, {c["id"]: c for c in report["cases"]}

    def test_statuses_and_all_five_tasks_always_reported(self):
        _, report, by_id = self.run_cases({
            1: ["--ask", "ok"], 2: ["--ask", "access"], 3: ["--ask", "input"], 4: ["--ask", "nonzero"],
            5: ["--make-pdf", "a.jpg"]}, "--run-label", "label from caller")
        self.assertEqual([c["id"] for c in report["cases"]], [1, 2, 3, 4, 5])
        self.assertEqual(report["run_label"], "label from caller")
        self.assertEqual([by_id[i]["status"] for i in range(1, 6)],
                         ["completed", "needs_access", "needs_input", "failed", "completed"])
        self.assertTrue(all(c["review"] == "needs_review" for c in report["cases"]))
        self.assertIn("quote", by_id[4]["review_notes"])
        self.assertIn("Undo", by_id[3]["review_notes"])
        self.assertEqual(by_id[2]["exit_code"], 2)

    def test_marker_problems_never_become_success(self):
        _, _, by_id = self.run_cases({1: ["--ask", "legacy"], 2: ["--ask", "bad"], 3: ["--ask", "dup"],
                                      4: ["--ask", "mismatch"], 5: ["--ask", "fail"]})
        self.assertEqual(by_id[1]["status"], "failed")
        self.assertEqual(by_id[1]["evidence"], "no_marker")
        self.assertEqual(by_id[2]["evidence"], "marker_malformed")
        self.assertEqual(by_id[3]["evidence"], "marker_duplicate")
        self.assertEqual(by_id[4]["evidence"], "marker_exit_mismatch")
        self.assertEqual([by_id[i]["status"] for i in (2, 3, 4, 5)], ["failed"] * 4)

    def test_marker_must_be_the_final_lf_delimited_line(self):
        _, _, by_id = self.run_cases({1: ["--ask", "notfinal"], 2: ["--ask", "badfinal"],
                                      3: ["--ask", "unicode"], 4: ["--ask", "carriage"]})
        self.assertEqual([by_id[i]["status"] for i in (1, 2, 3, 4)], ["failed"] * 4)

    def test_access_and_input_markers_require_their_documented_exit_codes(self):
        _, _, by_id = self.run_cases({1: ["--ask", "wrongaccess"], 2: ["--ask", "wronginput"]})
        for case_id in (1, 2):
            self.assertEqual(by_id[case_id]["status"], "failed")
            self.assertEqual(by_id[case_id]["evidence"], "marker_exit_mismatch")

    def test_missing_and_unselected_cases_are_explicit_and_not_run(self):
        out = str(self.tmp / "out")
        result = self.runner("--manifest", self.manifest({1: ["--ask", "ok"], 2: ["--ask", "ok"]}),
                             "--run", "--out", out, "--only", "1,3")
        self.assertEqual(result.returncode, 0, result.stderr)
        by_id = {c["id"]: c for c in json.loads((pathlib.Path(out) / "report.json").read_text())["cases"]}
        self.assertEqual(by_id[1]["status"], "completed")
        self.assertEqual(by_id[2]["reason"], "not selected")
        self.assertIn("no argv", by_id[3]["reason"])
        self.assertTrue(all(by_id[i]["status"] == "not_run" for i in (2, 3, 4, 5)))
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_no_app_is_explicit(self):
        result = self.runner("--manifest", self.manifest({1: ["--ask", "ok"]}, app=False))
        self.assertIn("no app binary configured", result.stdout)

    def test_plan_is_default_and_runs_nothing(self):
        result = self.runner("--manifest", self.manifest({1: ["--ask", "ok"]}))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mode: plan", result.stdout)
        self.assertFalse(self.log.exists())
        self.assertEqual(self.runner("--manifest", self.manifest({}), "--run").returncode, 2)

    def test_arguments_are_literal_and_each_case_runs_once(self):
        nasty = ["--ask", "ok", "$(touch pwned); `id` ; rm -rf * 'q' \"d\" a b", "*"]
        self.run_cases({1: nasty})
        calls = [json.loads(l) for l in self.log.read_text().splitlines()]
        self.assertEqual(calls, [nasty])
        self.assertFalse((self.tmp / "pwned").exists())

    def test_timeout_keeps_partial_output_and_kills_the_owned_tree(self):
        started = time.monotonic()
        _, _, by_id = self.run_cases({1: ["--ask", "hang"]}, "--timeout", "1")
        self.assertLess(time.monotonic() - started, 15)
        case = by_id[1]
        self.assertEqual(case["status"], "timed_out")  # beats the partial completed marker
        self.assertIn("partial", pathlib.Path(case["stdout_path"]).read_text())
        pid = int((self.tmp / "gc.pid").read_text())
        for _ in range(50):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            os.kill(pid, 9)  # only the grandchild this test's fake created
            self.fail("grandchild survived the timeout")

    def test_output_is_private_and_never_overwritten(self):
        out = self.tmp / "out"
        _, report, by_id = self.run_cases({1: ["--ask", "ok"]})
        modes = {p.name: stat.S_IMODE(p.stat().st_mode) for p in out.iterdir()}
        self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o700)
        self.assertTrue(modes and all(m == 0o600 for m in modes.values()), modes)
        self.assertNotIn("answer", subprocess.run([sys.executable, str(RUNNER), "--manifest",
                         self.manifest({}), "--out", str(self.tmp / "o2")], capture_output=True,
                         text=True).stdout)
        again = self.runner("--manifest", self.manifest({}), "--out", str(out))
        self.assertEqual(again.returncode, 2)
        self.assertIn("exists", again.stderr)

    def test_invalid_inputs_are_rejected_before_creating_output_or_launching(self):
        invalid_manifests = [[], {"cases": None}, {"cases": [None]},
                             {"cases": [{"id": 1.0, "argv": ["--ask", "ok"]}]},
                             {"app": 7, "cases": []},
                             {"cases": [{"id": 1, "argv": ["--setup"]}]},
                             {"cases": [{"id": 1, "argv": ["--ask"]}]},
                             {"cases": [{"id": 5, "argv": ["--make-pdf"]}]},
                             {"cases": [{"id": 1, "argv": ["--ask", "bad\x00text"]}]}]
        for index, data in enumerate(invalid_manifests):
            with self.subTest(data=data):
                path = self.tmp / "invalid.json"
                path.write_text(json.dumps(data))
                out = self.tmp / f"invalid-out-{index}"
                result = self.runner("--manifest", str(path), "--out", str(out))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(out.exists())
        for timeout in ("nan", "inf", "-inf", "0", "-1"):
            with self.subTest(timeout=timeout):
                out = self.tmp / f"invalid-timeout-{timeout}"
                result = self.runner("--timeout=" + timeout, "--out", str(out))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertFalse(out.exists())
        self.assertFalse(self.log.exists())

    def test_help_documents_manifest_and_report(self):
        text = self.runner("--help").stdout
        for word in ("MANIFEST", "REPORT", "argv", "PIPPA_ASK_RESULT", "needs_review"):
            self.assertIn(word, text)


if __name__ == "__main__":
    unittest.main()
