#!/usr/bin/env python3
"""Fixed synthetic reminder acceptance in an instrumented, Developer-ID-signed Pippa.

Without --run-native this only verifies the candidate and prints the plan. Native writes
must be explicitly requested. This does not certify shipped UI, fresh TCC or RAM tiers.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time
import uuid

EVIDENCE = "instrumented-signed-native-integration"


def load(path):
    return json.loads(path.read_text())


def validate_report(value, phase, expected_identity=None):
    if value.get("schema") != 1 or value.get("evidence") != EVIDENCE or value.get("phase") != phase:
        raise ValueError("Unexpected acceptance report schema, evidence or phase")
    if value.get("status") != "pass":
        raise ValueError(f"{phase}: {value.get('status', 'missing status')}: {value.get('detail', '')}")
    if type(value.get("pid")) is not int or value["pid"] <= 0:
        raise ValueError("Missing process identity")
    identity = tuple(value.get(k) for k in ("operationID", "nativeID", "targetID"))
    if not all(isinstance(v, str) and v for v in identity):
        raise ValueError("Missing exact native identity")
    uuid.UUID(identity[0])
    if expected_identity is not None and identity != expected_identity:
        raise ValueError("Native identity changed between processes")
    if value.get("nativeWrites") != (1 if phase == "create" else 0):
        raise ValueError("Unexpected native write count")
    if value.get("reminderPermission") != "granted":
        raise ValueError("Missing actual granted Reminders permission")
    if type(value.get("revision")) is not int or value["revision"] < (0 if phase == "cleanup" else 3):
        raise ValueError("Missing completed journal revision")
    if type(value.get("recovered")) is not bool or (phase == "recover" and not value["recovered"]):
        raise ValueError("Missing recovery evidence")
    return identity


def verify_candidate(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("PippaNativeAcceptance") is not True or info.get("CFBundleIdentifier") != "io.github.tschnorpfeil.pippa":
        raise ValueError("Use the marked native-acceptance candidate, never the installed/shipped app")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, capture_output=True, timeout=60)
    signature = subprocess.run(["codesign", "-dvv", str(app)], check=True, capture_output=True, text=True, timeout=10).stderr
    if "Authority=Developer ID Application:" not in signature:
        raise ValueError("Candidate must have a Developer ID signature")
    binary = app / "Contents/MacOS/Pippa"
    source = load(app / "Contents/Resources/native-acceptance-source.json")
    if source["before"]["appSourceSHA256"] != source["after"]["appSourceSHA256"] or source["before"]["commit"] != source["after"]["commit"]:
        raise ValueError("App source changed during the candidate build; rebuild it")
    return binary, {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                    "bundleID": info["CFBundleIdentifier"],
                    "source": source,
                    "teamID": next((s.split("=", 1)[1] for s in signature.splitlines() if s.startswith("TeamIdentifier=")), None)}


def source_snapshot():
    root = Path(__file__).resolve().parents[1]
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args])
    patch = hashlib.sha256(git("diff", "--binary", "HEAD"))
    app_source = hashlib.sha256()
    paths = sorted(set(git("ls-files", "-c", "-o", "--exclude-standard", "-z").split(b"\0")) - {b""})
    untracked = set(git("ls-files", "-o", "--exclude-standard", "-z").split(b"\0"))
    for raw in paths:
        path = root / os.fsdecode(raw)
        digest = hashlib.sha256(path.read_bytes()).digest() if path.is_file() else b"missing"
        if raw in untracked:
            patch.update(raw + b"\0" + digest)
        if raw.startswith(b"app/"):
            app_source.update(raw + b"\0" + digest)
    return {"commit": git("rev-parse", "HEAD").decode().strip(), "dirty": bool(git("status", "--porcelain")),
            "diffSHA256": patch.hexdigest(), "appSourceSHA256": app_source.hexdigest()}


def process_identity(pid, expected_command):
    """Read only: PID start time plus the exact private launch token in argv prevent PID-reuse kills."""
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "command="],
                            capture_output=True, text=True, timeout=3)
    fields = result.stdout.strip().split(maxsplit=5)
    return " ".join(fields[:5]) if result.returncode == 0 and len(fields) == 6 and fields[5] == expected_command else None


def validate_start(value, phase, token):
    if value.get("phase") != phase or str(value.get("launchToken", "")).lower() != token or type(value.get("pid")) is not int or value["pid"] <= 0:
        raise ValueError("App process identity does not match the fresh launch token")
    return value["pid"]


def invoke(binary, phase, directory, log, timeout):
    # Launch the exact signed bundle through LaunchServices so TCC attributes access to Pippa.
    # open's status is not the app's exit status; app reports establish the phase result.
    token = str(uuid.uuid4())
    arguments = ["--native-acceptance", phase, str(directory), token]
    expected_command = " ".join([str(binary), *arguments])
    started = directory / f"{phase}-process.json"
    if started.exists():
        raise ValueError("A phase-start file already exists; refusing stale process evidence")
    with log.open("wb") as output:
        process = subprocess.Popen(["/usr/bin/open", "-n", "-W", "-o", str(log.with_suffix(".app-stdout.log")),
                                    "--stderr", str(log.with_suffix(".app-stderr.log")), str(binary.parents[2]), "--args", *arguments],
                                   stdout=output, stderr=subprocess.STDOUT)
        deadline, owned_pid, owned_start = time.monotonic() + timeout, None, None
        try:
            while process.poll() is None:
                if owned_start is None and started.is_file():
                    owned_pid = validate_start(load(started), phase, token)
                    try:
                        owned_start = process_identity(owned_pid, expected_command)
                    except (OSError, subprocess.TimeoutExpired):
                        pass  # Keep waiting; unavailable ownership evidence never authorizes a kill.
                if time.monotonic() >= deadline:
                    stopped = False
                    try:
                        same_process = owned_start is not None and process_identity(owned_pid, expected_command) == owned_start
                    except (OSError, subprocess.TimeoutExpired):
                        same_process = False
                    if same_process:
                        try:
                            os.kill(owned_pid, signal.SIGKILL)
                            stopped = True
                        except ProcessLookupError:
                            pass
                    raise TimeoutError(f"{phase}: deadline exceeded; owned app stopped: {stopped}")
                time.sleep(0.05)
            pid = validate_start(load(started), phase, token)
            if process.returncode != 0:
                raise ValueError(f"LaunchServices could not confirm app closure (status {process.returncode})")
            return {"appPID": pid, "launchToken": token, "observedAppExit": True, "launcherExitCode": process.returncode}
        finally:
            # This is only the open process we started, never a global app or process group.
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


def run_case(binary, directory, interrupted, timeout):
    directory.mkdir(mode=0o700)
    reports, identity, error, blocked = [], None, None, False
    phases = ["interrupt", "recover", "readback", "deduplicate"] if interrupted else ["create", "readback", "deduplicate"]
    try:
        for phase in phases:
            launch = invoke(binary, phase, directory, directory.parent / f"{directory.name}-{phase}.log", timeout)
            if phase == "interrupt":
                if not (directory / "after-save.json").is_file() or (directory / "interrupt.json").exists():
                    raise ValueError("Interruption did not occur after a proven native save")
                proof = load(directory / "after-save.json")
                if proof.get("interruptAfterSave") is not True or proof.get("pid") != launch["appPID"] or launch.get("observedAppExit") is not True:
                    raise ValueError("Missing after-save interruption intent and observed app process closure")
                identity = (proof["operationID"], proof["item"]["identifier"], proof["targetID"])
                reports.append({"phase": phase, "status": "process-loss-after-native-save", "pid": proof["pid"],
                                "launch": launch, "limit": "LaunchServices observed closure; app termination signal was not observed"})
                continue
            report = load(directory / f"{phase}.json")
            report["launch"] = launch
            reports.append(report)
            if report.get("pid") != launch["appPID"]:
                raise ValueError("Phase report and launched app process differ")
            if report.get("status") != "pass":
                blocked = report.get("status") == "blocked" and not (directory / "after-save.json").is_file()
                raise ValueError(f"{phase}: {report.get('status')}: {report.get('detail')}")
            identity = validate_report(report, phase, identity)
    except Exception as failure:
        error = str(failure)
    finally:
        # Only a proven native save enables cleanup; the product rechecks exact identity and original fingerprint.
        if (directory / "after-save.json").is_file():
            try:
                launch = invoke(binary, "cleanup", directory, directory.parent / f"{directory.name}-cleanup.log", timeout)
                report = load(directory / "cleanup.json")
                if report.get("status") != "pass" or report.get("pid") != launch["appPID"]:
                    raise ValueError(report.get("detail", "cleanup failed"))
                validate_report(report, "cleanup", identity)
                report["launch"] = launch
                reports.append(report)
            except Exception as failure:
                error = f"{error + '; ' if error else ''}cleanup unresolved: {failure}"
    pids = [r["pid"] for r in reports if type(r.get("pid")) is int]
    if len(pids) != len(set(pids)):
        error = "Process identity was reused; fresh-process evidence is inconclusive"
        blocked = False
    return {"case": directory.name, "status": "blocked" if blocked else "fail" if error else "pass", "error": error, "phases": reports}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=Path("dist/native-acceptance/Pippa.app"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--run-native", action="store_true", help="Create at most two synthetic reminders and remove only those unchanged entries")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--source-manifest", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.source_manifest:
        print(json.dumps(source_snapshot(), sort_keys=True))
        return 0
    if not 10 <= args.timeout <= 180:
        parser.error("--timeout must be between 10 and 180 seconds")
    binary, bundle = verify_candidate(args.app.resolve())
    if not args.run_native:
        print("Candidate verified. Plan: create → exit → readback → deduplicate → cleanup; after-save interruption → recover → readback → deduplicate → cleanup.")
        print("No native records were read or changed. Add --run-native --output NEW_DIRECTORY after review.")
        return 0
    if args.output is None:
        parser.error("--run-native requires a new --output directory")
    output = args.output.expanduser().resolve()
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    evidence = {"schema": 1, "evidence": EVIDENCE, "bundle": bundle,
                "os": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
                "physicalMemoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
                "launchMethod": "LaunchServices: exact signed bundle, open -n -W",
                "limits": ["Instrumented candidate, not shipped-build UI acceptance", "Existing permission only; no fresh TCC allow/deny",
                           "Process-loss evidence includes signed after-save intent and observed app closure; no kernel termination signal claim",
                           "No physical 8/16 GB claim", "No Mail or account synchronization acceptance", "No model, Pi transport or conversation UI exercised"], "cases": []}
    for name, interrupted in [("completed", False), ("interrupted", True)]:
        case = run_case(binary, output / name, interrupted, args.timeout)
        evidence["cases"].append(case)
        (output / "report.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"{name}: {case['status']}")
        if case["status"] != "pass":
            print(case["error"], file=sys.stderr)
            return 1
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(args.app.resolve())], check=True, capture_output=True, timeout=60)
    print(f"PASS: signed native integration process-boundary evidence: {output / 'report.json'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
