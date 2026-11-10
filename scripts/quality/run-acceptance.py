#!/usr/bin/env python3
"""Captures reproducible evidence for Pippa's five acceptance tasks.

This is an evidence collector, not a grader. It runs the configured `Pippa --ask` / `Pippa --make-pdf` commands once
each, records exit code, elapsed time, a status and the raw transcripts, and leaves the quality verdict to a person.
Every report lists all five tasks. Without --run it only lists the plan: nothing is executed, so no prompt is sent
and no calendar event is written.

MANIFEST (--manifest FILE, JSON):
  {
    "app": "/path/to/Pippa.app/Contents/MacOS/Pippa",      optional, --app overrides it
    "cases": [
      {"id": 1, "argv": ["--ask", "<your question, passed literally>"]},
      {"id": 5, "argv": ["--make-pdf", "/path/photo 1.jpg", "/path/photo 2.jpg"]}
    ]
  }
  `argv` is the argument list after the binary. It goes to subprocess as an argv list, never through a shell, so
  spaces, quotes and `$()` stay literal. Ids are 1..5 (the tasks in docs/pippa-next-architecture.md#acceptance).
  A task without a manifest entry is reported as not_run. Questions and files are yours to choose; none are built in.

REPORT (report.json in --out, mode 0600; transcripts case-N.stdout.txt / case-N.stderr.txt, mode 0600, in a new
directory with mode 0700; an existing --out is refused). Top level: mode ("plan" or "run"), app, run_label (free text
you pass with --run-label; the runner does not know whether the model was cold or warm), timeout_seconds, cases.
Per case: id, title, criteria, status, reason, exit_code, elapsed_seconds, command, stdout_path, stderr_path,
marker, evidence, review ("needs_review" always) and review_notes.
  status: not_run (unselected, no config, or plan mode) | timed_out | failed | needs_access | needs_input | completed.
  status describes the process only. completed is not a pass: every case needs a person to check the answer, source
  and card against `criteria`.
  `--ask` may print a standalone line `PIPPA_ASK_RESULT {"status":"completed|needs_access|needs_input|failed"}`.
  It is used when present and valid. Missing, malformed or duplicate markers, or an exit code that contradicts the
  marker, give failed. An older --ask with no marker is failed with evidence "no_marker". A timeout overrides any marker. --make-pdf has no marker.
  A timeout stops the child's own process group (SIGTERM, then SIGKILL) and keeps the partial output. A child that
  deliberately leaves its session is not reached.
The transcripts may contain private content. The summary printed here never shows them. Nothing is uploaded.

Each selected case runs exactly once per invocation. Task 3 creates a calendar event: do not rerun it for timings.
"""
import argparse
import json
import math
import os
import pathlib
import signal
import subprocess
import sys
import time

MARKER_PREFIX = "PIPPA_ASK_RESULT "
MARKER_STATUSES = ("completed", "needs_access", "needs_input", "failed")
GRACE_SECONDS = 2

TASKS = {
    1: ("Find the current file in the iCloud folder brain",
        "Names ETF-Portfolio.md as the current file.",
        "Check the named file and that the source can be opened."),
    2: ("Evaluate the PDF attachments of the last three payment-receipt mails",
        "Reads the PDFs and gives the totals.",
        "Check the totals against the PDFs; source fidelity is not graded here."),
    3: ("Put a dentist appointment on Tuesday at 10",
        "A calendar card with Undo.",
        "Needs actual card and Undo proof in the app UI; the CLI output cannot show it. Creates a calendar event."),
    4: ("Letter PDF: until when must I answer?",
        "The deadline with the quoted sentence; no date computed from the letter date.",
        "Needs the quoted sentence and no invented deadline."),
    5: ("Five photos, one PDF",
        "A PDF card, without the model.",
        "Check the actual PDF and card; the CLI prints only a card description."),
}


