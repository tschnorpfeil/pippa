#!/usr/bin/env python3
"""Publishes a catalog model's pinned files as a mirror on GitHub releases (see scripts/mirror-model.sh).

Pippa falls back to the mirror when Hugging Face fails and verifies every file against the SHA-256 pinned in
catalog.json, so the assets must be byte-identical to the pinned files. Names: the file's path with `/` replaced by
`--`; a file larger than the catalog's `partSize` is uploaded as `<name>.part-0`, `.part-1`, … of `partSize` bytes
each (the last one shorter) that, joined, are the file.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "tschnorpfeil/pippa"
# GitHub refuses release assets of 2 GiB or more.
ASSET_LIMIT = 2 * 1024 ** 3
CHUNK = 8 << 20


class MirrorError(Exception):
    pass


def catalog_path(root=ROOT):
    catalogs = sorted(p for p in (root / "app").rglob("catalog.json") if ".build" not in p.parts)
    if len(catalogs) != 1:
        raise MirrorError(f"expected one catalog.json under app/, found {[str(p) for p in catalogs]}")
    return catalogs[0]


def mirror_tag(key, revision):
    return f"model-{key}-{revision[:7]}"


def mirror_problems(model, repo=REPO):
    """What keeps `model` from having a mirror (empty: fine). Shared with scripts/check-default-models.py."""
    key = model.get("key", "?")
    mirror = model.get("mirror")
    if mirror is None:
        return [f"{key}: no mirror in catalog.json"]
    problems = []
    revision = (model.get("pinned") or {}).get("revision", "")
    tag = mirror_tag(key, revision)
    url = mirror.get("url", "")
    expected = f"https://github.com/{repo}/releases/download/{tag}/"
    if url != expected:
        problems.append(f"{key}: mirror url {url!r} is not {expected!r} (this repo, tag model-<key>-<revision[:7]>)")
    part = mirror.get("partSize")
    if not isinstance(part, int) or isinstance(part, bool) or not 0 < part < ASSET_LIMIT:
        problems.append(f"{key}: mirror partSize {part!r} must be a positive integer below 2 GiB ({ASSET_LIMIT})")
    if not str(model.get("license") or "").strip():
        problems.append(f"{key}: a mirrored model needs \"license\" (as the publisher states it) for the release notes")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        problems.append(f"{key}: not pinned to a revision")
    return problems


def asset_name(path):
    """Release asset name of a pinned file: `/` becomes `--` (asset names are flat)."""
    return path.replace("/", "--")


def assets_for(path, size, part_size):
    """[(asset name, offset in the file, length)] of one pinned file on the mirror."""
    name = asset_name(path)
    if size <= part_size:
        return [(name, 0, size)]
    count = -(-size // part_size)
    return [(f"{name}.part-{i}", i * part_size, min(part_size, size - i * part_size)) for i in range(count)]


def sha256_of(paths):
    """SHA-256 of the files' contents joined in order."""
    digest = hashlib.sha256()
    for path in paths:
        with open(path, "rb") as f:
            while block := f.read(CHUNK):
                digest.update(block)
    return digest.hexdigest()


def search_roots(model, home):
    """Folders that may hold the pinned files, as (label, folder where the file is found under its path or basename)."""
    support = home / "Library/Application Support/Pippa"
    models = support / "omlx/models"
    try:
        state = json.loads((support / "install-state.json").read_text(encoding="utf-8"))
        if state.get("modelsFolder"):
            models = pathlib.Path(state["modelsFolder"])
    except (OSError, ValueError):
        pass
    revision = model["pinned"]["revision"]
    hub = pathlib.Path(os.environ.get("HF_HUB_CACHE") or pathlib.Path(os.environ.get("HF_HOME") or home / ".cache/huggingface") / "hub")
    return [
        ("Pippa", models / model["key"], True),
        ("oMLX", home / ".omlx/models" / model["repo"], False),
        ("Hugging Face cache", hub / ("models--" + model["repo"].replace("/", "--")) / "snapshots" / revision, False),
    ]


