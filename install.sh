#!/usr/bin/env bash
# HarmonyEmulator One-Click Installer for macOS arm64 (Apple Silicon) and Linux arm64 (aarch64).
# Usage:
#   ./install.sh [--listen 127.0.0.1:18555] [--release v0.1.0] [--images-from <dir|tar.zst|tar.gz>]
#                [--donor-zip <update_full_base.zip>] [--skip-donor]
#                [--build] [--skip-deps] [--setup-bridged] [--install-service] [--check]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
ARCH="$(uname -m)"

LISTEN="${HMOS7_DASHBOARD_LISTEN:-127.0.0.1:18555}"
RELEASE_REPO="${HMOS7_RELEASE_REPO:-FrankHan052176/HarmonyEmulator}"
RELEASE_TAG="${HMOS7_RELEASE_TAG:-v0.1.0}"
RELEASE_BASE="${HMOS7_RELEASE_URL:-https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}}"
IMAGES_FROM=""
DONOR_ZIP=""
SKIP_DONOR=0
FORCE_BUILD=0
SKIP_DEPS=0
SETUP_BRIDGED=0
INSTALL_SERVICE=0
CHECK_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --listen) LISTEN="$2"; shift 2 ;;
        --release) RELEASE_TAG="$2"; RELEASE_BASE="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}"; shift 2 ;;
        --images-from) IMAGES_FROM="$2"; shift 2 ;;
        --donor-zip) DONOR_ZIP="$2"; shift 2 ;;
        --skip-donor) SKIP_DONOR=1; shift ;;
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
    Darwin:arm64) PLATFORM="darwin-arm64" ;;
    Linux:aarch64|Linux:arm64) PLATFORM="linux-arm64" ;;
    *)
        echo "ERROR: Unsupported platform ${OS}/${ARCH}. HarmonyEmulator requires macOS arm64 or Linux arm64." >&2
        exit 1
        ;;
esac

