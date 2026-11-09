#!/usr/bin/env bash
# Builds the MLX runtime archive Pippa downloads at setup (arm64): a standalone CPython 3.11
# (python-build-standalone, via uv) with oMLX and its pinned dependencies installed into that Python's
# own site-packages. No venv, because a venv is not relocatable; the unpacked folder runs from anywhere:
#
#   <dir>/bin/python3 -c "from omlx.cli import main; main()" serve --base-path <base> --headless
#
#   scripts/build-mlx-runtime.sh
#
# Output: dist/mlx-runtime/pippa-mlx-runtime-<version>-arm64.tar.gz and a JSON manifest next to it, copied to
# app/Sources/PippaCore/Resources/mlx-runtime.json. The archive holds bin/, lib/ at its root.
#
# Dependencies come from app/Packaging/mlx-runtime/requirements.lock (hashes for everything from PyPI and the oMLX
# source tarball; mlx-lm, mlx-vlm, mlx-audio and mlx-embeddings are git URLs at fixed commits, as oMLX requires).
#
# oMLX's native kernels (omlx/custom_kernels: C++ extensions and Metal libraries) build only with
# OMLX_WITH_CUSTOM_KERNEL=1 and Xcode's Metal compiler; .github/workflows/mlx-runtime.yml builds the release archive
# that way on a GitHub runner. Their build tools (setuptools, cmake, nanobind as oMLX's [build-system] names them) come
# from app/Packaging/mlx-runtime/kernel-build.lock and never land in the archive.
#
# Environment:
#   OMLX_WITH_CUSTOM_KERNEL=1   build oMLX's native kernels into the runtime (needs Xcode with the macOS 26.2 SDK or
#                               newer: `xcrun metal`); without it the runtime has none and oMLX takes its slow paths
#   PIPPA_MLX_RELOCK=1          resolve the lock files again (otherwise each is created only when missing)
#   PIPPA_CACHE                 download cache (default ~/Library/Caches/pippa-build)
#   PIPPA_MLX_VERIFY=0          skip the check that unpacks the archive and starts the server
#   PIPPA_MLX_VERIFY_MODEL      MLX model folder for a chat request in that check
#                               (default ~/.omlx/models/ornith-ai/Ornith-1.5-9B-MLX-4bit; skipped when missing)
#   PIPPA_MLX_VERIFY_GUARD      oMLX memory guard tier for that check (default balanced; aggressive when another
#                               server already holds a model)
#   UV                          uv binary (default: uv from PATH, then ~/.local/bin/uv)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING="$ROOT/app/Packaging/mlx-runtime"
LOCK="$PACKAGING/requirements.lock"
KERNEL_LOCK="$PACKAGING/kernel-build.lock"
OUT="$ROOT/dist/mlx-runtime"
RESOURCE_MANIFEST="$ROOT/app/Sources/PippaCore/Resources/mlx-runtime.json"
CACHE="${PIPPA_CACHE:-$HOME/Library/Caches/pippa-build}/mlx-runtime"

# --- Pins --------------------------------------------------------------------
OMLX_VERSION="0.7.3"
BUILD_REVISION="2"                       # bump when the archive changes without a new oMLX (2: native kernels)
VERSION="$OMLX_VERSION-$BUILD_REVISION"
PYTHON_VERSION="3.11.14"                 # python-build-standalone as uv ships it
OMLX_URL="https://github.com/jundot/omlx/archive/refs/tags/v$OMLX_VERSION.tar.gz"
OMLX_SHA256="ff0d649ba4e550c031a5d27bb7a4a89b30b35607483fd42010bda2164c0547ad"
# Resolution date for PyPI packages: a relock picks what existed then, not whatever is newest.
EXCLUDE_NEWER="2026-11-01T00:00:00Z"
NAME="pippa-mlx-runtime-$VERSION-arm64"
ARCHIVE="$OUT/$NAME.tar.gz"
MANIFEST="$OUT/$NAME.json"
RELEASE_URL="https://github.com/tschnorpfeil/pippa/releases/download/mlx-runtime-$VERSION/$NAME.tar.gz"
# The kernels' Mach-O files target oMLX's own default; the NAX library sets 26.2 itself (oMLX's setup.py).
KERNEL_DEPLOYMENT_TARGET="15.0"
KERNEL_PACKAGES=(attention lowbit quant_matmul sparse_index)

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$*" >&2; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
die() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || die "Apple silicon macOS only"
UV="${UV:-$(command -v uv || true)}"
[[ -n "$UV" ]] || UV="$HOME/.local/bin/uv"
[[ -x "$UV" ]] || die "uv missing (https://docs.astral.sh/uv/)"
for tool in codesign otool install_name_tool file shasum curl tar gzip; do
  command -v "$tool" >/dev/null || die "$tool missing (Command Line Tools installed?)"
