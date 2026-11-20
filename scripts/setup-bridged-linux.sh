#!/usr/bin/env bash
# One-time Linux arm64 root setup for TRUE L2 BRIDGED Ethernet (NO NAT) via br0 + qemu-bridge-helper.
# Usage: sudo ./scripts/setup-bridged-linux.sh [--bridge br0] [--iface eth0] [--qemu-only]
#
# By default, configures /etc/qemu/bridge.conf + setuid qemu-bridge-helper, and if NetworkManager
# (nmcli) is managing the uplink interface and --qemu-only is NOT passed, creates persistent bridge br0.
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
    echo "This script is for Linux arm64 only. On macOS, run scripts/setup-bridged-macos.sh." >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo $0 [--bridge br0] [--iface <nic>] [--qemu-only]" >&2
    exit 1
fi

BRIDGE="br0"
IFACE=""
QEMU_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bridge) BRIDGE="$2"; shift 2 ;;
        --iface) IFACE="$2"; shift 2 ;;
        --qemu-only) QEMU_ONLY=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# 1. Authorize bridge in /etc/qemu/bridge.conf and ensure qemu-bridge-helper has setuid root
mkdir -p /etc/qemu
if [ ! -f /etc/qemu/bridge.conf ] || ! grep -Eq "^[[:space:]]*allow[[:space:]]+(${BRIDGE}|all)[[:space:]]*$" /etc/qemu/bridge.conf; then
    echo "allow ${BRIDGE}" >> /etc/qemu/bridge.conf
fi
chmod 0644 /etc/qemu/bridge.conf

HELPER=""
for h in /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper /usr/lib64/qemu/qemu-bridge-helper; do
    if [ -x "$h" ]; then
        HELPER="$h"
        chmod u+s "$h"
        break
    fi
done
if [ -z "$HELPER" ]; then
    echo "WARN: qemu-bridge-helper not found (install qemu-system-arm / qemu-system-common first)." >&2
else
    echo "OK: configured $HELPER (setuid) and /etc/qemu/bridge.conf (allow $BRIDGE)"
fi

if [ "$QEMU_ONLY" = "1" ] || [ -d "/sys/class/net/$BRIDGE/bridge" ]; then
    echo "OK: bridge $BRIDGE status: $( [ -d "/sys/class/net/$BRIDGE/bridge" ] && echo 'UP' || echo 'not created yet (--qemu-only)' )"
    exit 0
fi

# 2. Create bridge $BRIDGE enslaved to uplink NIC (via nmcli if available)
if [ -z "$IFACE" ]; then
    IFACE="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
if [ -z "$IFACE" ]; then
    echo "ERROR: could not detect default uplink interface; pass --iface <nic>." >&2
    exit 1
fi

if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    echo "Creating persistent NetworkManager bridge $BRIDGE -> $IFACE..."
    nmcli con add type bridge ifname "$BRIDGE" con-name "$BRIDGE" stp no ipv4.method auto ipv6.method auto
    nmcli con add type bridge-slave ifname "$IFACE" master "$BRIDGE" con-name "${BRIDGE}-slave-${IFACE}"
    nmcli con up "$BRIDGE"
    echo "OK: NetworkManager bridge $BRIDGE is active on $IFACE."
else
    cat <<EOF
NOTE: NetworkManager is not active on this host (likely systemd-networkd or Netplan).
/etc/qemu/bridge.conf and qemu-bridge-helper are ALREADY configured for '${BRIDGE}'.
To create '${BRIDGE}' bridged to '${IFACE}' without dropping SSH, add a Netplan file e.g. /etc/netplan/60-hmos-bridge.yaml:

network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: false
  bridges:
    ${BRIDGE}:
      interfaces: [${IFACE}]
      dhcp4: true
      parameters:
        stp: false

Then run: sudo netplan try
EOF
fi
