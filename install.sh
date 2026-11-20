#!/usr/bin/env bash
# HarmonyEmulator One-Click Installer for macOS arm64 (Apple Silicon) and Linux arm64 (aarch64).
# Usage:
#   ./install.sh [--listen 127.0.0.1:18555] [--images-from <dir|tar.zst|tar.gz>]
#                [--build] [--skip-deps] [--setup-bridged] [--install-service] [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
ARCH="$(uname -m)"

LISTEN="${HMOS7_DASHBOARD_LISTEN:-127.0.0.1:18555}"
IMAGES_FROM=""
FORCE_BUILD=0
SKIP_DEPS=0
SETUP_BRIDGED=0
INSTALL_SERVICE=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --listen) LISTEN="$2"; shift 2 ;;
        --images-from) IMAGES_FROM="$2"; shift 2 ;;
        --build) FORCE_BUILD=1; shift ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        --setup-bridged) SETUP_BRIDGED=1; shift ;;
        --install-service) INSTALL_SERVICE=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -h|--help)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$OS:$ARCH" in
    Darwin:arm64)
        PLATFORM="darwin-arm64"
        ;;
    Linux:aarch64|Linux:arm64)
        PLATFORM="linux-arm64"
        ;;
    *)
        echo "ERROR: Unsupported platform ${OS}/${ARCH}. HarmonyEmulator requires macOS arm64 or Linux arm64." >&2
        exit 1
        ;;
esac

echo "=== HarmonyEmulator One-Click Deploy (${PLATFORM}) ==="
echo "Project root : $ROOT"
echo "Dashboard    : http://${LISTEN}  (MCP: http://${LISTEN}/mcp)"

if [ "$CHECK_ONLY" = "1" ]; then
    exec "$ROOT/scripts/doctor.sh" --listen "$LISTEN"
fi

# 1. Install runtime dependencies if missing
if [ "$SKIP_DEPS" = "0" ]; then
    if [ "$PLATFORM" = "darwin-arm64" ]; then
        if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
            if ! command -v brew >/dev/null 2>&1; then
                echo "ERROR: Homebrew is required on macOS to install qemu. Visit https://brew.sh" >&2
                exit 1
            fi
            echo "[1/5] Installing qemu via Homebrew..."
            brew install qemu
        else
            echo "[1/5] qemu-system-aarch64 already installed ($(qemu-system-aarch64 --version | head -n1))"
        fi
        if ! command -v socket_vmnet >/dev/null 2>&1 && [ ! -x /opt/socket_vmnet/bin/socket_vmnet ]; then
            echo "      Note: for L2 bridged Ethernet (no NAT), install socket_vmnet: brew install socket_vmnet"
        fi
    else
        NEED_PKGS=()
        command -v qemu-system-aarch64 >/dev/null 2>&1 || NEED_PKGS+=(qemu-system-arm qemu-utils)
        command -v python3 >/dev/null 2>&1 || NEED_PKGS+=(python3)
        command -v curl >/dev/null 2>&1 || NEED_PKGS+=(curl)
        command -v java >/dev/null 2>&1 || NEED_PKGS+=(openjdk-17-jre-headless)
        if [ ${#NEED_PKGS[@]} -gt 0 ]; then
            echo "[1/5] Installing Linux arm64 runtime packages: ${NEED_PKGS[*]}"
            SUDO=""
            [ "$(id -u)" -ne 0 ] && SUDO="sudo"
            if command -v apt-get >/dev/null 2>&1; then
                $SUDO apt-get update -y
                $SUDO apt-get install -y "${NEED_PKGS[@]}" bridge-utils iproute2
            elif command -v dnf >/dev/null 2>&1; then
                $SUDO dnf install -y qemu-system-aarch64 qemu-img python3 curl java-17-openjdk-headless iproute
            elif command -v pacman >/dev/null 2>&1; then
                $SUDO pacman -Sy --noconfirm qemu-system-aarch64 python curl jre17-openjdk-headless iproute2
            else
                echo "WARN: Unknown package manager; please install qemu-system-aarch64, python3, curl, java manually." >&2
            fi
        else
            echo "[1/5] Linux arm64 dependencies already installed ($(qemu-system-aarch64 --version | head -n1))"
        fi
        if [ -e /dev/kvm ] && { [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; }; then
            echo "      NOTE: /dev/kvm is not accessible by $(id -un). Run: sudo usermod -aG kvm $(id -un) && newgrp kvm"
        fi
    fi
else
    echo "[1/5] Skipping OS package check (--skip-deps)"
fi

# 2. Import or link runtime images if --images-from was given
if [ -n "$IMAGES_FROM" ]; then
    echo "[2/5] Importing runtime images from $IMAGES_FROM..."
    mkdir -p "$ROOT/images/kernel" "$ROOT/images/donor"
    if [ -f "$IMAGES_FROM" ]; then
        case "$IMAGES_FROM" in
            *.tar.zst) tar --zstd -xf "$IMAGES_FROM" -C "$ROOT" ;;
            *.tar.gz|*.tgz) tar -xzf "$IMAGES_FROM" -C "$ROOT" ;;
            *.tar) tar -xf "$IMAGES_FROM" -C "$ROOT" ;;
            *) echo "ERROR: unsupported archive format: $IMAGES_FROM" >&2; exit 2 ;;
        esac
    elif [ -d "$IMAGES_FROM" ]; then
        # Support either HarmonyEmulator/images layout or raw hmos7-qemu layout
        if [ -f "$IMAGES_FROM/kernel/Image" ]; then
            ln -sfn "$IMAGES_FROM/kernel/Image" "$ROOT/images/kernel/Image"
            ln -sfn "$IMAGES_FROM/initramfs.cpio.gz" "$ROOT/images/initramfs.cpio.gz"
            ln -sfn "$IMAGES_FROM/qemu_overlay.img" "$ROOT/images/qemu_overlay.img"
            [ -f "$IMAGES_FROM/userdata-provisioned.img" ] && ln -sfn "$IMAGES_FROM/userdata-provisioned.img" "$ROOT/images/userdata-provisioned.img"
            for part in system vendor sys_prod chip_prod cust; do
                ln -sfn "$IMAGES_FROM/donor/${part}.img" "$ROOT/images/donor/${part}.img"
            done
        elif [ -f "$IMAGES_FROM/out/kernel/Image" ]; then
            ln -sfn "$IMAGES_FROM/out/kernel/Image" "$ROOT/images/kernel/Image"
            ln -sfn "$IMAGES_FROM/out/initramfs.cpio.gz" "$ROOT/images/initramfs.cpio.gz"
            ln -sfn "$IMAGES_FROM/out/qemu_overlay.img" "$ROOT/images/qemu_overlay.img"
            [ -f "$IMAGES_FROM/out/userdata-provisioned.img" ] && ln -sfn "$IMAGES_FROM/out/userdata-provisioned.img" "$ROOT/images/userdata-provisioned.img"
            for part in system vendor sys_prod chip_prod cust; do
                ln -sfn "$IMAGES_FROM/donor/pura70proplus-7.0.0.107/images/${part}.img" "$ROOT/images/donor/${part}.img"
            done
        else
            echo "ERROR: unrecognized images directory: $IMAGES_FROM" >&2
            exit 2
        fi
    else
        echo "ERROR: --images-from path not found: $IMAGES_FROM" >&2
        exit 2
    fi
