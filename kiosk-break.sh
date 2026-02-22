#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-break.sh
# Kills the kiosk browser and re-opens the configuration application.
# Mapped to Ctrl+Alt+C by the installer so the operator can break out of
# kiosk mode at any time.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_APP="${SCRIPT_DIR}/kiosk-config/config_app.py"

# Kill any running Chromium instance
pkill -x chromium-browser 2>/dev/null || \
pkill -x chromium          2>/dev/null || true

# Reopen the configuration app if it is not already running
if ! pgrep -f "config_app.py" &>/dev/null; then
    python3 "${CONFIG_APP}" &
fi
