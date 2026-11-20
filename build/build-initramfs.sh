#!/bin/bash
# Builds out/initramfs.cpio.gz on Linux ARM64 (or inside an ARM64 Linux build VM).
set -euo pipefail
ROOT="${HMOS7_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${HMOS7_OUT:-$ROOT/out}"
BUILD="$ROOT/build"
WORK=/tmp/hmos7-initramfs

rm -rf "$WORK"
mkdir -p "$WORK"/{bin,sbin,lib/modules,proc,sys,dev,tmp,run,hmos,qoverlay,data,hmos-root,hmos-ram}
cp /bin/busybox "$WORK/bin/busybox"
chmod 0755 "$WORK/bin/busybox"
cp "$BUILD/m1-init.sh" "$WORK/init"
chmod 0755 "$WORK/init"
cp "$OUT/kernel/kstate.ko" "$WORK/lib/modules/kstate.ko"
cp "$OUT/kernel/hwlog.ko" "$WORK/lib/modules/hwlog.ko"
cp "$OUT/kernel/ashmem.ko" "$WORK/lib/modules/ashmem.ko"

(cd "$WORK" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUT/initramfs.cpio.gz")
ls -lh "$OUT/initramfs.cpio.gz"
