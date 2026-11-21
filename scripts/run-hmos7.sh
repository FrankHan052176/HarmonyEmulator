#!/usr/bin/env bash
# Cross-platform HarmonyOS 7.0.0.107 QEMU arm64_virt launcher for macOS arm64 (HVF) and Linux arm64 (KVM).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="${HMOS7_ROOT:-$DEFAULT_ROOT}"

# Resolve image paths (supports both HarmonyEmulator/images/ layout and legacy hmos7-qemu/out/ layout)
resolve_file() {
    for p in "$@"; do
        if [ -f "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    printf '%s' "$1"
}

resolve_dir() {
    for p in "$@"; do
        if [ -d "$p" ]; then
            printf '%s' "$p"
            return 0
        fi
    done
    printf '%s' "$1"
}

PROFILE="${HMOS7_PROFILE:-phone}"       # phone | pc
IMAGES_DIR="${HMOS7_IMAGES_DIR:-$ROOT/images}"
INSTANCES_DIR="${HMOS7_INSTANCES_DIR:-$ROOT/instances}"
PROF_DIR="$IMAGES_DIR/$PROFILE"

if [ "$PROFILE" = "pc" ]; then
    DEFAULT_W=1920; DEFAULT_H=1080; DEFAULT_MEM=8192; DEFAULT_DATA_GB=16
    PROVISIONED_IMG="${HMOS7_PROVISIONED_IMG:-$PROF_DIR/userdata-provisioned.img}"
    DONOR_IMGS="${HMOS7_DONOR_IMGS:-$PROF_DIR/donor}"
else
    DEFAULT_W=1080; DEFAULT_H=2340; DEFAULT_MEM=6144; DEFAULT_DATA_GB=4
    PROVISIONED_IMG="${HMOS7_PROVISIONED_IMG:-$(resolve_file "$PROF_DIR/userdata-provisioned.img" "$IMAGES_DIR/userdata-provisioned.img" "$IMAGES_DIR/out/userdata-provisioned.img" "$ROOT/images/userdata-provisioned.img" "$ROOT/out/userdata-provisioned.img")}"
    DONOR_IMGS="${HMOS7_DONOR_IMGS:-$(resolve_dir "$PROF_DIR/donor" "$IMAGES_DIR/donor" "$IMAGES_DIR/donor/pura70proplus-7.0.0.107/images" "$ROOT/images/donor" "$ROOT/donor/pura70proplus-7.0.0.107/images")}"
fi

KERNEL="${HMOS7_KERNEL:-$(resolve_file "$PROF_DIR/kernel/Image" "$IMAGES_DIR/kernel/Image" "$IMAGES_DIR/out/kernel/Image" "$ROOT/images/kernel/Image" "$ROOT/out/kernel/Image")}"
INITRD="${HMOS7_INITRD:-$(resolve_file "$PROF_DIR/initramfs.cpio.gz" "$IMAGES_DIR/initramfs.cpio.gz" "$IMAGES_DIR/out/initramfs.cpio.gz" "$ROOT/images/initramfs.cpio.gz" "$ROOT/out/initramfs.cpio.gz")}"
OVERLAY_IMG="${HMOS7_OVERLAY_IMG:-$(resolve_file "$PROF_DIR/qemu_overlay.img" "$IMAGES_DIR/qemu_overlay.img" "$IMAGES_DIR/out/qemu_overlay.img" "$ROOT/images/qemu_overlay.img" "$ROOT/out/qemu_overlay.img")}"

INSTANCE="${HMOS7_INSTANCE:-default}"
INST_DIR="$INSTANCES_DIR/$INSTANCE"
USERDATA_IMG="$INST_DIR/userdata.img"

HDC_PORT="${HMOS7_HDC_PORT:-5555}"
SERIAL_PORT="${HMOS7_SERIAL_PORT:-}"
SHELL_PORT="${HMOS7_SHELL_PORT:-5556}"
DISPLAY_MODE="${HMOS7_DISPLAY:-none}"   # none | vnc | cocoa (macOS) | gtk | sdl (Linux)
VNC_DISPLAY="${HMOS7_VNC_DISPLAY:-21}"
MEMORY="${HMOS7_MEMORY:-$DEFAULT_MEM}"
SMP="${HMOS7_SMP:-4}"
WIDTH="${HMOS7_WIDTH:-$DEFAULT_W}"
HEIGHT="${HMOS7_HEIGHT:-$DEFAULT_H}"
RESET_DATA="${HMOS7_RESET:-0}"
EXTRA_CMDLINE="${HMOS7_CMDLINE:-}"
PEER_MODE="${HMOS7_PEER:-off}"          # off | listen[:PORT] | connect[:PORT]
NET_MODE="${HMOS7_NET:-auto}"           # auto | bridged | shared | user
BRIDGE_NAME="${HMOS7_BRIDGE:-br0}"      # Linux bridge interface name
VMNET_CLIENT="${HMOS7_VMNET_CLIENT:-$(command -v socket_vmnet_client 2>/dev/null || echo /opt/socket_vmnet/bin/socket_vmnet_client)}"
VMNET_BRIDGED_SOCK="${HMOS7_VMNET_BRIDGED_SOCK:-/var/run/socket_vmnet_bridged}"
VMNET_SHARED_SOCK="${HMOS7_VMNET_SHARED_SOCK:-/var/run/socket_vmnet}"

OS_NAME="$(uname -s)"
ARCH_NAME="$(uname -m)"

for req in "$KERNEL" "$INITRD" "$OVERLAY_IMG" "$DONOR_IMGS/system.img" "$DONOR_IMGS/vendor.img" "$DONOR_IMGS/sys_prod.img" "$DONOR_IMGS/chip_prod.img" "$DONOR_IMGS/cust.img"; do
    if [ ! -f "$req" ]; then
        echo "ERROR: required image missing: $req" >&2
        exit 2
    fi
done

mkdir -p "$INST_DIR"
if [ "$RESET_DATA" = "1" ] || [ ! -f "$USERDATA_IMG" ]; then
    rm -f "$USERDATA_IMG"
    if [ "${HMOS7_BLANK_DATA:-0}" != "1" ] && [ -f "$PROVISIONED_IMG" ]; then
        if [ "$OS_NAME" = "Darwin" ]; then
            cp -c "$PROVISIONED_IMG" "$USERDATA_IMG" 2>/dev/null || cp "$PROVISIONED_IMG" "$USERDATA_IMG"
        else
            cp --reflink=auto --sparse=always "$PROVISIONED_IMG" "$USERDATA_IMG" 2>/dev/null || cp "$PROVISIONED_IMG" "$USERDATA_IMG"
        fi
    else
        if command -v truncate >/dev/null 2>&1; then
            truncate -s "${DEFAULT_DATA_GB}G" "$USERDATA_IMG"
        else
            python3 -c "open('$USERDATA_IMG', 'wb').truncate(${DEFAULT_DATA_GB} * 1024 * 1024 * 1024)"
        fi
    fi
fi

# Stable per-instance locally-administered MAC so DHCP leases stay consistent across reboots.
if [ -n "${HMOS7_MAC:-}" ]; then
    ETH0_MAC="$HMOS7_MAC"
elif command -v python3 >/dev/null 2>&1; then
    ETH0_MAC="$(python3 -c "import hashlib; h=hashlib.sha256('$INSTANCE'.encode()).digest(); print(f'52:54:00:{h[0]:02x}:{h[1]:02x}:{h[2]:02x}')")"
else
    H="$(printf '%s' "$INSTANCE" | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}')"
    ETH0_MAC="52:54:00:${H:0:2}:${H:2:2}:${H:4:2}"
fi

# Detect hardware virtualization accelerator (macOS HVF / Linux KVM / TCG fallback)
ACCEL_ARGS=(-accel tcg -cpu max)
if [ "$OS_NAME" = "Darwin" ] && [ "$ARCH_NAME" = "arm64" ]; then
    ACCEL_ARGS=(-accel hvf -cpu host)
elif [ "$OS_NAME" = "Linux" ] && { [ "$ARCH_NAME" = "aarch64" ] || [ "$ARCH_NAME" = "arm64" ]; }; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        ACCEL_ARGS=(-accel kvm -cpu host)
    else
        echo "WARN: /dev/kvm is not readable/writable; falling back to slow TCG emulation (run: sudo usermod -aG kvm \$USER)" >&2
    fi
fi

DISPLAY_ARGS=(-display none)
case "$DISPLAY_MODE" in
    none) DISPLAY_ARGS=(-display none) ;;
    cocoa) DISPLAY_ARGS=(-display "cocoa,full-grab=off,show-cursor=on,zoom-to-fit=on") ;;
    gtk) DISPLAY_ARGS=(-display "gtk,grab-on-hover=off,show-cursor=on,zoom-to-fit=on") ;;
    sdl) DISPLAY_ARGS=(-display "sdl,show-cursor=on") ;;
    vnc) DISPLAY_ARGS=(-display "vnc=127.0.0.1:${VNC_DISPLAY}") ;;
    *) echo "Unknown display mode: $DISPLAY_MODE" >&2; exit 2 ;;
