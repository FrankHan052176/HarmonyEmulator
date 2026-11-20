#!/usr/bin/env bash
# One-time macOS arm64 root setup for TRUE L2 BRIDGED Ethernet (NO NAT) via socket_vmnet.
# Usage: sudo ./scripts/setup-bridged-macos.sh [en0]
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script is for macOS only. On Linux, run scripts/setup-bridged-linux.sh." >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo $0 [interface]" >&2
    exit 1
fi

IFACE="${1:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')}"
IFACE="${IFACE:-en0}"

BIN=""
for cand in /opt/socket_vmnet/bin/socket_vmnet /opt/homebrew/opt/socket_vmnet/bin/socket_vmnet /usr/local/bin/socket_vmnet; do
    if [ -x "$cand" ]; then
        BIN="$cand"
        break
    fi
done
if [ -z "$BIN" ]; then
    echo "ERROR: socket_vmnet not found. Install it first: brew install socket_vmnet" >&2
    exit 1
fi

SOCK="/var/run/socket_vmnet_bridged"
PLIST="/Library/LaunchDaemons/com.hmos7.socket_vmnet.bridged.plist"
mkdir -p /var/log/socket_vmnet

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hmos7.socket_vmnet.bridged</string>
    <key>Program</key>
    <string>${BIN}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
        <string>--socket-group=staff</string>
        <string>--vmnet-mode=bridged</string>
        <string>--vmnet-interface=${IFACE}</string>
        <string>${SOCK}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>root</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/var/log/socket_vmnet/bridged.stdout</string>
    <key>StandardErrorPath</key>
    <string>/var/log/socket_vmnet/bridged.stderr</string>
</dict>
</plist>
PLIST

chmod 0644 "$PLIST"
chown root:wheel "$PLIST"
launchctl bootout system/com.hmos7.socket_vmnet.bridged 2>/dev/null || true
rm -f "$SOCK"
launchctl bootstrap system "$PLIST"
sleep 1
ls -la "$SOCK"
echo "OK: macOS L2 bridged socket_vmnet active on ${IFACE} -> ${SOCK}"