done
case "$(printf '%s' "${OMLX_WITH_CUSTOM_KERNEL:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) KERNELS=1 ;;
  *) KERNELS=0 ;;
esac
# Read once, then gone: uv must build oMLX's wheel without kernels (its isolated build would fetch unpinned tools),
# the kernels are built below from the same source with pinned ones.
unset OMLX_WITH_CUSTOM_KERNEL
if [[ "$KERNELS" == 1 ]]; then
  # Fail before anything is downloaded: asked for kernels, a build without them would look the same from outside.
  if ! xcrun -sdk macosx -f metal >/dev/null 2>&1 || ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    die "OMLX_WITH_CUSTOM_KERNEL=1 needs Xcode's Metal compiler, and \`xcrun metal\` does not run here (developer dir: $(xcode-select -p 2>/dev/null || echo none)). Install Xcode and select it with xcode-select -s (on Xcode 26 also: xcodebuild -downloadComponent MetalToolchain), or build without kernels by leaving OMLX_WITH_CUSTOM_KERNEL unset."
  fi
  SDK_VERSION="$(xcrun -sdk macosx --show-sdk-version)"
  [[ "$(printf '%s\n26.2\n' "$SDK_VERSION" | sort -V | head -1)" == 26.2 ]] \
    || die "OMLX_WITH_CUSTOM_KERNEL=1 needs the macOS 26.2 SDK or newer for the NAX kernels (M5 and newer); this Xcode has $SDK_VERSION"
fi
say "MLX runtime $VERSION (oMLX $OMLX_VERSION, Python $PYTHON_VERSION, native kernels: $([[ "$KERNELS" == 1 ]] && echo "yes, macOS SDK $SDK_VERSION" || echo no))"

