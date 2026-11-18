#!/usr/bin/env python3
"""Run the normal chat and bundled Pi against a local provider. Terminal needs Accessibility access."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


class FixtureProvider(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        self.server.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        reply = {"id": "fixture", "object": "chat.completion.chunk", "created": 0, "model": "fixture",
                 "choices": [{"index": 0, "delta": {"role": "assistant", "content": "FIXTURE_OK"}, "finish_reason": "stop"}]}
        self.wfile.write(("data: " + json.dumps(reply) + "\n\ndata: [DONE]\n\n").encode())

    def log_message(self, *_):
        pass


def exercise(pid, helper, requests):
    def ax(*args):
        return subprocess.run([helper, str(pid), *args], capture_output=True, text=True, timeout=10)

    def wait(predicate, label):
        until = time.monotonic() + 25
        while time.monotonic() < until:
            if predicate():
                return
            time.sleep(0.15)
        raise AssertionError(f"Timed out waiting for {label}. Check Terminal's Accessibility access.\n{ax('tree').stdout}")

    def visible(label):
        wait(lambda: label in ax("tree").stdout, label)

    def press(label):
        wait(lambda: ax("press", label).returncode == 0, label)

    def edit(original, replacement):
        wait(lambda: ax("edit", original, replacement).returncode == 0, replacement)

    press("Fixture discussion A")
    press("Add")
    press("Calendar, Next 7 Days")
    visible("Zahnarzt")  # Appointment supplied by PIPPA_DEMO.
    edit("Zahnarzt", "CHECKED_EXCERPT_08")
    press("Cancel")
    visible("Continue Checking…")
    press("Fixture discussion B")
    wait(lambda: "Continue Checking…" not in ax("tree").stdout, "separate draft in B")
    press("Fixture discussion A")
    press("Continue Checking…")
    visible("CHECKED_EXCERPT_08")
    assert not requests, "Opening, editing and cancelling a review sent a request"
    press("Send to Fixture AI")
    visible("FIXTURE_OK")
    assert len(requests) == 1
    first = json.dumps(requests[0])
    assert "CHECKED_EXCERPT_08" in first
    assert all(marker not in first for marker in ["Zahnarzt", "Praxis Beispiel", "LOCAL_NOTE_08"])

    wait(lambda: ax("compose", "FOLLOWUP_08").returncode == 0, "chat composer")
    press("Send")
    wait(lambda: len(requests) >= 2, "ordinary follow-up request")
    second = json.dumps(requests[1])
    assert "FOLLOWUP_08" in second and "CHECKED_EXCERPT_08" not in second and "LOCAL_NOTE_08" not in second
    print("Cloud sharing passed: draft survives changing chats, only the edited excerpt is sent, and the next question omits it.")


def run(app, temp, server):
    home = temp / "home"
    agent = home / ".pi/agent"
    support = home / "Library/Application Support/Pippa"
    conversations = support / "conversations"
    agent.mkdir(parents=True)
    conversations.mkdir(parents=True)
    clone = temp / "Pippa.app"
    subprocess.run(["cp", "-cR", app, clone], check=True)
    bundle_id = "io.github.tschnorpfeil.pippa.sharing-check." + str(os.getpid())
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {bundle_id}", clone / "Contents/Info.plist"], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", clone], check=True)
    helper = temp / "sharing-accessibility"
    subprocess.run(["swiftc", "-O", "-o", helper, ROOT / "scripts/sharing-accessibility.swift"], check=True)
    write_json(agent / "models.json", {"providers": {"fixture": {
        "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-completions", "apiKey": "fixture",
        "models": [{"id": "fixture", "name": "Fixture", "contextWindow": 32768, "maxTokens": 1024}]}}})
    write_json(support / "inference-settings.json", {"policy": "localOnly", "piModel": {
        "providerID": "fixture", "modelID": "fixture", "providerName": "Fixture AI"}})
    (support / "memory.md").write_text("LOCAL_NOTE_08\n", encoding="utf-8")
    for key in ["A", "B"]:
        write_json(conversations / f"{key}.json", {"id": key, "title": f"Fixture discussion {key}", "updated": 743000000, "messages": []})
    env = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "PIPPA_PI_HOME": str(home), "PI_CODING_AGENT_DIR": str(agent),
           "PIPPA_NO_MOVE": "1", "PIPPA_DEMO": "1", "PI_OFFLINE": "1", "PI_TELEMETRY": "0", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    with subprocess.Popen([clone / "Contents/MacOS/Pippa", "-AppleLanguages", "(en)", "-SUEnableAutomaticChecks", "NO"],
                          env=env, stdout=subprocess.DEVNULL) as pippa:
        try:
            exercise(pippa.pid, helper, server.requests)
            subprocess.run([helper, str(pippa.pid), "quit"], check=True, timeout=5)
            pippa.wait(timeout=12)
            snapshots = support / "pi-recipients" / str(pippa.pid)
            assert not list(snapshots.glob("*/models.json")), "Quit left the active provider configuration on disk"
        finally:
            pippa.terminate()
            try:
                pippa.wait(timeout=8)
            except subprocess.TimeoutExpired:
                pippa.kill()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, nargs="?", default=ROOT / "dist/Pippa.app")
    with HTTPServer(("127.0.0.1", 0), FixtureProvider) as server, tempfile.TemporaryDirectory() as directory:
        server.requests = []
        handler = threading.Thread(target=server.serve_forever, daemon=True)
        handler.start()
        try:
            run(parser.parse_args().app.resolve(), Path(directory), server)
        finally:
            server.shutdown()
            handler.join()