esac

find_qemu_bridge_helper() {
    for h in /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper /usr/lib64/qemu/qemu-bridge-helper; do
        if [ -x "$h" ]; then
            printf '%s' "$h"
            return 0
        fi
    done
    return 1
}

linux_bridge_ready() {
    [ "$OS_NAME" = "Linux" ] || return 1
    [ -d "/sys/class/net/$BRIDGE_NAME/bridge" ] || return 1
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    local helper
    helper="$(find_qemu_bridge_helper 2>/dev/null)" || return 1
    [ -f /etc/qemu/bridge.conf ] && grep -Eq "^[[:space:]]*allow[[:space:]]+(${BRIDGE_NAME}|all)[[:space:]]*$" /etc/qemu/bridge.conf
}

# Resolve networking backend:
#   macOS: bridged (socket_vmnet_bridged) -> shared (socket_vmnet) -> user
#   Linux: bridged (qemu-bridge-helper + br0) -> user
RESOLVED_NET="$NET_MODE"
if [ "$RESOLVED_NET" = "auto" ]; then
    if [ "$OS_NAME" = "Darwin" ]; then
        if [ -x "$VMNET_CLIENT" ] && [ -S "$VMNET_BRIDGED_SOCK" ]; then
            RESOLVED_NET="bridged"
        elif [ -x "$VMNET_CLIENT" ] && [ -S "$VMNET_SHARED_SOCK" ]; then
            RESOLVED_NET="shared"
        else
            RESOLVED_NET="user"
        fi
    elif [ "$OS_NAME" = "Linux" ]; then
        if linux_bridge_ready; then
            RESOLVED_NET="bridged"
        else
            RESOLVED_NET="user"
        fi
    else
        RESOLVED_NET="user"
    fi
