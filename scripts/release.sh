#!/usr/bin/env bash
# Prepares a signed/notarized update and appcast.xml strictly locally.
# No push, no GitHub release, no tag and no CI. Publishing must be requested separately.
# PIPPA_SIGN_IDENTITY='Developer ID Application: …' PIPPA_NOTARY_PROFILE=pippa-notary scripts/release.sh [tag]
# PIPPA_NO_SPARKLE=1: a Mac without the Sparkle key builds the signed, notarized DMG but no update signature and no
# appcast.xml, so installed copies are not offered this release.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ "${PIPPA_SIGN_IDENTITY:-}" == 'Developer ID Application:'* ]] || die 'PIPPA_SIGN_IDENTITY with a Developer ID Application is missing'
[[ -n "${PIPPA_NOTARY_PROFILE:-}" ]] || die 'PIPPA_NOTARY_PROFILE is missing'
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || die 'commit the working tree locally first; a release must match a clean commit'
VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/app/Sources/PippaCore/PippaCore.swift" | head -1)"
# Build number = base + commit count. The base keeps builds above those of the archived repository (up to 282)
# now that the public repository starts with a single commit; Sparkle only offers higher builds.
COMMITS="$(git -C "$ROOT" rev-list --count HEAD)"
BUILD="$(( $(tr -d '[:space:]' < "$ROOT/app/Packaging/build-number-base") + COMMITS ))"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TAG="${1:-v$VERSION-$BUILD}"
[[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'tag may only contain letters, digits, dot, underscore and hyphen'
RELEASE="$ROOT/dist/releases/$TAG"
[[ ! -e "$RELEASE" ]] || die "release folder already exists: $RELEASE"

NO_SPARKLE="${PIPPA_NO_SPARKLE:-0}"
[[ "$NO_SPARKLE" == 0 || "$NO_SPARKLE" == 1 ]] || die 'PIPPA_NO_SPARKLE must be 0 or 1'
if [[ "$NO_SPARKLE" == 1 ]]; then
  printf 'Warning: PIPPA_NO_SPARKLE=1: no update signature and no appcast.xml. Installed copies will not be offered this release.\n' >&2
  printf '         Attach the previous release'"'"'s appcast.xml unchanged, so the update feed (releases/latest) keeps working.\n' >&2
else
  # Resolve only the pinned Sparkle tools; never generate/replace a signing key here.
  swift package --package-path "$ROOT/app" resolve
  SPARKLE_TOOLS="$ROOT/app/.build/artifacts/sparkle/Sparkle/bin"
  [[ -x "$SPARKLE_TOOLS/sign_update" && -x "$SPARKLE_TOOLS/generate_keys" ]] || die 'pinned Sparkle tools are missing'
  ACCOUNT="${PIPPA_SPARKLE_ACCOUNT:-ed25519}"
  PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" --account "$ACCOUNT" -p)" || die 'existing Sparkle key in the Keychain is not readable'
  EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/app/Packaging/Info.plist")"
  [[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || die 'Sparkle key does not match SUPublicEDKey; do not generate a new key for existing users'
fi

export PIPPA_REQUIRE_DISTRIBUTION=1
"$ROOT/scripts/build-app.sh"
"$ROOT/scripts/make-dmg.sh"
"$ROOT/scripts/verify-app.sh"
# Notary submission can take time; do not archive files if the source changed meanwhile.
[[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]] || die 'sources changed during the build; prepare the release again'
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$COMMIT" ]] || die 'commit changed during the build; prepare the release again'
mkdir -p "$ROOT/dist/releases"
STAGE="$(mktemp -d "$ROOT/dist/releases/.prepare.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ASSET="Pippa-$VERSION-$BUILD.dmg"
cp "$ROOT/dist/Pippa.dmg" "$STAGE/$ASSET"
# Stable name for the website link releases/latest/download/Pippa.dmg.
cp "$STAGE/$ASSET" "$STAGE/Pippa.dmg"
if [[ "$NO_SPARKLE" == 0 ]]; then
  SIGNATURE="$("$SPARKLE_TOOLS/sign_update" --account "$ACCOUNT" -p "$STAGE/$ASSET")"
  "$SPARKLE_TOOLS/sign_update" --account "$ACCOUNT" --verify "$STAGE/$ASSET" "$SIGNATURE"
  python3 "$ROOT/scripts/write-appcast.py" "$ROOT/dist/Pippa.app/Contents/Info.plist" \
    "$STAGE/$ASSET" "$TAG" "$SIGNATURE" "$STAGE/appcast.xml"
fi
(cd "$STAGE" && shasum -a 256 "$ASSET" Pippa.dmg > SHA256SUMS)
printf '%s\n' "$COMMIT" > "$STAGE/commit.txt"
mv "$STAGE" "$RELEASE"
if [[ "$NO_SPARKLE" == 1 ]]; then
  printf 'Ready locally WITHOUT update feed: %s\nPublish it with the previous release'"'"'s appcast.xml; installed copies are not updated. That requires an explicit request.\n' "$RELEASE"
else
  printf 'Ready locally: %s\nPublish the update and appcast.xml together as one GitHub release; that requires an explicit request.\n' "$RELEASE"
fi