else
    echo "[2/5] Using existing runtime images in $ROOT/images"
fi

# 3. Install or compile HarmonyEmulatorDashboard binary for this platform
mkdir -p "$ROOT/bin" "$ROOT/instances" "$ROOT/logs"
PREBUILT="$ROOT/dist/harmony-emulator-dashboard-${PLATFORM}"
TARGET_BIN="$ROOT/bin/harmony-emulator-dashboard"

if [ "$FORCE_BUILD" = "0" ] && [ -x "$PREBUILT" ]; then
    echo "[3/5] Installing prebuilt binary: $PREBUILT -> $TARGET_BIN"
    rm -f "$TARGET_BIN"
    cp "$PREBUILT" "$TARGET_BIN"
    chmod +x "$TARGET_BIN"
else
    if ! command -v go >/dev/null 2>&1; then
        echo "ERROR: prebuilt binary $PREBUILT missing and 'go' is not installed." >&2
        exit 1
    fi
    echo "[3/5] Building HarmonyEmulatorDashboard from source ($ROOT/dashboard)..."
    (cd "$ROOT/dashboard" && CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -o "$TARGET_BIN" .)
    chmod +x "$TARGET_BIN"
fi
chmod +x "$ROOT/scripts/"*.sh

# 4. Optional L2 bridged networking setup (requires sudo)
if [ "$SETUP_BRIDGED" = "1" ]; then
    echo "[4/5] Configuring L2 bridged Ethernet (no NAT)..."
    if [ "$PLATFORM" = "darwin-arm64" ]; then
        sudo "$ROOT/scripts/setup-bridged-macos.sh"
    else
        sudo "$ROOT/scripts/setup-bridged-linux.sh"
    fi
else
    echo "[4/5] Bridged Ethernet setup skipped (run with --setup-bridged when ready for L2 bridge)"
fi

# 5. Optional persistent background service (launchd / systemd)
if [ "$INSTALL_SERVICE" = "1" ]; then
    echo "[5/5] Installing and starting HarmonyEmulatorDashboard service..."
    "$ROOT/scripts/install-service.sh" --listen "$LISTEN"
else
    echo "[5/5] Service install skipped (start manually with: $TARGET_BIN --listen $LISTEN --root $ROOT)"
fi

echo ""
"$ROOT/scripts/doctor.sh" --listen "$LISTEN" || true

cat <<EOF

=== Next Steps ===
1. Start Dashboard (if not installed as a service):
   $TARGET_BIN --listen $LISTEN --root $ROOT

2. Open Web Console:
   http://${LISTEN}

3. Connect Fancy / Claude / Cursor via MCP:
   {
     "mcpServers": {
       "harmony_emulator": {
         "type": "http",
         "url": "http://${LISTEN}/mcp"
       }
     }
   }
EOF
