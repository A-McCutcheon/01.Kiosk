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

# ── Single-instance guard ─────────────────────────────────────────────────
# Prevents a double-start race when both the systemd user service and the
# legacy .desktop autostart entry happen to fire in the same session.
# flock acquires an exclusive lock on the lock-file; the second invocation
# exits immediately rather than starting a second Firefox instance.
# XDG_RUNTIME_DIR is user-private (mode 0700, tmpfs) so it is safe for
# lock files; fall back to ~/.cache which is always user-specific.
LOCK_FILE="${XDG_RUNTIME_DIR:-${HOME}/.cache}/kiosk-launch.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "kiosk-launch.sh: another instance is already running; exiting." >&2
    exit 0
fi

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

# ── Wait for GNOME Shell compositor to be ready ───────────────────────────
# The kiosk autostart may execute while GNOME Shell is still completing its
# session-start animation.  If Firefox is launched before Mutter has finished
# its first-frame setup, the fullscreen window never receives an initial
# focus/expose event and the display stays black until something (e.g.
# Alt+Tab) triggers one.
#
# gdbus wait --session --timeout N NAME blocks until the named D-Bus service
# appears (exits immediately if already present, or after N seconds at most).
# NOTE: NAME is a required positional argument; without it the command fails
# immediately and silently if error output is suppressed — making the wait
# a no-op.  The extra sleep gives Mutter time to finish its startup animation
# before Firefox claims the fullscreen surface.
if command -v gdbus &>/dev/null; then
    gdbus wait --session --timeout 30 org.gnome.Shell 2>/dev/null || true
fi
sleep 5

# ── Launch Firefox in background ───────────────────────────────────────────
# Firefox is a native GTK/Wayland app: it runs as a native Wayland client
# automatically when WAYLAND_DISPLAY is set, with no extra flags required.
# GTK implements the zwp_text_input_v3 protocol so the GNOME on-screen
# keyboard appears above the browser window and auto-shows on input focus.
#
# MOZ_WEBRENDER=0 disables Firefox's GPU WebRender compositor, which can
# cause screen artefacts and redraw glitches on some graphics drivers.
# Hardware acceleration is also disabled via policies.json; this env-var
# ensures it is off even if policies.json has not been (re-)applied yet.
#
# --kiosk        – full-screen, no browser UI, no exit via keyboard shortcuts.
# -no-remote     – always start a fresh Firefox process; do not reuse any
#                  existing instance that might not be in kiosk mode.
MOZ_WEBRENDER=0 "${BROWSER}" \
    --kiosk \
    -no-remote \
    "${URL}" &
FIREFOX_PID=$!

# ── Post-launch: wait for Firefox window and activate it ─────────────────
# On Wayland, fullscreen windows started without an XDG activation token
# may not receive automatic focus from GNOME Shell's focus-stealing
# prevention, leaving the screen black until something (e.g. Alt+Tab)
# delivers an activation event.
#
# Two bugs existed in the previous version of this block:
#   1. DISPLAY was never set.  xdotool needs DISPLAY; when the script runs
#      from a systemd user service DISPLAY is not automatically inherited,
#      so every xdotool call failed silently.
#   2. The search used --classname firefox, but Firefox's WM_CLASS instance
#      name is "Navigator", not "firefox".  The search always returned empty.
#
# Fix: explicitly export DISPLAY (defaulting to :0 – XWayland's standard
# display on GNOME), search for all known Firefox WM_CLASS patterns, and
# poll until the window appears rather than sleeping a fixed interval.
#
# GNOME's Mutter compositor creates EWMH proxy entries for native Wayland
# clients, so xdotool and wmctrl can find and activate Wayland windows via
# the XWayland compatibility layer even when Firefox is not an X11 client.
(
    set +e  # every command here is best-effort; failures must not abort the main script

    # Ensure X display is set; XWayland always binds to :0 on a GNOME session.
    _DISP="${DISPLAY:-:0}"

    # Poll for Firefox's window to appear (up to 30s, 1s intervals).
    # This replaces the previous fixed sleep and handles both fast and slow
    # hardware without an arbitrary timeout.
    _WIN_ID=""
    for _i in $(seq 1 30); do
        # Firefox's browser window WM_CLASS: instance="Navigator", class="Firefox".
        # Try the most specific pattern first, then broader ones as fallback.
        for _pat in "--classname Navigator" "--class Firefox" "--classname firefox"; do
            # shellcheck disable=SC2086
            _WIN_ID=$(DISPLAY="${_DISP}" xdotool search ${_pat} 2>/dev/null | head -1)
            [[ -n "${_WIN_ID}" ]] && break 2
        done
        sleep 1
    done

    if [[ -n "${_WIN_ID}" ]]; then
        # xdotool found the window via XWayland/EWMH – activate and focus it.
        DISPLAY="${_DISP}" xdotool windowactivate --sync "${_WIN_ID}" 2>/dev/null || true
        DISPLAY="${_DISP}" xdotool windowfocus   --sync "${_WIN_ID}" 2>/dev/null || true
        exit 0
    fi

    # Fallback: wmctrl – activate Firefox by WM_CLASS/title match.
    # wmctrl uses the same EWMH interface so it works for Wayland windows too.
    if command -v wmctrl &>/dev/null; then
        DISPLAY="${_DISP}" wmctrl -xa Navigator 2>/dev/null || \
        DISPLAY="${_DISP}" wmctrl -xa firefox   2>/dev/null || true
        exit 0
    fi

    # Last resort: GNOME Shell Eval (disabled by default in GNOME 41+;
    # silently rejected on production shells but safe to attempt).
    if command -v gdbus &>/dev/null; then
        _EVAL_JS="global.get_window_actors()"
        _EVAL_JS+=".find(a => a.meta_window.get_wm_class().toLowerCase().includes('firefox'))"
        _EVAL_JS+="?.meta_window.activate(global.display.get_current_time())"
        gdbus call --session \
            --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Eval \
            "${_EVAL_JS}" \
            2>/dev/null || true
    fi
) &

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
