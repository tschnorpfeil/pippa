#!/usr/bin/env python3
"""Helpers for scripts/build-mlx-runtime.sh: what in the runtime lock is built from source, and where it came from.

  split <requirements.lock> <binary.lock>
      Writes every hash-pinned PyPI entry of the lock to <binary.lock> (installed as wheels, nothing built) and prints
      one tab-separated line per entry that is built from source instead:
          archive <name> <url> <sha256>      a source tarball pinned by its hash (oMLX)
          git     <name> <url> <commit>      a git repository at a fixed commit (mlx-lm, mlx-vlm, ...)

  build-requires <pyproject.toml>...
      Prints the union of their [build-system] requires, one per line, in first-seen order.

  tools <build-tools.lock> <pyproject.toml> <out.lock> [<skip>...]
      Writes the part of the build tools lock that this one source's [build-system] needs (its requirements and what
      they pull in, by the lock's "via" comments) to <out.lock>, leaving out the names in <skip>. Each wheel is built
      with its own tools only, as in an isolated build: setuptools-scm, for one, adds every git-tracked file to the
      wheels of the packages it is installed for.

  direct-url <site-packages> <name> archive <url>
  direct-url <site-packages> <name> git <url> <commit>
      Records where an installed distribution came from (PEP 610 direct_url.json, with its RECORD row), exactly as uv
      writes it when it installs that URL itself: the runtime is installed from wheels built here, and oMLX reads the
      git commits back for its admin page. Drops uv's uv_cache.json there (a timestamp of the local install).
"""

import base64
import csv
import hashlib
import io
import json
import pathlib
import re
import sys
import tomllib

ENTRY = re.compile(r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)\s*@\s*(?P<url>\S+)")
GIT = re.compile(r"^git\+(?P<url>https://[^@\s]+)@(?P<commit>[0-9a-f]{40})$")
HASH = re.compile(r"--hash=sha256:(?P<sha>[0-9a-f]{64})")


def entries(text):
    """The lock's requirement blocks: a line starting in column 0 plus its indented continuation and comment lines."""
    blocks = []
    for line in text.splitlines(keepends=True):
        starts_entry = line.strip() and not line[0].isspace() and not line.startswith("#")
        if starts_entry:
            blocks.append([line])
        elif blocks:
            blocks[-1].append(line)
    return ["".join(block) for block in blocks]


def split(lock_text):
    """(binary lock text, [(kind, name, url, pin)]) for a uv-generated requirements lock."""
    binary, sources = [], []
    for block in entries(lock_text):
        match = ENTRY.match(block)
        if not match:
            if not HASH.search(block):
                raise ValueError(f"lock entry without a hash: {block.splitlines()[0]}")
            binary.append(block)
            continue
        name, url = match["name"], match["url"]
        git = GIT.match(url)
        if git:
            sources.append(("git", name, git["url"], git["commit"]))
            continue
        hashes = HASH.findall(block)
        if url.startswith("https://") and len(hashes) == 1:
            sources.append(("archive", name, url, hashes[0]))
            continue
        raise ValueError(f"{name}: a direct URL needs a git commit or exactly one sha256 hash: {url}")
    return "".join(binary), sources


def build_requires(paths):
    seen = []
    for path in paths:
        with open(path, "rb") as f:
            requires = tomllib.load(f).get("build-system", {}).get("requires")
        if requires is None:
            raise ValueError(f"{path} has no [build-system] requires")
        for requirement in requires:
            if requirement not in seen:
                seen.append(requirement)
    return seen


def requirement_name(requirement):
    match = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", requirement)
    if not match:
        raise ValueError(f"cannot read requirement {requirement!r}")
    return normalized(match[1])


def via(block):
    """The names a lock entry is there for, from uv's "# via" annotation ("-r <file>" left out)."""
    parents, in_via = [], False
    for line in block.splitlines()[1:]:
        text = line.strip()
        if text.startswith("# via"):
            in_via = True
            text = text[len("# via"):].strip()
        elif in_via and text.startswith("#"):
            text = text[1:].strip()
        else:
            in_via = False
            continue
        if text and not text.startswith("-r "):
            parents.append(normalized(text))
    return parents


def tools_for(lock_text, pyproject, skip=()):
    blocks = {requirement_name(block.splitlines()[0]): block for block in entries(lock_text)}
    skip = {normalized(name) for name in skip}
    wanted = [name for name in map(requirement_name, build_requires([pyproject])) if name not in skip]
    missing = [name for name in wanted if name not in blocks]
    if missing:
        raise ValueError(f"build tools lock has no {', '.join(missing)} ({pyproject})")
    needed = set(wanted)
    while True:
        more = {name for name, block in blocks.items() if name not in needed and needed & set(via(block))}
        if not more:
            break
        needed |= more
    return "".join(block for name, block in blocks.items() if name in needed)


def direct_url_json(kind, url, commit=None):
    if kind == "archive":
        data = {"url": url, "archive_info": {}}
    elif kind == "git":
        data = {"url": url, "vcs_info": {"vcs": "git", "commit_id": commit, "requested_revision": commit}}
    else:
        raise ValueError(f"unknown source kind {kind}")
    return json.dumps(data, separators=(",", ":"))


def normalized(name):
    return re.sub(r"[-_.]+", "_", name).lower()


def record_direct_url(site, name, content):
    """Writes <dist-info>/direct_url.json and puts its row into RECORD (replacing one that is there). Drops
    uv_cache.json, uv's note on when it installed a local wheel, which means nothing in the archive."""
    site = pathlib.Path(site)
    matches = [p for p in site.glob("*.dist-info") if normalized(p.name.split("-", 1)[0]) == normalized(name)]
    if len(matches) != 1:
        raise ValueError(f"expected one dist-info for {name} in {site}, found {len(matches)}")
    dist_info = matches[0]
    data = content.encode()
    (dist_info / "direct_url.json").write_bytes(data)
    digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
    row_path = f"{dist_info.name}/direct_url.json"
    uv_cache = f"{dist_info.name}/uv_cache.json"
    (dist_info / "uv_cache.json").unlink(missing_ok=True)
    record = dist_info / "RECORD"
    rows = [row for row in csv.reader(io.StringIO(record.read_text())) if row and row[0] not in (row_path, uv_cache)]
    rows.append([row_path, f"sha256={digest}", str(len(data))])
    out = io.StringIO()
    csv.writer(out, lineterminator="\n").writerows(rows)
    record.write_text(out.getvalue())
    return dist_info


def main(argv):
    command, *args = argv
    if command == "split" and len(args) == 2:
        binary, sources = split(pathlib.Path(args[0]).read_text())
        pathlib.Path(args[1]).write_text(binary)
        for source in sources:
            print("\t".join(source))
    elif command == "build-requires" and args:
        print("\n".join(build_requires(args)))
    elif command == "tools" and len(args) >= 3:
        lock, pyproject, out, *skip = args
        pathlib.Path(out).write_text(tools_for(pathlib.Path(lock).read_text(), pyproject, skip))
    elif command == "direct-url" and len(args) in (4, 5):
        site, name, kind, url, *commit = args
        record_direct_url(site, name, direct_url_json(kind, url, *commit))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except ValueError as error:
        sys.exit(f"mlx-runtime-sources: {error}")
