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
# The _NET_ACTIVE_WINDOW source field is the critical detail:
#   source=0/1  application request — Mutter may REJECT this for Wayland-
#               native clients when focus-stealing prevention is active.
#   source=2    pager request       — EWMH mandates the WM MUST grant focus
#               unconditionally for source=2.  wmctrl always sends source=2.
#   xdotool windowactivate sends source=0 (old-style), which is silently
#   ignored by Mutter on Wayland.  wmctrl -i -a sends source=2 and works.
#
# XAUTHORITY must also be present for xdotool/wmctrl to connect to XWayland.
# In a systemd user service the variable may not be propagated from the GNOME
# session.  We probe its common location under $XDG_RUNTIME_DIR as a fallback.
(
    set +e  # every command here is best-effort; failures must not abort the main script

    # Tuning knobs (kept near the top for easy adjustment).
    _ACTIVATION_RETRIES=3   # how many times to re-send each activation method
    _RETRY_DELAY=1          # seconds between retry attempts

    # ── Environment setup ─────────────────────────────────────────────────
    # DISPLAY: XWayland always binds to :0 on a standard GNOME session.
    _DISP="${DISPLAY:-:0}"

    # XAUTHORITY: required for xdotool/wmctrl to authenticate with XWayland.
    # gnome-session exports this via dbus-update-activation-environment, but
    # on some setups it may be absent.  Mutter writes its own XWayland auth
    # file to $XDG_RUNTIME_DIR/.mutter-Xwaylandauth.<random-suffix>.
    _XAUTH="${XAUTHORITY:-}"
    if [[ -z "${_XAUTH}" ]]; then
        _RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        for _candidate in "${_RUNTIME}"/.mutter-Xwaylandauth.* \
                          "${HOME}/.Xauthority"; do
            if [[ -f "${_candidate}" ]]; then
                _XAUTH="${_candidate}"
                break
            fi
        done
    fi
    [[ -n "${_XAUTH}" ]] && export XAUTHORITY="${_XAUTH}"

    # ── Wait for Firefox window to appear ─────────────────────────────────
    # Poll up to 30s (1s intervals).  Firefox's browser window WM_CLASS:
    #   instance = "Navigator"   class = "Firefox"
    # Try the most reliable pattern first, then fall back to others.
    _WIN_ID=""
    for _i in $(seq 1 30); do
        for _pat in "--classname Navigator" "--class Firefox" "--classname firefox"; do
            # shellcheck disable=SC2086
            _WIN_ID=$(DISPLAY="${_DISP}" xdotool search ${_pat} 2>/dev/null | head -1)
            [[ -n "${_WIN_ID}" ]] && break 2
        done
        sleep 1
    done

    # ── Wait for Firefox to render before activating ──────────────────────
    # xdotool finds the XWayland window handle as soon as Firefox creates it,
    # which can happen before Firefox has committed its first rendered frame to
    # the Wayland surface.  Sending wmctrl activation at that point gives focus
    # to a surface with no content, leaving the screen black.  A 2-second pause
    # is sufficient for Firefox to complete its initial Wayland surface commit
    # on typical hardware while still being short enough not to be noticeable.
    if [[ -n "${_WIN_ID}" ]]; then
        sleep 2
    fi

    # ── Activate the window ───────────────────────────────────────────────
    # PRIMARY: wmctrl -i -a sends _NET_ACTIVE_WINDOW with source=2 (pager).
    # Mutter MUST honor source=2, bypassing focus-stealing prevention for
    # both X11 and Wayland-native (via XWayland-bridge) client windows.
    # Retry up to 3 times (1 s apart) in case the first attempt races with
    # Firefox's Wayland surface commit.
    if [[ -n "${_WIN_ID}" ]] && command -v wmctrl &>/dev/null; then
        # Validate _WIN_ID is a decimal integer before converting to hex.
        if [[ "${_WIN_ID}" =~ ^[0-9]+$ ]]; then
            _WIN_HEX="0x$(printf '%08x' "${_WIN_ID}")"
            for _try in $(seq 1 "${_ACTIVATION_RETRIES}"); do
                echo "kiosk-launch: activating Firefox window ${_WIN_HEX} via wmctrl (source=2, attempt ${_try}/${_ACTIVATION_RETRIES})" >&2
                DISPLAY="${_DISP}" wmctrl -i -a "${_WIN_HEX}" 2>/dev/null || true
                # _NET_ACTIVE_WINDOW is updated by Mutter once focus is granted;
                # if it already matches, skip the remaining retry sleeps.
                _ACTIVE=$(DISPLAY="${_DISP}" xdotool getactivewindow 2>/dev/null || true)
                [[ "${_ACTIVE}" == "${_WIN_ID}" ]] && break
                sleep "${_RETRY_DELAY}"
            done
            exit 0
        fi
    fi

    # FALLBACK A: wmctrl by WM_CLASS name (when window-ID search failed).
    if command -v wmctrl &>/dev/null; then
        echo "kiosk-launch: window-ID search failed; activating by class name via wmctrl" >&2
        for _try in $(seq 1 "${_ACTIVATION_RETRIES}"); do
            DISPLAY="${_DISP}" wmctrl -xa Firefox   2>/dev/null || \
            DISPLAY="${_DISP}" wmctrl -xa Navigator 2>/dev/null || true
            # Check whether any Firefox/Navigator window is now the active one.
            _ACTIVE_CLASS=$(DISPLAY="${_DISP}" xdotool getactivewindow getwindowclassname 2>/dev/null || true)
            [[ "${_ACTIVE_CLASS}" == "Firefox" || "${_ACTIVE_CLASS}" == "Navigator" ]] && break
            sleep "${_RETRY_DELAY}"
        done
        exit 0
    fi

    # FALLBACK B: xdotool windowactivate (source=0 – may be blocked by
    # Mutter's focus-stealing prevention, but try anyway as last resort).
    if [[ -n "${_WIN_ID}" ]]; then
        echo "kiosk-launch: wmctrl unavailable; trying xdotool windowactivate (source=0)" >&2
        for _try in $(seq 1 "${_ACTIVATION_RETRIES}"); do
            DISPLAY="${_DISP}" xdotool windowactivate --sync "${_WIN_ID}" 2>/dev/null || true
            DISPLAY="${_DISP}" xdotool windowfocus    --sync "${_WIN_ID}" 2>/dev/null || true
            _ACTIVE=$(DISPLAY="${_DISP}" xdotool getactivewindow 2>/dev/null || true)
            [[ "${_ACTIVE}" == "${_WIN_ID}" ]] && break
            sleep "${_RETRY_DELAY}"
        done
        exit 0
    fi

    # FALLBACK C: GNOME Shell Eval (disabled by default in GNOME 41+;
    # silently rejected on hardened shells, safe to attempt).
    if command -v gdbus &>/dev/null; then
        echo "kiosk-launch: trying GNOME Shell Eval as final activation fallback" >&2
        _JS="global.get_window_actors()"
        _JS+=".find(a=>a.meta_window.get_wm_class()?.toLowerCase().includes('firefox'))"
        _JS+="?.meta_window.activate(global.display.get_current_time())"
        gdbus call --session \
            --dest org.gnome.Shell \
            --object-path /org/gnome/Shell \
            --method org.gnome.Shell.Eval \
            "${_JS}" \
            2>/dev/null || true
    fi

    echo "kiosk-launch: all activation methods exhausted" >&2
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
