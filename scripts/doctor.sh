#!/usr/bin/env bash
# Environment, image, network, and Dashboard/MCP self-check for macOS arm64 & Linux arm64.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HMOS7_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LISTEN="${HMOS7_DASHBOARD_LISTEN:-127.0.0.1:18555}"
if [ "${1:-}" = "--listen" ] && [ -n "${2:-}" ]; then
    LISTEN="$2"
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
PASS=0
WARN=0
FAIL=0

ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
fail() { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "=== HarmonyEmulator Doctor (${OS}/${ARCH}) ==="
echo "Root: $ROOT"

case "$OS:$ARCH" in
    Darwin:arm64) ok "Host platform: macOS arm64 (Apple Silicon HVF)" ;;
    Linux:aarch64|Linux:arm64)
        ok "Host platform: Linux arm64"
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            ok "/dev/kvm accessible (hardware KVM acceleration enabled)"
        else
            warn "/dev/kvm not readable/writable (will fall back to slow TCG; run: sudo usermod -aG kvm \$USER)"
        fi
        ;;
    *) fail "Unsupported platform: ${OS}/${ARCH} (need macOS arm64 or Linux arm64)" ;;
esac

if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    ok "QEMU: $(qemu-system-aarch64 --version | head -n1)"
else
    fail "qemu-system-aarch64 not found in PATH"
fi

# Check bridged Ethernet readiness
if [ "$OS" = "Darwin" ]; then
    if [ -S /var/run/socket_vmnet_bridged ]; then
        ok "macOS L2 bridged Ethernet ready (/var/run/socket_vmnet_bridged)"
    elif [ -S /var/run/socket_vmnet ]; then
        warn "macOS vmnet shared ready (/var/run/socket_vmnet), L2 bridged not yet set up (run: sudo $ROOT/scripts/setup-bridged-macos.sh)"
    else
        warn "socket_vmnet not running (will use user-mode fallback; run: sudo $ROOT/scripts/setup-bridged-macos.sh)"
    fi
elif [ "$OS" = "Linux" ]; then
    BR="${HMOS7_BRIDGE:-br0}"
    if [ -d "/sys/class/net/$BR/bridge" ] && [ -f /etc/qemu/bridge.conf ] && grep -Eq "^[[:space:]]*allow[[:space:]]+(${BR}|all)[[:space:]]*$" /etc/qemu/bridge.conf; then
        ok "Linux L2 bridged Ethernet ready (bridge=$BR)"
    else
        warn "Linux bridge '$BR' not yet configured (will use user-mode fallback; run: sudo $ROOT/scripts/setup-bridged-linux.sh)"
    fi
fi

# Check hdc
HDC_FOUND=""
HDC_CANDS=("${HMOS7_HDC:-}" "$ROOT/tools/hdc" "$(command -v hdc 2>/dev/null || true)" "${OHOS_SDK_HOME:+${OHOS_SDK_HOME}/openharmony/toolchains/hdc}" "${DEVECO_SDK_HOME:+${DEVECO_SDK_HOME}/default/openharmony/toolchains/hdc}" "/opt/ohos-sdk/openharmony/toolchains/hdc")
for c in "${HDC_CANDS[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then
        HDC_FOUND="$c"
        break
    fi
done
if [ -n "$HDC_FOUND" ]; then
    ok "hdc: $HDC_FOUND"
else
    warn "hdc not found (set HMOS7_HDC or place hdc in $ROOT/tools/hdc or PATH)"
fi

# Check java & signing kit
if command -v java >/dev/null 2>&1 || { [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; }; then
    ok "Java runtime available for HAP signing"
else
    warn "java not found (needed for automatic .hap signing)"
fi
if [ -f "$ROOT/signing/hmos7.p12" ] && [ -f "$ROOT/tools/signing/hap-sign-tool.jar" ]; then
    ok "Private PKI + hap-sign-tool.jar bundled"
else
    warn "Signing kit incomplete under $ROOT/signing or $ROOT/tools/signing"
fi

# Resolve images_dir (HMOS7_IMAGES_DIR -> config.json -> $ROOT/images)
IMAGES_DIR="${HMOS7_IMAGES_DIR:-}"
if [ -z "$IMAGES_DIR" ] && [ -f "$ROOT/config.json" ] && command -v python3 >/dev/null 2>&1; then
    IMAGES_DIR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("images_dir",""))' "$ROOT/config.json" 2>/dev/null || true)"
fi
IMAGES_DIR="${IMAGES_DIR:-$ROOT/images}"
echo "Images: $IMAGES_DIR"

# Check runtime images (Phone profile)
PHONE_BASE="$IMAGES_DIR/phone"
[ -d "$PHONE_BASE" ] || PHONE_BASE="$IMAGES_DIR"
for rel in kernel/Image initramfs.cpio.gz qemu_overlay.img \
           donor/system.img donor/vendor.img donor/sys_prod.img donor/chip_prod.img donor/cust.img; do
    if [ -f "$PHONE_BASE/$rel" ]; then
        ok "Phone image: $rel ($(du -hL "$PHONE_BASE/$rel" | awk '{print $1}'))"
    else
        fail "Missing phone image: $PHONE_BASE/$rel"
    fi
done
if [ -f "$IMAGES_DIR/pc/donor/system.img" ] && [ -f "$IMAGES_DIR/pc/qemu_overlay.img" ]; then
    ok "PC image profile ready ($IMAGES_DIR/pc)"
else
    warn "PC image profile not configured under $IMAGES_DIR/pc (optional)"
fi
if [ -f "$PHONE_BASE/userdata-provisioned.img" ]; then
    ok "Image (optional skip-OOBE): userdata-provisioned.img ($(du -hL "$PHONE_BASE/userdata-provisioned.img" | awk '{print $1}'))"
else
    ok "Userdata: fresh 4G sparse ext4 will be auto-initialized on first boot"
fi

# Check prebuilt / installed dashboard binaries
for b in bin/harmony-emulator-dashboard dist/harmony-emulator-dashboard-darwin-arm64 dist/harmony-emulator-dashboard-linux-arm64; do
    if [ -x "$ROOT/$b" ]; then
        ok "Binary: $b ($(du -h "$ROOT/$b" | awk '{print $1}'))"
    fi
done

# Check live Dashboard & MCP if listening
if env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
       curl -fsS --max-time 2 "http://${LISTEN}/api/health" >/dev/null 2>&1; then
    ok "HarmonyEmulatorDashboard reachable at http://${LISTEN} (MCP: http://${LISTEN}/mcp)"
else
    warn "HarmonyEmulatorDashboard not currently listening on http://${LISTEN}"
fi

echo "Summary: ${PASS} ok, ${WARN} warnings, ${FAIL} failures"
[ "$FAIL" -eq 0 ]
