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


def invoke(binary, phase, directory, log, timeout):
    with log.open("wb") as output:
        process = subprocess.Popen([str(binary), "--native-acceptance", phase, str(directory)],
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise TimeoutError(f"{phase}: stopped its own probe process after {timeout} seconds")


def run_case(binary, directory, interrupted, timeout):
    directory.mkdir(mode=0o700)
    reports, identity, error = [], None, None
    phases = ["interrupt", "recover", "readback", "deduplicate"] if interrupted else ["create", "readback", "deduplicate"]
    try:
        for phase in phases:
            code = invoke(binary, phase, directory, directory.parent / f"{directory.name}-{phase}.log", timeout)
            if phase == "interrupt":
                if code != -signal.SIGKILL or not (directory / "after-save.json").is_file():
                    raise ValueError("Interruption did not occur after a proven native save")
                proof = load(directory / "after-save.json")
                identity = (proof["operationID"], proof["item"]["identifier"], proof["targetID"])
                reports.append({"phase": phase, "status": "interrupted-after-native-save", "pid": proof["pid"]})
                continue
            report = load(directory / f"{phase}.json")
            if code != 0:
                raise ValueError(f"{phase}: {report.get('status')}: {report.get('detail')}")
            identity = validate_report(report, phase, identity)
            reports.append(report)
    except Exception as failure:
        error = str(failure)
    finally:
        # Only a proven native save enables cleanup; the product rechecks exact identity and original fingerprint.
        if (directory / "after-save.json").is_file():
            try:
                code = invoke(binary, "cleanup", directory, directory.parent / f"{directory.name}-cleanup.log", timeout)
                report = load(directory / "cleanup.json")
                if code != 0:
                    raise ValueError(report.get("detail", "cleanup failed"))
                validate_report(report, "cleanup", identity)
                reports.append(report)
            except Exception as failure:
                error = f"{error + '; ' if error else ''}cleanup unresolved: {failure}"
    pids = [r["pid"] for r in reports]
    if len(pids) != len(set(pids)):
        error = "Process identity was reused; fresh-process evidence is inconclusive"
    return {"case": directory.name, "status": "fail" if error else "pass", "error": error, "phases": reports}


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
                "limits": ["Instrumented candidate, not shipped-build UI acceptance", "Existing permission only; no fresh TCC allow/deny",
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