def locate(model, home):
    """{path: (file, label)} with a verified copy of every pinned file; MirrorError listing each mismatch otherwise.
    Only reads: a copy that differs is reported and the next folder is tried."""
    found, problems = {}, []
    roots = search_roots(model, home)
    for entry in model["pinned"]["files"]:
        path, size, sha = entry["path"], entry["size"], entry["sha256"]
        for label, folder, flat in roots:
            candidate = folder / (pathlib.PurePosixPath(path).name if flat else path)
            if not candidate.is_file():
                continue
            actual = candidate.stat().st_size
            if actual != size:
                problems.append(f"{path}: {label} copy {candidate} has {actual} bytes, pinned {size}")
                continue
            digest = sha256_of([candidate])
            if digest != sha:
                problems.append(f"{path}: {label} copy {candidate} has SHA-256 {digest}, pinned {sha}")
                continue
            found[path] = (candidate, label)
            break
        else:
            problems.append(f"{path}: no verified copy in " + ", ".join(str(folder) for _, folder, _ in roots))
    missing = [e["path"] for e in model["pinned"]["files"] if e["path"] not in found]
    if missing:
        raise MirrorError("cannot mirror, files missing or not matching the pins:\n  " + "\n  ".join(problems))
    return found, problems


def split(source, path, size, part_size, sha, work):
    """Writes the assets of one file into `work` and verifies them by hashing them joined. Returns their paths."""
    pieces = assets_for(path, size, part_size)
    if len(pieces) == 1:
        link = work / pieces[0][0]
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(source)  # the verified file itself, under its asset name; never modified
        written = [link]
    else:
        written = []
        with open(source, "rb") as f:
            for name, offset, length in pieces:
                target = work / name
                f.seek(offset)
                left = length
                with open(target, "wb") as out:
                    while left > 0:
                        block = f.read(min(CHUNK, left))
                        if not block:
                            raise MirrorError(f"{source} ended early")
                        out.write(block)
                        left -= len(block)
                written.append(target)
    if [p.stat().st_size for p in written] != [length for _, _, length in pieces]:
        raise MirrorError(f"{path}: parts have the wrong sizes")
    if sha256_of(written) != sha:
        raise MirrorError(f"{path}: joined parts do not match the pinned SHA-256")
    return written


def release_notes(model):
    pinned = model["pinned"]
    part = model["mirror"]["partSize"]
    rows = "\n".join(f"| `{f['path']}` | {f['size']} | `{f['sha256']}` |" for f in pinned["files"])
    return f"""Mirror of the AI model files Pippa downloads during setup. **This is not an app release**: download Pippa from
the latest release.

- Model: {model['label']}
- Source: https://huggingface.co/{model['repo']}/tree/{pinned['revision']}
- Revision: `{pinned['revision']}`
- License: {model['license']}
- Model card: `MODEL-CARD.md`, the source's `README.md` at this revision

Pippa uses these files only when the download from Hugging Face fails, and checks every file against the SHA-256
pinned in its catalog before using it, so a file that differs from the source is never installed. Each file is named
after its path with `/` replaced by `--`; a file larger than {part} bytes is split into `<name>.part-0`, `.part-1`, …
of {part} bytes each that, joined, are the file.

| File | Bytes | SHA-256 |
|---|---|---|
{rows}
"""


