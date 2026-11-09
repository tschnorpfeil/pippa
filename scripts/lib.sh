#!/usr/bin/env bash
# Shared by the build and release scripts: `. "$ROOT/scripts/lib.sh"` after setting ROOT (and CACHE for the downloads).

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# VERSION from `Pippa.version` and BUILD = base + commit count. The base keeps builds above those of the archived
# repository (up to 282) now that the public repository starts with a single commit; Sparkle only offers higher builds.
read_version_build() {
  VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/app/Sources/PippaCore/PippaCore.swift" | head -1)"
  [[ -n "$VERSION" ]] || die "Pippa.version not found in app/Sources/PippaCore/PippaCore.swift"
  local commits
  commits="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
  BUILD="$(( $(tr -d '[:space:]' < "$ROOT/app/Packaging/build-number-base") + commits ))"
}

# fetch_pinned <url> <file> <sha256>: downloads into the cache once. A cached file that no longer matches is replaced,
# a download that does not match is never kept.
fetch_pinned() {
  local url="$1" file="$2" sha="$3" actual
  if [[ -f "$file" && "$(sha_of "$file")" != "$sha" ]]; then rm -f "$file"; fi
  [[ -f "$file" ]] && return 0
  say "Downloading $(basename "$url")"
  curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
  actual="$(sha_of "$file.part")"
  [[ "$actual" == "$sha" ]] || { rm -f "$file.part"; die "SHA256 of $(basename "$url") does not match: expected $sha, got $actual"; }
  mv "$file.part" "$file"
}

# The pinned Node (app/Packaging/node-release.json), downloaded and unpacked once per cache: sets NODE_VERSION and
# NODE_DIR (bin/node, lib/node_modules/npm). Several scripts of one build use it read-only.
ensure_node() {
  local asset sha unpacked
  read -r NODE_VERSION asset sha < <(python3 - "$ROOT/app/Packaging/node-release.json" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); print(m['version'],m['asset'],m['sha256'])
PY
)
  mkdir -p "$CACHE"
  fetch_pinned "https://nodejs.org/dist/$NODE_VERSION/$asset" "$CACHE/$asset" "$sha"
  unpacked="$CACHE/node-unpacked-${sha:0:12}"
  NODE_DIR="$unpacked/node-$NODE_VERSION-darwin-arm64"
  if [[ ! -x "$NODE_DIR/bin/node" ]]; then
    local work
    work="$(mktemp -d "$CACHE/.node-unpack.XXXXXX")"
    tar -xzf "$CACHE/$asset" -C "$work"
    rm -rf "$unpacked"
    mv "$work" "$unpacked"
  fi
  [[ "$("$NODE_DIR/bin/node" --version)" == "$NODE_VERSION" ]] || die 'Unexpected Node version'
}

# runtime_files <group>: the files of one group in app/Packaging/runtime-files.json (what the build copies into the
# bundle and verify-app.sh and the app's runtime probe expect there).
runtime_files() {
  python3 -c 'import json,sys; print(*json.load(open(sys.argv[1]))[sys.argv[2]], sep="\n")' "$ROOT/app/Packaging/runtime-files.json" "$1"
}
