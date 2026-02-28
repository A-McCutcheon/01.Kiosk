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

# ── Wait for GNOME Shell to be fully initialized ──────────────────────────
# With GDM3 autologin, kiosk.desktop fires while GNOME Shell is still
# starting up.  If Chromium launches before the compositor has placed its
# panel/dock struts the kiosk fullscreen geometry is incorrect and the
# window appears decorated (title bar + panels visible).  Polling the
# D-Bus session service ensures the shell is ready before we proceed.
# Timeout after 60 s so a broken GNOME session does not block forever.
if command -v gdbus &>/dev/null; then
    _shell_wait=0
    until gdbus introspect --session --dest org.gnome.Shell \
              --object-path /org/gnome/Shell &>/dev/null; do
        sleep 1
        (( _shell_wait++ )) || true
        [[ $_shell_wait -ge 60 ]] && break
    done
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
#   --kiosk               full-screen, no address bar, no exit UI
#   --no-first-run        skip first-run wizard
#   --disable-infobars    suppress info banners
#   --noerrdialogs        suppress crash dialogs
#   --incognito           no local browsing history
#   --window-position=0,0 anchor the window at the top-left corner so that
#                         the initial window position does not flash at a
#                         random location before fullscreen engages
"${BROWSER}" \
    --kiosk \
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
