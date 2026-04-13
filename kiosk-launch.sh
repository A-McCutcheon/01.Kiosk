#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-launch.sh
# Reads the configured URL and opens Firefox in kiosk mode.
# When the browser exits the configuration app is re-opened automatically.
#
# Firefox is used because it is a native GTK/Wayland application.  On a GNOME
# Wayland session GTK implements the zwp_text_input_v3 protocol automatically,
# so the GNOME on-screen keyboard appears above the browser window and
# auto-shows whenever a web-page input field receives focus — with no special
# flags required.

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

# ── Locate Firefox ────────────────────────────────────────────────────────
BROWSER=""
for candidate in firefox firefox-esr; do
    if command -v "${candidate}" &>/dev/null; then
        BROWSER="${candidate}"
        break
    fi
done

if [[ -z "${BROWSER}" ]]; then
    echo "ERROR: Firefox is not installed." >&2
    echo "Run sudo apt-get install -y firefox" >&2
    python3 "${CONFIG_APP}"
    exit 1
fi

# ── Launch Firefox in background ───────────────────────────────────────────
# Firefox is a native GTK/Wayland app: it runs as a native Wayland client
# automatically when WAYLAND_DISPLAY is set, with no extra flags required.
# GTK implements the zwp_text_input_v3 protocol so the GNOME on-screen
# keyboard appears above the browser window and auto-shows on input focus.
#
# --kiosk        – full-screen, no browser UI, no exit via keyboard shortcuts.
# -no-remote     – always start a fresh Firefox process; do not reuse any
#                  existing instance that might not be in kiosk mode.
"${BROWSER}" \
    --kiosk \
    -no-remote \
    "${URL}" &
FIREFOX_PID=$!

# ── Wait for Firefox process to start, then launch the overlay ───────────
# The overlay itself polls (via xdotool) until Firefox's window is on
# screen before showing, so no fixed fullscreen-settle sleep is needed here.
for _i in $(seq 1 15); do
    kill -0 "${FIREFOX_PID}" 2>/dev/null && break || true
    sleep 1
done

OVERLAY_PID=""
if [[ -f "${EXIT_OVERLAY}" ]]; then
    python3 "${EXIT_OVERLAY}" "${FIREFOX_PID}" &
    OVERLAY_PID=$!
fi

_cleanup_overlay() {
    [[ -n "${OVERLAY_PID}" ]] && kill "${OVERLAY_PID}" 2>/dev/null || true
}
trap '_cleanup_overlay' EXIT

# Keep this script alive until Firefox exits
wait "${FIREFOX_PID}" || true

# ── When the browser exits, reopen the config app ─────────────────────────
python3 "${CONFIG_APP}"