echo "=== HarmonyEmulator One-Click Deploy (${PLATFORM}) ==="
echo "Project root : $ROOT"
echo "Release      : ${RELEASE_REPO}@${RELEASE_TAG}"
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
            echo "[1/6] Installing qemu via Homebrew..."
            brew install qemu
        else
            echo "[1/6] qemu-system-aarch64 already installed ($(qemu-system-aarch64 --version | head -n1))"
        fi
        if ! command -v socket_vmnet >/dev/null 2>&1 && [ ! -x /opt/socket_vmnet/bin/socket_vmnet ]; then
            echo "      Note: for L2 bridged Ethernet (no NAT), install socket_vmnet: brew install socket_vmnet"
        fi
    else
        NEED_PKGS=()
        command -v qemu-system-aarch64 >/dev/null 2>&1 || NEED_PKGS+=(qemu-system-arm qemu-utils)
        command -v python3 >/dev/null 2>&1 || NEED_PKGS+=(python3)
        command -v curl >/dev/null 2>&1 || NEED_PKGS+=(curl)
        command -v unzip >/dev/null 2>&1 || NEED_PKGS+=(unzip)
        command -v java >/dev/null 2>&1 || NEED_PKGS+=(openjdk-17-jre-headless)
        if [ ${#NEED_PKGS[@]} -gt 0 ]; then
            echo "[1/6] Installing Linux arm64 runtime packages: ${NEED_PKGS[*]}"
            SUDO=""
            [ "$(id -u)" -ne 0 ] && SUDO="sudo"
            if command -v apt-get >/dev/null 2>&1; then
                $SUDO apt-get update -y
                $SUDO apt-get install -y "${NEED_PKGS[@]}" bridge-utils iproute2
            elif command -v dnf >/dev/null 2>&1; then
                $SUDO dnf install -y qemu-system-aarch64 qemu-img python3 curl unzip java-17-openjdk-headless iproute
            elif command -v pacman >/dev/null 2>&1; then
                $SUDO pacman -Sy --noconfirm qemu-system-aarch64 python curl unzip jre17-openjdk-headless iproute2
            else
                echo "WARN: Unknown package manager; please install qemu-system-aarch64, python3, curl, unzip, java manually." >&2
            fi
        else
            echo "[1/6] Linux arm64 dependencies already installed ($(qemu-system-aarch64 --version | head -n1))"
        fi
        if [ -e /dev/kvm ] && { [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; }; then
            echo "      NOTE: /dev/kvm is not accessible by $(id -un). Run: sudo usermod -aG kvm $(id -un) && newgrp kvm"
        fi
    fi
else
    echo "[1/6] Skipping OS package check (--skip-deps)"
fi

mkdir -p "$ROOT/bin" "$ROOT/dist" "$ROOT/images/kernel" "$ROOT/images/donor" "$ROOT/instances" "$ROOT/logs" "$ROOT/.cache"
chmod +x "$ROOT/scripts/"*.sh

# 2. Import local runtime images if --images-from was given
if [ -n "$IMAGES_FROM" ]; then
    echo "[2/6] Importing runtime images from $IMAGES_FROM..."
    if [ -f "$IMAGES_FROM" ]; then
        case "$IMAGES_FROM" in
            *.tar.zst) tar --zstd -xf "$IMAGES_FROM" -C "$ROOT" ;;
            *.tar.gz|*.tgz) tar -xzf "$IMAGES_FROM" -C "$ROOT" ;;
            *.tar) tar -xf "$IMAGES_FROM" -C "$ROOT" ;;
            *) echo "ERROR: unsupported archive format: $IMAGES_FROM" >&2; exit 2 ;;
        esac
    elif [ -d "$IMAGES_FROM" ]; then
        if [ -f "$IMAGES_FROM/kernel/Image" ]; then
            ln -sfn "$IMAGES_FROM/kernel/Image" "$ROOT/images/kernel/Image"
            ln -sfn "$IMAGES_FROM/initramfs.cpio.gz" "$ROOT/images/initramfs.cpio.gz"
            ln -sfn "$IMAGES_FROM/qemu_overlay.img" "$ROOT/images/qemu_overlay.img"
            [ -f "$IMAGES_FROM/userdata-provisioned.img" ] && ln -sfn "$IMAGES_FROM/userdata-provisioned.img" "$ROOT/images/userdata-provisioned.img"
            for part in system vendor sys_prod chip_prod cust; do
                [ -f "$IMAGES_FROM/donor/${part}.img" ] && ln -sfn "$IMAGES_FROM/donor/${part}.img" "$ROOT/images/donor/${part}.img"
            done
        elif [ -f "$IMAGES_FROM/out/kernel/Image" ]; then
            ln -sfn "$IMAGES_FROM/out/kernel/Image" "$ROOT/images/kernel/Image"
            ln -sfn "$IMAGES_FROM/out/initramfs.cpio.gz" "$ROOT/images/initramfs.cpio.gz"
            ln -sfn "$IMAGES_FROM/out/qemu_overlay.img" "$ROOT/images/qemu_overlay.img"
            [ -f "$IMAGES_FROM/out/userdata-provisioned.img" ] && ln -sfn "$IMAGES_FROM/out/userdata-provisioned.img" "$ROOT/images/userdata-provisioned.img"
            for part in system vendor sys_prod chip_prod cust; do
                [ -f "$IMAGES_FROM/donor/pura70proplus-7.0.0.107/images/${part}.img" ] && ln -sfn "$IMAGES_FROM/donor/pura70proplus-7.0.0.107/images/${part}.img" "$ROOT/images/donor/${part}.img"
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
    echo "[2/6] Checking runtime boot/overlay images..."
fi

# Auto-download boot/overlay + signing kit from GitHub Release if missing
if [ ! -f "$ROOT/images/kernel/Image" ] || [ ! -f "$ROOT/images/initramfs.cpio.gz" ] || [ ! -f "$ROOT/images/qemu_overlay.img" ]; then
    BOOT_TAR="$ROOT/.cache/hmos7-boot-overlay-arm64.tar.gz"
    echo "      Downloading hmos7-boot-overlay-arm64.tar.gz from ${RELEASE_BASE}..."
    curl -fL -C - --progress-bar "${RELEASE_BASE}/hmos7-boot-overlay-arm64.tar.gz" -o "$BOOT_TAR"
    tar -xzf "$BOOT_TAR" -C "$ROOT"
    rm -f "$BOOT_TAR"