fi

PREFIX_CMD=()
NET_ARGS=()
case "$RESOLVED_NET" in
    bridged)
        if [ "$OS_NAME" = "Darwin" ]; then
            if [ ! -x "$VMNET_CLIENT" ] || [ ! -S "$VMNET_BRIDGED_SOCK" ]; then
                echo "ERROR: macOS bridged mode requires $VMNET_BRIDGED_SOCK (run: sudo $ROOT/scripts/setup-bridged-macos.sh)" >&2
                exit 2
            fi
            PREFIX_CMD=("$VMNET_CLIENT" "$VMNET_BRIDGED_SOCK")
            NET_ARGS=(
                -netdev "socket,id=eth0,fd=3"
                -device "virtio-net-pci,netdev=eth0,mac=${ETH0_MAC}"
                -netdev "user,id=hdc0,restrict=on,hostfwd=tcp:127.0.0.1:${HDC_PORT}-:5555"
                -device "virtio-net-pci,netdev=hdc0,mac=52:54:00:fe:dc:01"
            )
        elif [ "$OS_NAME" = "Linux" ]; then
            if ! linux_bridge_ready; then
                echo "ERROR: Linux bridged mode requires bridge '$BRIDGE_NAME' and /etc/qemu/bridge.conf (run: sudo $ROOT/scripts/setup-bridged-linux.sh)" >&2
                exit 2
            fi
            HELPER_OPT=""
            if HELPER_PATH="$(find_qemu_bridge_helper 2>/dev/null)"; then
                HELPER_OPT=",helper=${HELPER_PATH}"
            fi
            NET_ARGS=(
                -netdev "bridge,id=eth0,br=${BRIDGE_NAME}${HELPER_OPT}"
                -device "virtio-net-pci,netdev=eth0,mac=${ETH0_MAC}"
                -netdev "user,id=hdc0,restrict=on,hostfwd=tcp:127.0.0.1:${HDC_PORT}-:5555"
                -device "virtio-net-pci,netdev=hdc0,mac=52:54:00:fe:dc:01"
            )
        else
            echo "ERROR: bridged mode unsupported on $OS_NAME" >&2
            exit 2
        fi
        ;;
    shared)
        if [ "$OS_NAME" != "Darwin" ] || [ ! -x "$VMNET_CLIENT" ] || [ ! -S "$VMNET_SHARED_SOCK" ]; then
            echo "ERROR: shared vmnet mode requires macOS + $VMNET_SHARED_SOCK" >&2
            exit 2
        fi
        PREFIX_CMD=("$VMNET_CLIENT" "$VMNET_SHARED_SOCK")
        NET_ARGS=(
            -netdev "socket,id=eth0,fd=3"
            -device "virtio-net-pci,netdev=eth0,mac=${ETH0_MAC}"
            -netdev "user,id=hdc0,restrict=on,hostfwd=tcp:127.0.0.1:${HDC_PORT}-:5555"
            -device "virtio-net-pci,netdev=hdc0,mac=52:54:00:fe:dc:01"
        )
        ;;
    user)
        NET_ARGS=(
            -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HDC_PORT}-:5555"
            -device "virtio-net-pci,netdev=net0,mac=${ETH0_MAC}"
        )
        ;;
    *)
        echo "Unknown HMOS7_NET mode: $RESOLVED_NET (use auto, bridged, shared, or user)" >&2
        exit 2
        ;;
