#!/usr/bin/env bash
# Publish a catalog model's pinned files as Pippa's download mirror on GitHub releases.
#
#   scripts/mirror-model.sh <catalog-key> [--dry-run]
#   scripts/mirror-model.sh ornith-1.5-9b-mlx-4bit --dry-run
#
# Pippa falls back to this mirror when the download from Hugging Face fails, and checks every file against the SHA-256
# pinned in catalog.json, so the mirror cannot slip in other bytes. The model needs `mirror` (release download URL with
# tag model-<key>-<revision[:7]>, partSize below 2 GiB) and `license` in catalog.json.
#
# Reads the pinned files from this Mac (Pippa's model folder, ~/.omlx/models/<repo>, the Hugging Face cache; only read,
# a copy that differs is skipped), checks size and SHA-256 of each, and stops if any file has no matching copy. Splits
# files above partSize into a work folder under $PIPPA_CACHE (default ~/Library/Caches/pippa-build), verifies the parts
# joined, then creates the pre-release (never "latest") with `gh release create` or adds the assets an existing one
# lacks, plus the model card (README.md of the pinned repo at the pinned revision) as MODEL-CARD.md.
# --dry-run only verifies the local files and shows what would be uploaded. Needs python3 and, to upload, gh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] || { sed -n '4,5p' "$0" | sed 's/^# *//' >&2; exit 2; }
exec python3 "$ROOT/scripts/mirror-model.py" "$@"
