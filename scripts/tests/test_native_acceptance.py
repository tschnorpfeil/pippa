import importlib.util
import json
import os
import plistlib
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
import uuid
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


def launch(pid=100):
    return dict(appPID=pid, observedAppExit=True, launcherExitCode=0, launchToken=IDENTITY[0])


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
            return launch(value["pid"])
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", invoke):
            result = probe.run_case(Path("unused"), Path(folder) / "case", False, 20)
        self.assertEqual(phases, ["create", "readback", "cleanup"])
        self.assertEqual(result["status"], "fail")
        self.assertIn("Exact lookup unavailable", result["error"])

    def test_no_cleanup_without_native_save_evidence(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", return_value=launch()) as invoke:
            result = probe.run_case(Path("unused"), Path(folder) / "case", False, 20)
        self.assertEqual(invoke.call_count, 1)
        self.assertEqual(result["status"], "fail")

    def test_blocked_permission_is_preserved_without_cleanup(self):
        def invoke(binary, phase, directory, log, timeout):
            (directory / f"{phase}.json").write_text(json.dumps(report(phase) | {
                "status": "blocked", "detail": "Existing permission required", "nativeWrites": 0,
                "reminderPermission": "notDetermined"}))
            return launch()
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", side_effect=invoke) as call:
            result = probe.run_case(Path("unused"), Path(folder) / "case", False, 20)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(result["phases"][0]["reminderPermission"], "notDetermined")
        self.assertEqual(result["phases"][0]["nativeWrites"], 0)

    def test_interruption_requires_proof_and_observed_app_closure(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(probe, "invoke", return_value=launch()):
            result = probe.run_case(Path("unused"), Path(folder) / "case", True, 20)
        self.assertEqual(result["status"], "fail")
        self.assertIn("proven native save", result["error"])

    def test_process_loss_uses_app_proof_instead_of_launcher_signal_status(self):
        for intent in (True, False):
            with self.subTest(intent=intent), tempfile.TemporaryDirectory() as folder:
                calls=[]
                def invoke(binary, phase, directory, log, timeout):
                    calls.append(phase)
                    pid=100+len(calls)
                    if phase=='interrupt':
                        (directory/'after-save.json').write_text(json.dumps(dict(operationID=IDENTITY[0],
                            targetID=IDENTITY[2],item=dict(identifier=IDENTITY[1]),pid=pid,interruptAfterSave=intent)))
                    else:
                        (directory/f'{phase}.json').write_text(json.dumps(report(phase,pid)))
                    return launch(pid)  # open exits normally even when the app terminates itself.
                with patch.object(probe,'invoke',side_effect=invoke):
                    result=probe.run_case(Path('unused'),Path(folder)/'case',True,20)
                self.assertEqual(result['status'],'pass' if intent else 'fail')
                self.assertEqual(calls[-1],'cleanup')
                if intent:
                    self.assertEqual(result['phases'][0]['status'],'process-loss-after-native-save')
                    self.assertIn('not observed',result['phases'][0]['limit'])
                else:
                    self.assertIn('interruption intent',result['error'])

    def test_runner_refuses_ordinary_app_before_any_process_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Pippa.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "io.github.tschnorpfeil.pippa"}))
            with patch.object(probe.subprocess, "run") as run, self.assertRaises(ValueError):
                probe.verify_candidate(app)
            run.assert_not_called()

    def test_timeout_kills_only_exact_app_pid_token_and_unchanged_start(self):
        from unittest.mock import Mock
        for actual_start in ("same-start", "reused-pid", None):
            with self.subTest(actual_start=actual_start), tempfile.TemporaryDirectory() as folder:
                directory=Path(folder)
                child=Mock(returncode=0); child.poll.return_value=None
                def popen(*args, **kwargs):
                    (directory/'readback-process.json').write_text(json.dumps(dict(phase='readback',launchToken=IDENTITY[0],pid=5678)))
                    return child
                with patch.object(probe.subprocess,"Popen",side_effect=popen), patch.object(probe.uuid,"uuid4",return_value=uuid.UUID(IDENTITY[0])), \
                     patch.object(probe.time,"monotonic",side_effect=[0,11]), patch.object(probe,"process_identity",side_effect=['same-start',actual_start]), \
                     patch.object(probe.os,"kill") as kill:
                    with self.assertRaises(TimeoutError):
                        probe.invoke(Path('/candidate/Pippa.app/Contents/MacOS/Pippa'),'readback',directory,directory/'log',10)
                if actual_start=='same-start': kill.assert_called_once_with(5678,signal.SIGKILL)
                else: kill.assert_not_called()
                child.kill.assert_called_once()

    def test_launch_start_requires_exact_private_token(self):
        start=dict(phase='create',launchToken=IDENTITY[0],pid=100)
        self.assertEqual(probe.validate_start(start,'create',IDENTITY[0]),100)
        for changes in ({'pid':0},{'launchToken':str(uuid.uuid4())},{'phase':'cleanup'}):
            with self.subTest(changes=changes),self.assertRaises(ValueError):
                probe.validate_start(start|changes,'create',IDENTITY[0])

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