def load_manifest(path):
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("cases", []), list):
        raise ValueError("manifest must be an object with a cases array")
    app = data.get("app")
    if app is not None and (not isinstance(app, str) or not app.strip() or "\x00" in app):
        raise ValueError("app must be a non-empty binary path")
    cases = {}
    for entry in data.get("cases", []):
        if not isinstance(entry, dict):
            raise ValueError("each case must be an object")
        case_id, argv = entry.get("id"), entry.get("argv")
        if type(case_id) is not int or case_id not in TASKS:
            raise ValueError(f"case id {case_id!r} is not 1..5")
        if case_id in cases:
            raise ValueError(f"case id {case_id} appears twice")
        if not (isinstance(argv, list) and argv and all(isinstance(a, str) and "\x00" not in a for a in argv)):
            raise ValueError(f"case {case_id}: argv must be a non-empty list of strings")
        if argv[0] not in ("--ask", "--make-pdf") or len(argv) < 2 or not argv[1].strip():
            raise ValueError(f"case {case_id}: expected --ask QUESTION or --make-pdf FILE ...")
        cases[case_id] = argv
    return data.get("app"), cases


def parse_marker(stdout_text):
    """Returns (status or None, evidence). Only whole stdout lines starting with the prefix count."""
    lines = [l for l in stdout_text.splitlines() if l.startswith(MARKER_PREFIX)]
    if not lines:
        return None, "no_marker"
    if len(lines) > 1:
        return None, "marker_duplicate"
    try:
        status = json.loads(lines[0][len(MARKER_PREFIX):]).get("status")
    except (ValueError, AttributeError):
        return None, "marker_malformed"
    return (status, "marker_ok") if status in MARKER_STATUSES else (None, "marker_malformed")


def classify(argv, exit_code, stdout_text):
    """Process outcome only. Returns (status, reason, marker, evidence)."""
    if argv[0] != "--ask":
        ok = exit_code == 0
        return ("completed" if ok else "failed"), f"exit code {exit_code}; --make-pdf prints no marker", None, "no_marker_expected"
    marker, evidence = parse_marker(stdout_text)
    if evidence in ("marker_duplicate", "marker_malformed"):
        return "failed", evidence, None, evidence
    if marker is None:
        if exit_code == 0:
            return "failed", "exit 0 without a result marker: completion unconfirmed", None, "no_marker"
        return "failed", f"exit code {exit_code}, no marker", None, "no_marker"
    if marker == "completed" and exit_code == 0:
        return "completed", "marker completed, exit 0", marker, evidence
    if marker in ("needs_access", "needs_input") and exit_code != 0:
        return marker, f"marker {marker}, exit code {exit_code}", marker, evidence
    if marker == "failed" and exit_code != 0:
        return "failed", f"marker failed, exit code {exit_code}", marker, evidence
    return "failed", f"marker {marker} contradicts exit code {exit_code}", marker, "marker_exit_mismatch"