mkdir -p "$CACHE" "$OUT" "$PACKAGING"
# Resolved like BASE_DIR below (a TMPDIR cache under /var is /private/var), so the Python check compares like with like.
CACHE="$(cd "$CACHE" && pwd -P)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pippa-mlx-runtime.XXXXXX")"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Python (python-build-standalone) ----------------------------------------
# A private install dir keeps the copy pristine: nothing else ever installs into it.
say "Python $PYTHON_VERSION"
export UV_PYTHON_INSTALL_DIR="$CACHE/python"
# --no-bin: leave the python3.11 links in ~/.local/bin alone.
"$UV" python install --no-bin "$PYTHON_VERSION"
BASE_PY="$("$UV" python find --managed-python --no-project "$PYTHON_VERSION")"
BASE_DIR="$(cd "$(dirname "$BASE_PY")/.." && pwd -P)"
[[ "$BASE_DIR" == "$UV_PYTHON_INSTALL_DIR"/* ]] || die "uv found $BASE_PY instead of a Python in $UV_PYTHON_INSTALL_DIR"
unset UV_PYTHON_INSTALL_DIR

# --- Lock file ---------------------------------------------------------------
# oMLX without extras (no audio, grammar, mcp, cluster, bundle). mlx-audio stays: oMLX imports it as a base
# dependency, its own extras stay out.
if [[ ! -f "$LOCK" || "${PIPPA_MLX_RELOCK:-0}" == 1 ]]; then
  say "resolving $LOCK"
  printf 'omlx @ %s\n' "$OMLX_URL" > "$WORK/requirements.in"
  "$UV" pip compile "$WORK/requirements.in" \
    --python "$BASE_PY" --python-platform aarch64-apple-darwin \
    --generate-hashes --exclude-newer "$EXCLUDE_NEWER" \
    --no-header --output-file "$WORK/requirements.lock"
  {
    printf '# Pinned dependencies of the Pippa MLX runtime (oMLX %s, CPython %s, macOS arm64).\n' \
      "$OMLX_VERSION" "$PYTHON_VERSION"
    printf '# Generated by scripts/build-mlx-runtime.sh (PIPPA_MLX_RELOCK=1); do not edit by hand.\n'
    cat "$WORK/requirements.lock"
  } > "$LOCK"
fi
# The oMLX tarball is pinned by its release hash, whatever the lock says.
grep -q "sha256:$OMLX_SHA256" "$LOCK" || die "lock file does not carry the oMLX $OMLX_VERSION tarball hash"

# --- Install -----------------------------------------------------------------
STAGE="$WORK/$NAME"
say "staging $NAME"
cp -R "$BASE_DIR" "$STAGE"
SITE="$STAGE/lib/python3.11/site-packages"
# Start from an empty site-packages: pip and setuptools come back only if the lock needs them.
rm -rf "$SITE"/*
rm -f "$STAGE/lib/python3.11/EXTERNALLY-MANAGED"
"$UV" pip install --python "$STAGE/bin/python3" --no-deps --link-mode copy --no-compile \
  --exclude-newer "$EXCLUDE_NEWER" -r "$LOCK"

# --- Native kernels (OMLX_WITH_CUSTOM_KERNEL=1) ------------------------------
# What oMLX's `make kernels` does, against the staged Python and its MLX (the extensions are ABI-coupled to that exact
# mlx), from the same pinned source tarball. Before the prune: CMake needs the staged Python's headers.
if [[ "$KERNELS" == 1 ]]; then
  say "building oMLX's native kernels"
  SRC_ARCHIVE="$CACHE/omlx-$OMLX_VERSION.tar.gz"
  if [[ ! -f "$SRC_ARCHIVE" ]] || ! shasum -a 256 "$SRC_ARCHIVE" | grep -q "^$OMLX_SHA256 "; then
    curl -fsSL --retry 3 -o "$SRC_ARCHIVE.part" "$OMLX_URL"
    mv "$SRC_ARCHIVE.part" "$SRC_ARCHIVE"
  fi
  shasum -a 256 "$SRC_ARCHIVE" | grep -q "^$OMLX_SHA256 " || die "oMLX $OMLX_VERSION source tarball does not match its pinned hash"
  SRC="$WORK/omlx-src"
  mkdir -p "$SRC"
  tar -xzf "$SRC_ARCHIVE" -C "$SRC" --strip-components 1
  if [[ ! -f "$KERNEL_LOCK" || "${PIPPA_MLX_RELOCK:-0}" == 1 ]]; then
    say "resolving $KERNEL_LOCK"
    # The kernel build tools exactly as oMLX's [build-system] names them (mlx comes from the runtime itself).
    "$BASE_PY" -I -c '
import sys, tomllib
requires = tomllib.load(open(sys.argv[1], "rb"))["build-system"]["requires"]
print("\n".join(r for r in requires if r.startswith(("setuptools", "cmake", "nanobind"))))' \
      "$SRC/pyproject.toml" > "$WORK/kernel-build.in"
    "$UV" pip compile "$WORK/kernel-build.in" \
      --python "$BASE_PY" --python-platform aarch64-apple-darwin \
      --generate-hashes --exclude-newer "$EXCLUDE_NEWER" \
      --no-header --output-file "$WORK/kernel-build.lock"
    {
      printf '# Tools that build oMLX %s'"'"'s native kernels for the Pippa MLX runtime (oMLX [build-system]; not shipped).\n' \
        "$OMLX_VERSION"
      printf '# Generated by scripts/build-mlx-runtime.sh (OMLX_WITH_CUSTOM_KERNEL=1, PIPPA_MLX_RELOCK=1); do not edit by hand.\n'
      cat "$WORK/kernel-build.lock"
    } > "$KERNEL_LOCK"
  fi
  # A nanobind other than oMLX's pin isolates the extensions from mlx's arrays (oMLX issue #2139).
  NANOBIND_PIN="$(sed -n 's/^[[:space:]]*"nanobind==\([0-9][0-9.]*\)".*/\1/p' "$SRC/pyproject.toml" | head -1)"
  grep -q "^nanobind==$NANOBIND_PIN " "$KERNEL_LOCK" || die "$KERNEL_LOCK does not pin nanobind $NANOBIND_PIN as oMLX $OMLX_VERSION requires"
  KDEPS="$WORK/kernel-build"
  "$UV" pip install --target "$KDEPS" --python "$BASE_PY" --no-deps --require-hashes \
    --exclude-newer "$EXCLUDE_NEWER" -r "$KERNEL_LOCK"
  (
    cd "$SRC"
    export PYTHONPATH="$KDEPS" PATH="$KDEPS/cmake/data/bin:$PATH"
    export OMLX_WITH_CUSTOM_KERNEL=1 OMLX_CUSTOM_KERNEL_DEPLOYMENT_TARGET="$KERNEL_DEPLOYMENT_TARGET"
    export MACOSX_DEPLOYMENT_TARGET="$KERNEL_DEPLOYMENT_TARGET" CMAKE_ARGS="-DCMAKE_OSX_DEPLOYMENT_TARGET=$KERNEL_DEPLOYMENT_TARGET"
    "$STAGE/bin/python3" -B setup.py build_ext --inplace --force
  ) || die "native kernel build failed; see the output above"
  for kernel in "${KERNEL_PACKAGES[@]}"; do
    built="$SRC/omlx/custom_kernels/$kernel"
    target="$SITE/omlx/custom_kernels/$kernel"
    [[ -d "$target" ]] || die "oMLX $OMLX_VERSION has no omlx/custom_kernels/$kernel in the runtime"
    [[ -f "$built/_ext.cpython-311-darwin.so" ]] || die "kernel build left no $kernel/_ext.cpython-311-darwin.so"
    [[ -f "$built/omlx_${kernel}_kernels.metallib" ]] || die "kernel build left no $kernel/omlx_${kernel}_kernels.metallib"
    cp "$built"/_ext.cpython-311-darwin.so "$built"/*.metallib "$target/"
  done
  # SDK-gated, not deployment-gated: with the 26.2 SDK checked above it must be there (M5 and newer use it).
  [[ -f "$SITE/omlx/custom_kernels/quant_matmul/omlx_quant_matmul_kernels_nax.metallib" ]] \
    || die "kernel build left no quant_matmul/omlx_quant_matmul_kernels_nax.metallib"
  say "native kernels: $(cd "$SITE/omlx/custom_kernels" && ls */_ext*.so */*.metallib | tr '\n' ' ')"
fi

# --- Prune -------------------------------------------------------------------
# Only what text serving never touches; the check below starts the unpacked server.
say "pruning"
STD="$STAGE/lib/python3.11"
find "$STAGE" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$SITE" -type d \( -name tests -o -name test \) -prune -exec rm -rf {} +
rm -rf "$STD"/{idlelib,tkinter,turtledemo,ensurepip,lib2to3,test} "$STD"/turtle.py \
  "$STD"/config-3.11-darwin "$STD"/lib-dynload/_tkinter*.so \
  "$STAGE"/lib/{tcl*,tk*,itcl*,thread*,libtcl*,pkgconfig} "$STAGE"/include "$STAGE"/share \
  "$STAGE"/BUILD
# C/C++ headers are for building extensions; mlx keeps its own (metal kernels may compile against them).
find "$SITE" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.pyx' -o -name '*.pxd' -o -name '*.c' -o -name '*.cpp' \) \
  -not -path "$SITE/mlx/*" -delete
find "$SITE" -type d -empty -delete

# Console scripts carry this machine's absolute path in their shebang; oMLX starts via `python3 -c`.
find "$STAGE/bin" -mindepth 1 \( -type f -o -type l \) \
  -not -name python -not -name python3 -not -name python3.11 -delete

# uv writes its install path into the sysconfig data (used only to build extensions); put back the
# python-build-standalone placeholder.
for f in "$STD"/_sysconfigdata_*.py; do
  sed -i '' -e "s|$BASE_DIR|/install|g" -e "s|$STAGE|/install|g" "$f"
done

# Absolute build paths in text files would break after the move: refuse to ship them.
if grep -rIl --exclude=RECORD --exclude=direct_url.json -e "$STAGE" -e "$BASE_DIR" "$STAGE" >"$WORK/abs-paths" 2>/dev/null; then
  warn "absolute build paths remain in:"
  sed 's/^/    /' "$WORK/abs-paths" >&2
  die "runtime is not relocatable"
fi

# --- Mach-O: relocatable links and ad hoc signatures -------------------------
say "checking and signing Mach-O files"
MACHO=()
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then MACHO+=("$f"); fi
done < <(find "$STAGE" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
# uv sets libpython's install name to its own install path; python-build-standalone ships it relative.
for f in "${MACHO[@]}"; do
  id="$(otool -D "$f" | tail -n +2)"
  if [[ "$id" == "$BASE_DIR"/* || "$id" == "$STAGE"/* ]]; then
    install_name_tool -id "@executable_path/../lib/${id##*/}" "$f" 2>/dev/null
  fi
done
for f in "${MACHO[@]}"; do
  if otool -L "$f" | grep $'^\t' | grep -E -e "$STAGE" -e "$BASE_DIR" -e '/opt/homebrew' -e '/usr/local' -e '/Users/' >/dev/null; then
    otool -L "$f" >&2
    die "$f links against a path outside the runtime"
  fi
done
# Every binary must load on the oldest macOS Pippa supports. A wheel's platform tag is not proof: MLX 0.32.4's
# macosx_26_0 wheels need macOS 26.2. Run by the base Python: the staged one's libpython has just lost its signature
# to install_name_tool, and macOS kills it until the files are signed again below.
if ! "$BASE_PY" -I "$ROOT/scripts/macho-minos.py" "$STAGE" "$ROOT/app/Packaging/Info.plist" >"$WORK/too-new"; then
  warn "these need a newer macOS than LSMinimumSystemVersion in app/Packaging/Info.plist:"
  sed 's/^/    /' "$WORK/too-new" >&2
  die "runtime does not load on every macOS Pippa supports"
fi
xattr -cr "$STAGE"
for f in "${MACHO[@]}"; do codesign --force --timestamp=none --sign - "$f" 2>/dev/null; done
say "${#MACHO[@]} Mach-O files signed"

# --- Archive and manifest ----------------------------------------------------
say "archiving"
rm -f "$ARCHIVE" "$MANIFEST"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C "$STAGE" -cf - . | gzip -9 > "$ARCHIVE"
SIZE="$(stat -f %z "$ARCHIVE")"
SHA256="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
UNPACKED_KB="$(du -sk "$STAGE" | cut -f1)"
PY_FULL="$("$STAGE/bin/python3" -I -c 'import platform; print(platform.python_version())')"
cat > "$MANIFEST" <<JSON
{
  "version": "$VERSION",
  "omlx": "$OMLX_VERSION",
  "python": "$PY_FULL",
  "native_kernels": $([[ "$KERNELS" == 1 ]] && echo true || echo false),
  "file": "$NAME.tar.gz",
  "size": $SIZE,
  "sha256": "$SHA256",
  "url": "$RELEASE_URL"
}
JSON
cp "$MANIFEST" "$RESOURCE_MANIFEST"
say "$ARCHIVE: $(( SIZE / 1048576 )) MB compressed, $(( UNPACKED_KB / 1024 )) MB unpacked"
[[ "$KERNELS" == 1 ]] || warn "built without oMLX's native kernels: not the archive the release of $VERSION carries (OMLX_WITH_CUSTOM_KERNEL=1 on a Mac with Xcode, or .github/workflows/mlx-runtime.yml)"

# --- Check: unpack elsewhere, start the server, ask the model ----------------
[[ "${PIPPA_MLX_VERIFY:-1}" == 1 ]] || exit 0
say "checking the unpacked archive"
CHECK="$WORK/check"
RUNTIME="$CHECK/runtime"
BASE="$CHECK/base"
mkdir -p "$RUNTIME" "$BASE/models"
tar -xzf "$ARCHIVE" -C "$RUNTIME"
rm -rf "$STAGE"   # nothing may resolve back into the staging folder
# oMLX's own report (also in its /api/status). Built with kernels, every native package must load and accept MLX
# arrays (the ABI probe runs on import); built without, none is expected.
"$RUNTIME/bin/python3" -I -c '
import sys
from omlx.custom_kernels import native_kernel_status
status = native_kernel_status()
for name, report in status.items():
    print("native kernel %s: available=%s import_error=%s" % (name, report["available"], report["import_error"]))
missing = [name for name, report in status.items() if not report["available"]]
sys.exit(1 if sys.argv[1] == "1" and missing else 0)' "$KERNELS" || die "native kernels missing from the archive"
MODEL_DIR="${PIPPA_MLX_VERIFY_MODEL:-$HOME/.omlx/models/ornith-ai/Ornith-1.5-9B-MLX-4bit}"
MODEL_ID=""
if [[ -d "$MODEL_DIR" ]]; then
  MODEL_ID="$(basename "$MODEL_DIR" | tr '[:upper:]' '[:lower:]')"
  ln -s "$MODEL_DIR" "$BASE/models/$MODEL_ID"
else
  warn "no model at $MODEL_DIR: checking startup only"
fi
PORT="$("$RUNTIME/bin/python3" -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
KEY="pippa-check-$RANDOM$RANDOM"
cat > "$BASE/settings.json" <<JSON
{"server": {"host": "127.0.0.1", "port": $PORT}, "auth": {"api_key": "$KEY"}}
JSON
chmod 600 "$BASE/settings.json"

# A private HOME: oMLX writes ~/.omlx/bin/omlx-cluster-python on every start, whatever --base-path says, and the
# check must not repoint the shim of an oMLX the person runs.
mkdir -p "$CHECK/home"
START="$(now_ms)"
(cd "$CHECK" && HOME="$CHECK/home" exec "$RUNTIME/bin/python3" -c "from omlx.cli import main; main()" \
  serve --base-path "$BASE" --headless --port "$PORT" --memory-guard "${PIPPA_MLX_VERIFY_GUARD:-balanced}") \
  >"$CHECK/server.log" 2>&1 &
SERVER_PID=$!
URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 240); do
  curl -fsS "$URL/health" >/dev/null 2>&1 && break
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$CHECK/server.log" >&2; die "server exited during startup"; }
  sleep 0.5