esac
echo "hmos7-run: os=$OS_NAME arch=$ARCH_NAME instance=$INSTANCE net=$RESOLVED_NET mac=$ETH0_MAC display=$DISPLAY_MODE hdc=127.0.0.1:$HDC_PORT" >&2

PEER_ARGS=()
if [[ "$PEER_MODE" =~ ^(listen|connect)(:([0-9]+))?$ ]]; then
    pmode="${BASH_REMATCH[1]}"
    pport="${BASH_REMATCH[3]:-6666}"
    if [ "$pmode" = "listen" ]; then
        PEER_ARGS=(-netdev "socket,id=peer0,listen=127.0.0.1:${pport}" -device "virtio-net-pci,netdev=peer0,mac=52:54:00:12:35:01")
    else
        PEER_ARGS=(-netdev "socket,id=peer0,connect=127.0.0.1:${pport}" -device "virtio-net-pci,netdev=peer0,mac=52:54:00:12:35:02")
    fi
fi

SERIAL_ARGS=(-serial "file:$INST_DIR/console.log")
if [ -n "$SERIAL_PORT" ]; then
    SERIAL_ARGS=(-serial "telnet:127.0.0.1:${SERIAL_PORT},server,nowait")
fi

QMP_SOCK="$INST_DIR/qmp.sock"
rm -f "$QMP_SOCK"

CMDLINE="console=ttyAMA0,115200 earlycon=pl011,0x09000000 arm64.nopauth enforcing=0 loglevel=7 rdinit=/init ${EXTRA_CMDLINE}"

exec ${PREFIX_CMD[@]+"${PREFIX_CMD[@]}"} qemu-system-aarch64 \
    -machine virt,gic-version=3 \
    "${ACCEL_ARGS[@]}" \
    -smp "$SMP" \
    -m "$MEMORY" \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "$CMDLINE" \
    "${DISPLAY_ARGS[@]}" \
    -device "virtio-gpu-pci,xres=${WIDTH},yres=${HEIGHT}" \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -device virtio-rng-pci \
    -device virtio-serial-pci \
    -chardev "socket,id=hvc0,host=127.0.0.1,port=${SHELL_PORT},server=on,wait=off" \
    -device virtconsole,chardev=hvc0,name=hmos.shell0 \
    "${NET_ARGS[@]}" \
    ${PEER_ARGS[@]+"${PEER_ARGS[@]}"} \
    -drive "if=none,id=d_sys,file=${DONOR_IMGS}/system.img,format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_sys \
    -drive "if=none,id=d_vnd,file=${DONOR_IMGS}/vendor.img,format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_vnd \
    -drive "if=none,id=d_sp,file=${DONOR_IMGS}/sys_prod.img,format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_sp \
    -drive "if=none,id=d_cp,file=${DONOR_IMGS}/chip_prod.img,format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_cp \
    -drive "if=none,id=d_cu,file=${DONOR_IMGS}/cust.img,format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_cu \
    -drive "if=none,id=d_ov,file=${OVERLAY_IMG},format=raw,readonly=on,file.locking=off" \
    -device virtio-blk-pci,drive=d_ov \
    -drive "if=none,id=d_ud,file=${USERDATA_IMG},format=raw" \
    -device virtio-blk-pci,drive=d_ud \
    -qmp "unix:${QMP_SOCK},server=on,wait=off" \
    "${SERIAL_ARGS[@]}" \
    -monitor none
