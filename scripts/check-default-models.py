#!/usr/bin/env python3
"""Default model is pinned: every catalog key in ModelSelector.table (between the `table:begin` and `table:end` markers in
app/Sources/PippaCore/Models.swift) must be in catalog.json, not `pending`, and pinned to a revision with path, size and
SHA256 for each file. Otherwise a release would ship a model that cannot be downloaded. scripts/pin-model.sh pins one.
PippaChecks has the same check ("Default model is pinned")."""
import json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
source = (root / "app/Sources/PippaCore/Models.swift").read_text(encoding="utf-8")
match = re.search(r"// table:begin(.*?)// table:end", source, re.S)
if not match:
    sys.exit("check-default-models: table markers missing in Models.swift")
keys = list(dict.fromkeys(re.findall(r':\s*\(\s*"([^"]+)"', match.group(1))))
if not keys:
    sys.exit("check-default-models: no keys found in the table")
problems = []
for catalog in sorted(p for p in (root / "app").rglob("catalog.json") if ".build" not in p.parts):
    models = {m["key"]: m for m in json.loads(catalog.read_text(encoding="utf-8"))["models"]}
    for key in keys:
        model = models.get(key)
        pinned = (model or {}).get("pinned") or {}
        files = pinned.get("files") or []
        if model is None:
            problems.append(f"{key}: not in {catalog.relative_to(root)}")
        elif model.get("pending"):
            problems.append(f"{key}: pending ({model['pending']})")
        elif not re.fullmatch(r"[0-9a-f]{40}", pinned.get("revision", "")) or not files or not all(
                re.fullmatch(r"[0-9a-f]{64}", f.get("sha256", "")) and f.get("size", 0) > 0 and f.get("path") for f in files):
            problems.append(f"{key}: not pinned in {catalog.relative_to(root)} (run scripts/pin-model.sh {key} {model['repo']})")
if problems:
    print("Default model is NOT pinned:\n  " + "\n  ".join(problems), file=sys.stderr)
    sys.exit(1)
print(f"check-default-models: OK ({', '.join(keys)})")