done
curl -fsS "$URL/health" >/dev/null || { tail -50 "$CHECK/server.log" >&2; die "/health did not answer"; }
say "/health after $(( $(now_ms) - START )) ms"
MODELS="$(curl -fsS -H "Authorization: Bearer $KEY" "$URL/v1/models")" || die "/v1/models failed"
printf '%s\n' "$MODELS"
if [[ -n "$MODEL_ID" ]]; then
  grep -q "\"$MODEL_ID\"" <<<"$MODELS" || die "/v1/models does not list $MODEL_ID"
  # Streamed, so the first content chunk marks the first token (model load included).
  FIRST_TOKEN=""
  while IFS= read -r line; do
    if [[ -z "$FIRST_TOKEN" && "$line" == *'content":"'[^\"]* ]]; then FIRST_TOKEN="$(now_ms)"; fi
    printf '%s\n' "$line" >>"$CHECK/reply.sse"
  done < <(curl -fsSN -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL_ID\",\"max_tokens\":32,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}]}" \
    "$URL/v1/chat/completions" || true)
  [[ -n "$FIRST_TOKEN" ]] || { cat "$CHECK/reply.sse" >&2 2>/dev/null; tail -30 "$CHECK/server.log" >&2; die "no reply"; }
  printf 'Reply: '
  "$RUNTIME/bin/python3" -I -c '
import json, sys
for line in open(sys.argv[1]):
    if line.startswith("data: {"):
        for c in json.loads(line[6:]).get("choices", []):
            sys.stdout.write((c.get("delta") or {}).get("content") or "")
print()' "$CHECK/reply.sse"
  say "first token $(( FIRST_TOKEN - START )) ms after starting the server"
fi
kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
say "done: $ARCHIVE"
