#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-launch.sh
# Reads the configured URL and opens Chromium in kiosk mode.
# When the browser exits the configuration app is re-opened automatically.
#
# Chromium is used because it is released under the BSD license, which
# permits commercial deployment without restriction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HOME}/.config/kiosk/kiosk.conf"
CONFIG_APP="${SCRIPT_DIR}/kiosk-config/config_app.py"
EXIT_OVERLAY="${SCRIPT_DIR}/kiosk-exit-overlay.py"

# ── Read URL from JSON config ──────────────────────────────────────────────
URL=""
if [[ -f "${CONFIG_FILE}" ]]; then
    URL=$(python3 - <<PYEOF
import json, sys
try:
    with open("${CONFIG_FILE}") as f:
        cfg = json.load(f)
    print(cfg.get("url", ""))
except Exception:
    pass
PYEOF
)
fi

# ── If no URL is configured, open the config app and exit ─────────────────
if [[ -z "${URL}" ]]; then
    python3 "${CONFIG_APP}"
    exit 0
fi

# ── Locate Chromium ────────────────────────────────────────────────────────
BROWSER=""
for candidate in chromium-browser chromium; do
    if command -v "${candidate}" &>/dev/null; then
        BROWSER="${candidate}"
        break
    fi
done

if [[ -z "${BROWSER}" ]]; then
    echo "ERROR: Chromium is not installed." >&2
    echo "Run sudo apt-get install -y chromium-browser" >&2
    python3 "${CONFIG_APP}"
    exit 1
fi

# ── Start the exit overlay (touchscreen / VirtualBox mouse support) ────────
# The overlay shows a small always-on-top button; tapping or clicking it
# invokes kiosk-break.sh.  The process is cleaned up automatically when
# this script exits (via the trap below).
OVERLAY_PID=""
if [[ -f "${EXIT_OVERLAY}" ]]; then
    python3 "${EXIT_OVERLAY}" &
    OVERLAY_PID=$!
fi

_cleanup_overlay() {
    [[ -n "${OVERLAY_PID}" ]] && kill "${OVERLAY_PID}" 2>/dev/null || true
}
trap '_cleanup_overlay' EXIT

# ── Launch in kiosk mode ────────────────────────────────────────────────────
# Flags explained:
#   --kiosk               removes all UI chrome (address bar, menus, exit button)
#   --start-fullscreen    tells the X11/Wayland compositor to render the window
#                         fullscreen from first paint; required on GNOME X11
#                         sessions where --kiosk alone does not trigger the WM
#                         fullscreen hint
#   --user-data-dir       dedicated clean profile directory; prevents any saved
#                         window state from a previous Chromium session
#                         (e.g. ~/.config/chromium) overriding --kiosk mode
#   --no-first-run        skip first-run wizard
#   --disable-infobars    suppress info banners
#   --noerrdialogs        suppress crash dialogs
#   --incognito           no local browsing history
"${BROWSER}" \
    --kiosk \
    --start-fullscreen \
    --user-data-dir="${HOME}/.config/chromium-kiosk" \
    --no-first-run \
    --disable-infobars \
    --disable-translate \
    --disable-suggestions-service \
    --disable-save-password-bubble \
    --disable-session-crashed-bubble \
    --noerrdialogs \
    --incognito \
    --window-position=0,0 \
    "${URL}" || true

# ── When the browser exits, reopen the config app ─────────────────────────
python3 "${CONFIG_APP}"
