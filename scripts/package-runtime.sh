#!/usr/bin/env bash
# Packages HarmonyEmulator into a portable release archive for macOS arm64 & Linux arm64.
# Usage:
#   ./scripts/package-runtime.sh [--output /path/to/HarmonyEmulator-arm64.tar.zst] [--without-images]
# Note: Use --without-images to package only binaries/scripts/PKI (~25 MB), or omit it to include
#       all dereferenced runtime images (~3-4 GB compressed, ready for 1-click offline deploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INCLUDE_IMAGES=1
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --output) OUT="$2"; shift 2 ;;
        --without-images) INCLUDE_IMAGES=0; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

COMPRESS_FLAG="-z"
EXT="tar.gz"
if command -v zstd >/dev/null 2>&1; then
    COMPRESS_FLAG="--zstd"
    EXT="tar.zst"
fi

if [ -z "$OUT" ]; then
    TAG=$([ "$INCLUDE_IMAGES" = "1" ] && echo "full" || echo "kit")
    OUT="$ROOT/HarmonyEmulator-${TAG}-arm64.${EXT}"
fi

ITEMS=(
    README.md
    Makefile
    install.sh
    scripts
    dashboard
    native
    build
    signing
    tools/signing
    dist
)
if [ "$INCLUDE_IMAGES" = "1" ]; then
    ITEMS+=(images)
fi

echo "Packaging ${ITEMS[*]} -> $OUT (dereferencing image symlinks, preserving sparse blocks)..."
TAR_EXTRA=()
if [ "$(uname -s)" = "Darwin" ]; then
    TAR_EXTRA+=(--no-xattrs --no-mac-metadata)
fi
(cd "$ROOT" && COPYFILE_DISABLE=1 tar ${TAR_EXTRA[@]+"${TAR_EXTRA[@]}"} -h --sparse "$COMPRESS_FLAG" -cf "$OUT" "${ITEMS[@]}")
(cd "$(dirname "$OUT")" && (sha256sum "$(basename "$OUT")" 2>/dev/null || shasum -a 256 "$(basename "$OUT")") > "$(basename "$OUT").sha256")
ls -lh "$OUT" "${OUT}.sha256"