def run_child(command, stdout_path, stderr_path, timeout):
    """Runs one command in its own session with output going straight to files. Returns (exit, timed_out, seconds)."""
    start = time.monotonic()
    timed_out = False
    with open_private(stdout_path) as out, open_private(stderr_path) as err:
        try:
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                    start_new_session=True)
        except OSError as error:
            err.write(f"runner could not start the command: {error}\n".encode())
            return None, False, time.monotonic() - start
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # The leader is not reaped yet, so its process group id cannot belong to anyone else.
            for sig, wait in ((signal.SIGTERM, GRACE_SECONDS), (signal.SIGKILL, None)):
                try:
                    os.killpg(proc.pid, sig)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=wait)
                    if sig == signal.SIGTERM:
                        # Leader exited on TERM; make sure no descendant outlived it.
                        try:
                            os.killpg(proc.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    break
                except subprocess.TimeoutExpired:
                    continue
    return proc.returncode, timed_out, time.monotonic() - start


def open_private(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb")


def build_report(args, app, configured):
    selected = set(args.only) if args.only else set(TASKS)
    cases = []
    for case_id, (title, criteria, notes) in TASKS.items():
        case = {"id": case_id, "title": title, "criteria": criteria, "status": "not_run", "reason": None,
                "exit_code": None, "elapsed_seconds": None, "command": None, "stdout_path": None,
                "stderr_path": None, "marker": None, "evidence": None, "review": "needs_review",
                "review_notes": notes}
        argv = configured.get(case_id)
        if case_id not in selected:
            case["reason"] = "not selected"
        elif argv is None:
            case["reason"] = "no argv configured in the manifest"
        elif not app:
            case["reason"] = "no app binary configured"
        else:
            case["command"] = [app, *argv]
            if not args.run:
                case["reason"] = "plan only; pass --run to execute"
            else:
                stdout_path = os.path.join(args.out, f"case-{case_id}.stdout.txt")
                stderr_path = os.path.join(args.out, f"case-{case_id}.stderr.txt")
                code, timed_out, seconds = run_child(case["command"], stdout_path, stderr_path, args.timeout)
                case.update(exit_code=code, elapsed_seconds=round(seconds, 2),
                            stdout_path=stdout_path, stderr_path=stderr_path)
                if code is None and not timed_out:
                    case.update(status="failed", reason="could not start the command", evidence="not_started")
                elif timed_out:
                    case.update(status="timed_out", reason=f"stopped after {args.timeout}s; partial output kept",
                                evidence="timeout")
                else:
                    text = pathlib.Path(stdout_path).read_text(encoding="utf-8", errors="replace")
                    status, reason, marker, evidence = classify(argv, code, text)
                    case.update(status=status, reason=reason, marker=marker, evidence=evidence)
        cases.append(case)
    return {"mode": "run" if args.run else "plan", "app": app, "run_label": args.run_label,
            "timeout_seconds": args.timeout, "cases": cases}


def print_summary(report, report_path):
    print(f"mode: {report['mode']}   app: {report['app'] or '(not configured)'}   run label: {report['run_label'] or '-'}")
    print(f"{'task':<5}{'status':<13}{'exit':<6}{'seconds':<9}{'review':<13}reason")
    for c in report["cases"]:
        exit_code = "-" if c["exit_code"] is None else c["exit_code"]
        seconds = "-" if c["elapsed_seconds"] is None else c["elapsed_seconds"]
        print(f"{c['id']:<5}{c['status']:<13}{exit_code!s:<6}{seconds!s:<9}{c['review']:<13}{c['reason']}")
    print("status is the process outcome only; every case still needs review, completed is not a pass.")
    if report_path:
        print(f"report: {report_path}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", help="JSON file with the app path and the argv per case (see above)")
    parser.add_argument("--app", help="Pippa binary; overrides the manifest")
    parser.add_argument("--only", type=lambda v: [int(x) for x in v.split(",")], metavar="1,3",
                        help="run/plan only these task ids")
    parser.add_argument("--run", action="store_true", help="execute the selected configured cases (needs --out)")
    parser.add_argument("--out", help="new directory for report and transcripts; refused if it exists")
    parser.add_argument("--timeout", type=float, default=600, help="seconds per case (default 600)")
    parser.add_argument("--run-label", help="free text recorded in the report, e.g. 'after model restart'")
    args = parser.parse_args(argv)

    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    if args.run and not args.out:
        parser.error("--run needs --out")
    if args.only and not set(args.only) <= set(TASKS):
        parser.error("--only takes task ids 1..5")
    app, configured = None, {}
    if args.manifest:
        try:
            app, configured = load_manifest(args.manifest)
        except (OSError, ValueError) as error:
            parser.error(f"manifest: {error}")
    app = args.app or app
    if args.out:
        try:
            os.mkdir(args.out, 0o700)
        except OSError as error:
            parser.error(f"--out: {error}")

    report = build_report(args, app, configured)
    report_path = None
    if args.out:
        report_path = os.path.join(args.out, "report.json")
        with open_private(report_path) as handle:
            handle.write(json.dumps(report, indent=2).encode() + b"\n")
    print_summary(report, report_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