fi

# 3. Ensure 5 Huawei Pura 70 Pro+ 7.0.0.107 donor partitions exist (auto-fetch from Huawei public CDN)
if [ "$SKIP_DONOR" = "0" ]; then
    NEED_DONOR=0
    for part in system vendor sys_prod chip_prod cust; do
        [ -f "$ROOT/images/donor/${part}.img" ] || NEED_DONOR=1
    done
    if [ "$NEED_DONOR" = "1" ]; then
        echo "[3/6] Fetching & extracting HarmonyOS 7.0.0.107 donor partitions (system/vendor/sys_prod/chip_prod/cust)..."
        if [ -n "$DONOR_ZIP" ]; then
            "$ROOT/scripts/fetch-donor.sh" "$DONOR_ZIP"
        else
            "$ROOT/scripts/fetch-donor.sh"
        fi
    else
        echo "[3/6] All 5 donor partitions already present in $ROOT/images/donor"
    fi
else
    echo "[3/6] Skipping donor firmware fetch (--skip-donor)"
fi

# 4. Install, download, or compile HarmonyEmulatorDashboard binary for this platform
PREBUILT="$ROOT/dist/harmony-emulator-dashboard-${PLATFORM}"
TARGET_BIN="$ROOT/bin/harmony-emulator-dashboard"

if [ "$FORCE_BUILD" = "0" ] && [ ! -x "$PREBUILT" ]; then
    echo "[4/6] Downloading prebuilt binary harmony-emulator-dashboard-${PLATFORM} from ${RELEASE_BASE}..."
    if curl -fL --progress-bar "${RELEASE_BASE}/harmony-emulator-dashboard-${PLATFORM}" -o "$PREBUILT"; then
        chmod +x "$PREBUILT"
    else
        rm -f "$PREBUILT"
    fi
fi

if [ "$FORCE_BUILD" = "0" ] && [ -x "$PREBUILT" ]; then
    echo "[4/6] Installing prebuilt binary: $PREBUILT -> $TARGET_BIN"
    rm -f "$TARGET_BIN"
    cp "$PREBUILT" "$TARGET_BIN"
    chmod +x "$TARGET_BIN"
else
    if ! command -v go >/dev/null 2>&1; then
        echo "ERROR: prebuilt binary unavailable and 'go' is not installed." >&2
        exit 1
    fi
    echo "[4/6] Building HarmonyEmulatorDashboard from source ($ROOT/dashboard)..."
    (cd "$ROOT/dashboard" && CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -o "$TARGET_BIN" .)
    chmod +x "$TARGET_BIN"
fi

# 5. Optional L2 bridged networking setup (requires sudo)
if [ "$SETUP_BRIDGED" = "1" ]; then
    echo "[5/6] Configuring L2 bridged Ethernet (no NAT)..."
    if [ "$PLATFORM" = "darwin-arm64" ]; then
        sudo "$ROOT/scripts/setup-bridged-macos.sh"
    else
        sudo "$ROOT/scripts/setup-bridged-linux.sh"
    fi
else
    echo "[5/6] Bridged Ethernet setup skipped (run with --setup-bridged when ready for L2 bridge)"
fi

# 6. Optional persistent background service (launchd / systemd)
if [ "$INSTALL_SERVICE" = "1" ]; then
    echo "[6/6] Installing and starting HarmonyEmulatorDashboard service..."
    "$ROOT/scripts/install-service.sh" --listen "$LISTEN"
else
    echo "[6/6] Service install skipped (start manually with: $TARGET_BIN --listen $LISTEN --root $ROOT)"
fi

echo ""
"$ROOT/scripts/doctor.sh" --listen "$LISTEN" || true

cat <<EOF

=== 部署完成 / 下一步 ===
1. 启动独立控制台服务（若未加 --install-service）：
   $TARGET_BIN --listen $LISTEN --root $ROOT

2. 打开 Web 控制台操作和体验模拟器：
   http://${LISTEN}

3. 接入 Fancy / Claude / Cursor MCP：
   {
     "mcpServers": {
       "harmony_emulator": {
         "type": "http",
         "url": "http://${LISTEN}/mcp"
       }
     }
   }
EOF
