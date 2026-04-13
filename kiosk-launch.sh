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

# ── Launch Chromium in background ──────────────────────────────────────────
# Running in background lets us start the overlay after Chromium's kiosk
# window has appeared, so the overlay is visible above it.
#
# NOTE: --kiosk is intentionally NOT used here.  On X11, Chromium's --kiosk
# mode repeatedly calls XRaiseWindow to keep its fullscreen window on top.
# This immediately pushes the GNOME on-screen keyboard behind Chromium each
# time the user swipes it up.  The combination of --app and --start-fullscreen
# provides equivalent kiosk UX (no address bar, fullscreen window) without
# the aggressive focus/z-order behaviour that blocks the OSK.
#
# --app="${URL}"            – launches as a standalone app window (no browser
#                             UI); keeps GNOME/Wayland from dropping back to a
#                             normal window when the OSK or overview animates.
# --start-fullscreen        – ensures the window enters fullscreen.
# --no-default-browser-check – suppresses the "make Chromium your default
#                             browser?" bar that can break the kiosk layout.
#
# On Wayland, Chromium may default to running via XWayland (the X11
# compatibility layer).  XWayland fullscreen windows bypass Wayland's
# z-ordering, so the GNOME on-screen keyboard (a layer-shell OVERLAY surface
# that is always above native Wayland windows) can disappear behind Chromium.
# --ozone-platform=wayland forces Chromium to run as a native Wayland client
# so the compositor correctly keeps the OSK above the fullscreen window.
# --enable-features=WaylandTextInputV3 activates the zwp_text_input_v3
# protocol, which GNOME Shell uses to detect when a text field is focused and
# show the OSK automatically.
PLATFORM_FLAGS=()
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    PLATFORM_FLAGS+=(
        --ozone-platform=wayland
        --enable-features=WaylandTextInputV3
    )
fi

"${BROWSER}" \
    --start-fullscreen \
    --no-first-run \
    --no-default-browser-check \
    --disable-infobars \
    --disable-translate \
    --disable-suggestions-service \
    --disable-save-password-bubble \
    --disable-session-crashed-bubble \
    --noerrdialogs \
    --incognito \
    "${PLATFORM_FLAGS[@]}" \
    --app="${URL}" &
CHROMIUM_PID=$!

# ── Wait for Chromium process to start, then launch the overlay ───────────
# The overlay itself polls (via xdotool) until Chromium's window is on
# screen before showing, so no fixed fullscreen-settle sleep is needed here.
for _i in $(seq 1 15); do
    kill -0 "${CHROMIUM_PID}" 2>/dev/null && break || true
    sleep 1
done

OVERLAY_PID=""
if [[ -f "${EXIT_OVERLAY}" ]]; then
    python3 "${EXIT_OVERLAY}" "${CHROMIUM_PID}" &
    OVERLAY_PID=$!
fi

_cleanup_overlay() {
    [[ -n "${OVERLAY_PID}" ]] && kill "${OVERLAY_PID}" 2>/dev/null || true
}
trap '_cleanup_overlay' EXIT

# Keep this script alive until Chromium exits
wait "${CHROMIUM_PID}" || true

# ── When the browser exits, reopen the config app ─────────────────────────
python3 "${CONFIG_APP}"
