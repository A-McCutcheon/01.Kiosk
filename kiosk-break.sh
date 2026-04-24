#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-break.sh
# Kills the kiosk browser and re-opens the configuration application.
# Mapped to Ctrl+Alt+C by the installer so the operator can break out of
# kiosk mode at any time.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_APP="${SCRIPT_DIR}/kiosk-config/config_app.py"

# Kill any running Firefox instance
pkill -x firefox                   2>/dev/null || \
pkill -x firefox-esr               2>/dev/null || \
pkill -f 'firefox.*--kiosk'        2>/dev/null || true

# Kill the exit overlay if it is running (it may have already exited if the
# user clicked its button, in which case pkill exits non-zero – that is fine)
pkill -f "kiosk-exit-overlay.py" 2>/dev/null || true

# Reopen the configuration app only when kiosk-launch.sh is not already alive.
# When kiosk-launch.sh is running it is waiting for Firefox to fully exit and
# will reopen the config app itself once the browser process has gone.
# Opening a second copy of the config app here creates a race: the user can
# click "Launch Kiosk" before kiosk-launch.sh has had a chance to release its
# flock (Firefox may take a few seconds to shut down after SIGTERM), causing
# the new kiosk-launch.sh to exit silently with "another instance is already
# running" and nothing visible happening.
if ! pgrep -f "config_app.py" &>/dev/null && \
   ! pgrep -f "kiosk-launch.sh" &>/dev/null; then
    python3 "${CONFIG_APP}" &
fi