def card_url(model, endpoint=None):
    endpoint = (endpoint or os.environ.get("PIPPA_HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
    return f"{endpoint}/{urllib.parse.quote(model['repo'], safe='/')}/resolve/{model['pinned']['revision']}/README.md"


def gh(*args, check=True):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=check)


def existing_assets(tag, repo):
    """{name: size} of the release's assets, or None when the release does not exist."""
    result = gh("release", "view", tag, "--repo", repo, "--json", "assets", check=False)
    if result.returncode != 0:
        if "not found" in (result.stderr or "").lower():
            return None
        raise MirrorError(f"gh release view {tag} failed: {result.stderr.strip()}")
    return {a["name"]: a["size"] for a in json.loads(result.stdout)["assets"]}


def main(argv=None, home=None, catalog=None):
    parser = argparse.ArgumentParser(description="Publish a catalog model's pinned files as a GitHub release mirror.")
    parser.add_argument("key")
    parser.add_argument("--dry-run", action="store_true", help="verify the local files and show what would be uploaded")
    args = parser.parse_args(argv)
    home = pathlib.Path(home or pathlib.Path.home())
    catalog = pathlib.Path(catalog or catalog_path())
    models = {m["key"]: m for m in json.loads(catalog.read_text(encoding="utf-8"))["models"]}
    model = models.get(args.key)
    if model is None:
        raise MirrorError(f"{args.key} is not in {catalog} (keys: {', '.join(models)})")
    if problems := mirror_problems(model):
        raise MirrorError("refusing to mirror:\n  " + "\n  ".join(problems))
    pinned, part = model["pinned"], model["mirror"]["partSize"]
    tag = mirror_tag(model["key"], pinned["revision"])
    title = f"AI model mirror: {model['label']} (not an app release)"

    print(f"Model {model['key']} ({model['repo']} @ {pinned['revision']}), license: {model['license']}")
    print(f"Release {REPO} {tag}: \"{title}\" (pre-release, not latest)")
    found, skipped = locate(model, home)
    for line in skipped:
        print(f"  skipped: {line}")
    planned = []  # (asset name, length, file path)
    for entry in pinned["files"]:
        source, label = found[entry["path"]]
        print(f"verified {entry['path']} ({entry['size']} bytes, SHA-256 {entry['sha256'][:12]}…) from {label}: {source}")
        planned += [(name, length, entry["path"]) for name, _, length in assets_for(entry["path"], entry["size"], part)]
    if not args.dry_run and not shutil.which("gh"):
        raise MirrorError("gh (GitHub CLI, signed in) is needed to publish; --dry-run works without it")
    try:
        existing = existing_assets(tag, REPO) if shutil.which("gh") else None
    except MirrorError as error:
        if not args.dry_run:
            raise
        print(f"Release state unknown ({error}); listing every asset.")
        existing = None
    if existing is not None:
        for name, length, _ in planned:
            if name in existing and existing[name] != length:
                raise MirrorError(f"release asset {name} has {existing[name]} bytes, expected {length}; delete it by hand first")
    have = existing or {}
    print(f"Assets ({'release exists' if existing is not None else 'new release'}):")
    for name, length, path in planned:
        print(f"  {'present' if name in have else 'upload '} {name} ({length} bytes, from {path})")
    print(f"  {'present' if 'MODEL-CARD.md' in have else 'upload '} MODEL-CARD.md (from {card_url(model)})")

    if args.dry_run:
        print("Dry run: nothing written, nothing uploaded.")
        return 0

    cache = pathlib.Path(os.environ.get("PIPPA_CACHE") or home / "Library/Caches/pippa-build")
    work = cache / "mirror" / tag
    work.mkdir(parents=True, exist_ok=True)
    uploads = []
    for entry in pinned["files"]:
        names = [name for name, _, _ in assets_for(entry["path"], entry["size"], part)]
        if all(name in have for name in names):
            continue
        written = split(found[entry["path"]][0], entry["path"], entry["size"], part, entry["sha256"], work)
        print(f"split and verified {entry['path']} into {len(written)} asset(s)")
        uploads += [p for p in written if p.name not in have]
    if "MODEL-CARD.md" not in have:
        request = urllib.request.Request(card_url(model), headers={"User-Agent": "pippa-mirror-model"})
        with urllib.request.urlopen(request, timeout=60) as response:
            (work / "MODEL-CARD.md").write_bytes(response.read())
        uploads.append(work / "MODEL-CARD.md")
    if existing is None:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as notes:
            notes.write(release_notes(model))
        gh("release", "create", tag, "--repo", REPO, "--prerelease", "--latest=false", "--title", title, "--notes-file", notes.name)
        os.unlink(notes.name)
        print(f"created release {tag}")
    for path in uploads:
        print(f"uploading {path.name} …", flush=True)
        gh("release", "upload", tag, str(path), "--repo", REPO)
    final = existing_assets(tag, REPO) or {}
    wrong = [name for name, length, _ in planned if final.get(name) != length]
    if wrong or "MODEL-CARD.md" not in final:
        raise MirrorError(f"release {tag} is incomplete after upload: {wrong or ['MODEL-CARD.md']}")
    shutil.rmtree(work)
    print(f"Mirror complete: https://github.com/{REPO}/releases/tag/{tag}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except MirrorError as error:
        sys.exit(f"mirror-model: {error}")
    except subprocess.CalledProcessError as error:
        sys.exit(f"mirror-model: {' '.join(error.cmd)} failed: {(error.stderr or '').strip()}")
