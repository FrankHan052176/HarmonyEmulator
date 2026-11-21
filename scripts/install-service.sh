#!/usr/bin/env bash
# Installs and starts HarmonyEmulatorDashboard as a persistent background service:
#   - macOS arm64: launchd LaunchAgent (~/Library/LaunchAgents/com.hmos7.emulator.dashboard.plist)
#   - Linux arm64: systemd user service (~/.config/systemd/user/harmony-emulator-dashboard.service)
#                  or system service (--system)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HMOS7_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LISTEN="${HMOS7_DASHBOARD_LISTEN:-127.0.0.1:18555}"
SYSTEM_UNIT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --listen) LISTEN="$2"; shift 2 ;;
        --root) ROOT="$2"; shift 2 ;;
        --system) SYSTEM_UNIT=1; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

SRC_BIN="$ROOT/bin/harmony-emulator-dashboard"
if [ ! -x "$SRC_BIN" ]; then
    echo "ERROR: $SRC_BIN not found. Run ./install.sh first." >&2
    exit 1
fi

OS="$(uname -s)"
if [ "$OS" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents" "$ROOT/logs"
    # If the project already lives on internal disk, run directly from $ROOT/bin;
    # only copy to ~/Data when $ROOT is on an external /Volumes/* mount.
    if [[ "$ROOT" == /Volumes/* ]]; then
        LOCAL_DIR="$HOME/Data/harmony-emulator-dashboard"
        mkdir -p "$LOCAL_DIR"
        rm -f "$LOCAL_DIR/harmony-emulator-dashboard"
        cp "$SRC_BIN" "$LOCAL_DIR/harmony-emulator-dashboard"
        chmod +x "$LOCAL_DIR/harmony-emulator-dashboard"
        RUN_BIN="$LOCAL_DIR/harmony-emulator-dashboard"
        LOG_PATH="$LOCAL_DIR/dashboard.log"
    else
        RUN_BIN="$SRC_BIN"
        LOG_PATH="$ROOT/logs/dashboard.log"
    fi

    PLIST="$HOME/Library/LaunchAgents/com.hmos7.emulator.dashboard.plist"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.hmos7.emulator.dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>${RUN_BIN}</string>
    <string>--listen</string>
    <string>${LISTEN}</string>
    <string>--root</string>
    <string>${ROOT}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HMOS7_ROOT</key>
    <string>${ROOT}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_PATH}</string>
  <key>StandardErrorPath</key>
  <string>${LOG_PATH}</string>
</dict>
</plist>
PLIST
    chmod 0600 "$PLIST"
    launchctl bootout "gui/$(id -u)/com.hmos7.emulator.dashboard" 2>/dev/null || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
        echo "OK: macOS LaunchAgent started (com.hmos7.emulator.dashboard -> http://${LISTEN})"
    else
        echo "NOTE: Wrote $PLIST (run in Terminal.app if needed: launchctl bootstrap gui/\$(id -u) $PLIST)"
    fi

elif [ "$OS" = "Linux" ]; then
    UNIT_BODY="[Unit]
Description=HarmonyEmulatorDashboard (HarmonyOS 7 QEMU + MCP Server)
After=network-online.target

[Service]
Type=simple
ExecStart=${SRC_BIN} --listen ${LISTEN} --root ${ROOT}
Environment=HMOS7_ROOT=${ROOT}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target"

    if [ "$SYSTEM_UNIT" = "1" ]; then
        UNIT="/etc/systemd/system/harmony-emulator-dashboard.service"
        printf '%s\n' "$UNIT_BODY" | sed 's/WantedBy=default.target/WantedBy=multi-user.target/' | sudo tee "$UNIT" >/dev/null
        sudo systemctl daemon-reload
        sudo systemctl enable --now harmony-emulator-dashboard.service
        echo "OK: Linux systemd system service started (harmony-emulator-dashboard.service -> http://${LISTEN})"
    else
        UNIT_DIR="$HOME/.config/systemd/user"
        mkdir -p "$UNIT_DIR"
        printf '%s\n' "$UNIT_BODY" > "$UNIT_DIR/harmony-emulator-dashboard.service"
        systemctl --user daemon-reload
        systemctl --user enable --now harmony-emulator-dashboard.service
        echo "OK: Linux systemd user service started (harmony-emulator-dashboard.service -> http://${LISTEN})"
    fi
else
    echo "Unsupported OS: $OS" >&2
    exit 1
fi
