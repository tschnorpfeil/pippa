import importlib.util
import json
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("native_acceptance", ROOT / "scripts/check-native-acceptance.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
IDENTITY = ("11111111-1111-4111-8111-111111111111", "native-fixture", "target-fixture")


def report(phase, pid=100):
    return dict(schema=1, evidence=probe.EVIDENCE, phase=phase, status="pass", pid=pid,
                operationID=IDENTITY[0], nativeID=IDENTITY[1], targetID=IDENTITY[2], revision=3,
                recovered=phase == "recover", nativeWrites=1 if phase == "create" else 0, reminderPermission="granted")


class NativeAcceptanceChecks(unittest.TestCase):
    def test_reports_require_identity_process_and_real_write_counts(self):
        self.assertEqual(probe.validate_report(report("create"), "create"), IDENTITY)
        for changes in ({"status": "blocked"}, {"evidence": "mock"}, {"nativeWrites": 1},
                        {"nativeID": "another"}, {"revision": 2}, {"pid": 0}, {"recovered": None}, {"reminderPermission": "mocked"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                probe.validate_report(report("readback") | changes, "readback", IDENTITY)
        with self.assertRaises(ValueError):
            probe.validate_report(report("recover") | {"recovered": False}, "recover")
        self.assertEqual(probe.validate_report(report("cleanup") | {"revision": 2}, "cleanup"), IDENTITY)

    def test_failed_readback_still_cleans_only_proven_synthetic_save(self):
        phases = []
        def invoke(binary, phase, directory, log, timeout):
            phases.append(phase)
            value = report(phase, 100 + len(phases))
            if phase == "create":
                (directory / "after-save.json").write_text("{}")
            if phase == "readback":
                value.update(status="fail", detail="Exact lookup unavailable")
            (directory / f"{phase}.json").write_text(json.dumps(value))
            return 1 if phase == "readback" else 0
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", invoke):
            result = probe.run_case(Path("unused"), Path(folder) / "case", False, 20)
        self.assertEqual(phases, ["create", "readback", "cleanup"])
        self.assertEqual(result["status"], "fail")
        self.assertIn("Exact lookup unavailable", result["error"])

    def test_no_cleanup_without_native_save_evidence(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", return_value=3) as invoke:
            result = probe.run_case(Path("unused"), Path(folder) / "case", False, 20)
        self.assertEqual(invoke.call_count, 1)
        self.assertEqual(result["status"], "fail")

    def test_interruption_must_be_exact_signal_with_proof(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", return_value=0):
            result = probe.run_case(Path("unused"), Path(folder) / "case", True, 20)
        self.assertEqual(result["status"], "fail")
        self.assertIn("proven native save", result["error"])

    def test_runner_refuses_ordinary_app_before_any_process_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Pippa.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.github.tschnorpfeil.pippa"}))
            with patch.object(probe.subprocess, "run") as run, self.assertRaises(ValueError):
                probe.verify_candidate(app)
            run.assert_not_called()

    def test_timeout_kills_only_its_own_started_process_group(self):
        from unittest.mock import Mock
        child = Mock(pid=5678)
        child.wait.side_effect = [subprocess.TimeoutExpired("fixture", 10), -signal.SIGKILL]
        with tempfile.TemporaryDirectory() as folder, patch.object(probe.subprocess, "Popen", return_value=child) as popen, patch.object(probe.os, "killpg") as kill:
            with self.assertRaises(TimeoutError):
                probe.invoke(Path("candidate"), "readback", Path(folder), Path(folder) / "log", 10)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        kill.assert_called_once_with(5678, signal.SIGKILL)

    def test_unsafe_build_combinations_fail_before_build_or_signing(self):
        for extra in ({"PIPPA_REQUIRE_DISTRIBUTION": "1"}, {"PIPPA_SKIP_BUILD": "1"}, {"PIPPA_SIGN_IDENTITY": "-"}):
            env = os.environ | {"PIPPA_NATIVE_ACCEPTANCE": "1", "PIPPA_SIGN_IDENTITY": "Developer ID Application: Fixture (TEST)",
                                "PIPPA_REQUIRE_DISTRIBUTION": "0", "PIPPA_SKIP_BUILD": "0"} | extra
            result = subprocess.run(["bash", str(ROOT / "scripts/build-app.sh")], env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("native acceptance requires", result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
