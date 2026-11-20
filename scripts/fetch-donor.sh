#!/usr/bin/env bash
# Downloads and extracts the 5 required HarmonyOS 7.0.0.107 donor partitions
# (system, vendor, sys_prod, chip_prod, cust) from Huawei's public OTA CDN,
# or from a local update_full_base.zip, and verifies every SHA-256 checksum.
# Works identically on macOS arm64 and Linux arm64 (pure Python + curl + unzip).
#
# Usage:
#   ./scripts/fetch-donor.sh [path/to/update_full_base.zip]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HMOS7_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DONOR_DIR="$ROOT/images/donor"
CACHE_DIR="${HMOS7_CACHE_DIR:-$ROOT/.cache}"
LOCAL_ZIP="${1:-}"

OTA_URL="${HMOS7_DONOR_URL:-http://update.dbankcdn.com/download/data/pub_13/HWHOTA_hota_900_9/6e/v3/v8JuxUb2TBejup8P2vgrrQ/full/update_full_base.zip}"
OTA_SHA256="36fbb2d601ddf94a4b6542f5a58ecf5337344c0ad3cdd2090e4e894e771a154b"
UNPACK_REPO="https://github.com/SimomYung/unpack_huawei_package.git"
UNPACK_COMMIT="928e61839a521218bcc13a2c4e62661bc212bc8d"

PARTS=(system vendor sys_prod chip_prod cust)
SHA_system="cd8b37e61483c56717babf3c566fef924a4260a475a44ed0005ae0a27b006475"
SHA_vendor="16a2ef3a9c8de4a8d1fd9e9b17ab05af4b8f4e329815696154aa39bbaa7d8387"
SHA_sys_prod="718cb64342be63028b84785a54736bf43ee9ff7d18dc10cac10be12279619c33"
SHA_chip_prod="b1041fd7183159e8b52166053645f86ecb1463285ddfd4690acd39c75fb293b3"
SHA_cust="71c4a679c702ada36d24203d72c5f05a353ee07a2f6f8619ecc507adabc22d59"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

expected_sha() {
    eval "printf '%s' \"\$SHA_$1\""
}

# Fast path: skip if all 5 donor partitions already exist and match SHA-256
ALL_OK=1
for p in "${PARTS[@]}"; do
    f="$DONOR_DIR/${p}.img"
    if [ ! -f "$f" ]; then
        ALL_OK=0
        break
    fi
done
if [ "$ALL_OK" = "1" ]; then
    echo "Verifying existing 5 donor images in $DONOR_DIR..."
    BAD=0
    for p in "${PARTS[@]}"; do
        got="$(sha256_file "$DONOR_DIR/${p}.img")"
        want="$(expected_sha "$p")"
        if [ "$got" != "$want" ]; then
            echo "  MISMATCH ${p}.img: got $got want $want" >&2
            BAD=1
        fi
    done
    if [ "$BAD" = "0" ]; then
        echo "OK: all 5 donor partitions verified."
        exit 0
    fi
fi

for cmd in curl unzip python3 git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is required to fetch and unpack donor images." >&2
        exit 1
    fi
done

mkdir -p "$DONOR_DIR" "$CACHE_DIR"

ZIP_PATH="$LOCAL_ZIP"
if [ -z "$ZIP_PATH" ]; then
    ZIP_PATH="$CACHE_DIR/update_full_base.zip"
    echo "Downloading Huawei Pura 70 Pro+ 7.0.0.107 base OTA (~6.6 GiB, supports resume)..."
    echo "  URL: $OTA_URL"
    curl -fL -C - --progress-bar "$OTA_URL" -o "$ZIP_PATH"
fi

echo "Verifying update_full_base.zip SHA-256..."
ZIP_SHA="$(sha256_file "$ZIP_PATH")"
if [ "$ZIP_SHA" != "$OTA_SHA256" ]; then
    echo "ERROR: update_full_base.zip SHA-256 mismatch!" >&2
    echo "  got : $ZIP_SHA" >&2
    echo "  want: $OTA_SHA256" >&2
    exit 1
fi

UNPACK_DIR="$CACHE_DIR/unpack_huawei_package"
if [ ! -d "$UNPACK_DIR/.git" ]; then
    echo "Fetching unpack_huawei_package (pinned commit $UNPACK_COMMIT)..."
    git clone -q "$UNPACK_REPO" "$UNPACK_DIR"
    git -C "$UNPACK_DIR" -c advice.detachedHead=false checkout -q "$UNPACK_COMMIT"
fi

WORK_DIR="$CACHE_DIR/unpack-work"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Extracting update.bin from update_full_base.zip..."
unzip -p "$ZIP_PATH" update.bin > "$WORK_DIR/update.bin"

echo "Unpacking HarmonyOS partition images from update.bin (this takes 1-3 minutes)..."
(cd "$WORK_DIR" && python3 -I "$UNPACK_DIR/unpack_huawei_package.py")
rm -f "$WORK_DIR/update.bin"

echo "Moving and verifying the 5 required donor partitions..."
for p in "${PARTS[@]}"; do
    src="$WORK_DIR/${p}.img"
    dst="$DONOR_DIR/${p}.img"
    if [ ! -f "$src" ]; then
        echo "ERROR: expected partition ${p}.img not found in unpacked update.bin" >&2
        exit 1
    fi
    got="$(sha256_file "$src")"
    want="$(expected_sha "$p")"
    if [ "$got" != "$want" ]; then
        echo "ERROR: ${p}.img SHA-256 mismatch: got $got want $want" >&2
        exit 1
    fi
    mv -f "$src" "$dst"
    echo "  [OK] ${p}.img ($(du -h "$dst" | awk '{print $1}'))"
done

if [ -z "$LOCAL_ZIP" ] && [ "${HMOS7_KEEP_OTA_ZIP:-0}" != "1" ]; then
    rm -f "$ZIP_PATH"
fi

echo "OK: all 5 HarmonyOS 7.0.0.107 donor partitions are ready in $DONOR_DIR"
