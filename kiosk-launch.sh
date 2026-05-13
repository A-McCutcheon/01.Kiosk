#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-launch.sh
# Reads the configured URL and opens Firefox in kiosk mode.
# When the browser exits the configuration app is re-opened automatically.
#
# Firefox is used because it integrates with GNOME's on-screen keyboard flow.
# Launch Firefox natively for the current desktop session (Wayland by default
# on modern GNOME).  X11-only helpers (xdotool/wmctrl) are best-effort and
# must never be treated as required for launch success on Wayland.

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
    # Release the single-instance lock before opening the config app so that
    # the new kiosk-launch.sh spawned by "Launch Kiosk" can acquire it.
    exec 9>&-
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
    exec 9>&-
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
#
# On subsequent launches (e.g. after the user clicks "Launch Kiosk" from the
# config app) GNOME Shell is already fully running, so gdbus wait returns
# immediately and no extra sleep is needed.  The sleep is only necessary on
# the very first boot when Mutter is still completing its startup sequence.
_compositor_was_ready=false
if command -v gdbus &>/dev/null; then
    # A short-timeout probe: if GNOME Shell is already present the call
    # returns 0 almost immediately; if not it will time out after 2 seconds
    # and we fall through to the full 30-second wait.
    if gdbus wait --session --timeout 2 org.gnome.Shell 2>/dev/null; then
        _compositor_was_ready=true
    else
        gdbus wait --session --timeout 30 org.gnome.Shell 2>/dev/null || true
    fi
fi
# Only add the post-startup sleep when the compositor was still initialising
# (first-boot path).  On subsequent launches GNOME Shell is already fully
# running so the extra wait is unnecessary and causes an apparent 5-second
# freeze after "Launch Kiosk" is clicked.
if ! "${_compositor_was_ready}"; then
    sleep 5
fi

# ── Prepare a dedicated Firefox profile for kiosk mode ───────────────────
# A fixed profile path lets us write renderer settings via user.js before
# every launch.  user.js is read unconditionally by Firefox on startup,
# which is more reliable than enterprise policies: snap-packaged Firefox on
# Ubuntu may not read /etc/firefox/policies/ (requires the etc-firefox snap
# interface), and Firefox's enterprise Preferences policy only applies to an
# internal allowlist that excludes some gfx.* preferences.
#
# IMPORTANT – snap Firefox confinement and dot-directories:
# The snap 'home' interface grants access to $HOME/* but intentionally
# excludes dot-directories (those starting with '.').  This means a profile
# path under ~/.config/ is inaccessible inside the snap mount-namespace and
# the -profile flag is silently ignored; snap Firefox then falls back to its
# own default profile at ~/snap/firefox/common/.mozilla/firefox/, which may
# contain a stale lock file from a previous unclean shutdown and trigger the
# "Firefox is already running" dialog.
#
# The fix: detect snap Firefox and use a profile path inside the snap app's
# $SNAP_USER_COMMON (~/snap/firefox/common/) which is always readable and
# writable inside the snap confinement, is persistent across snap updates,
# and is never remapped by the dot-directory exclusion.
_FF_IS_SNAP=false
# Check 1 – snap binary path (snap-installed Firefox where /snap/bin/firefox
#            is on PATH, or the canonical location is under /snap/).
_ff_bin_path="$(command -v "${BROWSER}" 2>/dev/null || true)"
_ff_bin_real="$(readlink -f "${_ff_bin_path}" 2>/dev/null || true)"
if [[ "${_ff_bin_path}" == /snap/* ]] || [[ "${_ff_bin_real}" == /snap/* ]]; then
    _FF_IS_SNAP=true
fi
# Check 2 – snap list (most authoritative; handles the Ubuntu 22.04+ case
#            where apt installs a shell-script wrapper at /usr/bin/firefox
#            that exec's the snap binary — readlink -f returns /usr/bin/firefox
#            so check 1 above would otherwise miss it).
if ! "${_FF_IS_SNAP}" && command -v snap &>/dev/null; then
    snap list firefox &>/dev/null && _FF_IS_SNAP=true || true
fi
# Check 3 – snap installation directory exists (fallback when snap command
#            is unavailable, e.g. in a minimal chroot or CI environment).
if ! "${_FF_IS_SNAP}"; then
    [[ -d /snap/firefox ]] && _FF_IS_SNAP=true || true
fi

if "${_FF_IS_SNAP}"; then
    # ~/snap/firefox/common/ is the snap app's $SNAP_USER_COMMON — fully
    # accessible inside the snap confinement, stable across snap updates,
    # and not subject to the dot-directory restriction of the 'home' interface.
    _FF_PROFILE_DIR="${HOME}/snap/firefox/common/kiosk-profile"
else
    _FF_PROFILE_DIR="${HOME}/.config/kiosk/firefox-profile"
fi

# ── Kill any lingering Firefox process before launching ───────────────────
# If Firefox was running when the machine was rebooted or the script was
# killed, the old process may still be alive and holding the profile lock.
# Removing the lock file alone is not enough in that case — Firefox checks
# whether the PID in the lock is alive, and if it is, it shows the
# "Firefox is already running, but is not responding" dialog instead of
# starting.  Kill any surviving Firefox instances now so the new launch
# always starts from a clean slate.
#
# Use pgrep -f to search the FULL command line rather than only the process
# name (comm).  On Ubuntu, snap Firefox runs via a launcher script whose
# comm may be 'bash' or 'firefox.launcher', not 'firefox'; pgrep -x would
# miss those processes.  The pattern '/firefox' matches any process whose
# argv[0] or arguments contain a path component '/firefox', which covers:
#   /usr/lib/firefox/firefox        (apt Firefox)
#   /snap/bin/firefox               (snap launcher)
#   /snap/firefox/.../firefox       (snap browser binary)
# Our own kiosk-launch.sh command line does not contain '/firefox', so the
# self-exclusion by $$ is just a belt-and-suspenders safety measure.
_ff_pids_raw=""
_ff_pids_raw+="$(pgrep -f '/firefox' 2>/dev/null | grep -v "^${$}\$" || true)"$'\n'
_ff_pids_raw+="$(pgrep -f '/firefox-esr' 2>/dev/null | grep -v "^${$}\$" || true)"$'\n'
# Also include exact-name matches in case the above misses any variant.
_ff_pids_raw+="$(pgrep -x 'firefox'     2>/dev/null || true)"$'\n'
_ff_pids_raw+="$(pgrep -x 'firefox-esr' 2>/dev/null || true)"$'\n'
# Deduplicate and drop blank entries.
_ff_pids_uniq="$(printf '%s\n' ${_ff_pids_raw} | sort -un | grep -v '^$' || true)"
for _ff_pid in ${_ff_pids_uniq}; do
    echo "kiosk-launch: killing lingering Firefox process (PID ${_ff_pid})" >&2
    kill "${_ff_pid}" 2>/dev/null || true
done
# Wait up to 10 s for each killed process to actually exit (checking every
# 0.5 s) before removing the lock files.  A fixed sleep is not sufficient
# because snap Firefox can take several seconds to clean up its sandbox.
if [[ -n "${_ff_pids_uniq}" ]]; then
    for _i in $(seq 1 20); do
        _ff_any_alive=false
        for _ff_pid in ${_ff_pids_uniq}; do
            kill -0 "${_ff_pid}" 2>/dev/null && { _ff_any_alive=true; break; }
        done
        "${_ff_any_alive}" || break
        sleep 0.5
    done
    # Force-kill any process that did not exit within the grace period.
    for _ff_pid in ${_ff_pids_uniq}; do
        if kill -0 "${_ff_pid}" 2>/dev/null; then
            echo "kiosk-launch: force-killing non-responsive Firefox (PID ${_ff_pid})" >&2
            kill -9 "${_ff_pid}" 2>/dev/null || true
        fi
    done
    sleep 0.5  # allow the OS to release file locks after SIGKILL
fi

# ── Recreate the kiosk Firefox profile from scratch ─────────────────────
# The most reliable way to prevent "Firefox is already running" is to
# ensure our custom profile directory contains no stale lock files at all.
# We do this by removing the profile and recreating it fresh on every
# launch.  This eliminates two edge cases that survive simple rm -f:
#
#   1. PID reuse after reboot: Firefox's 'lock' symlink records the PID of
#      the previous browser process.  After a reboot the OS may assign that
#      same PID to an unrelated process (e.g. a system daemon).  Firefox
#      sees "PID is alive" and falsely reports another instance is running —
#      even though the old Firefox is long gone and the lock was never
#      cleaned from a previous crash.
#
#   2. Partial cleanup: if a previous kiosk-launch.sh was interrupted after
#      Firefox started but before the profile was written, stale SQLite WAL
#      files or other session artifacts can trigger Firefox's recovery UI
#      instead of loading the kiosk URL cleanly.
#
# For a kiosk the profile is intentionally stateless: user.js is rewritten
# on every launch and the kiosk URL is always the same, so losing the
# cached startup files costs only a short one-time Firefox init delay
# (< 1 s in practice) and is far preferable to showing an error dialog.
if [[ -d "${_FF_PROFILE_DIR}" ]]; then
    rm -rf "${_FF_PROFILE_DIR}"
fi
mkdir -p "${_FF_PROFILE_DIR}"

# ── Remove stale locks from all other Firefox profile locations ──────────
# Even though we always launch with -profile pointing at our custom dir,
# snap Firefox may ignore that path (snap confinement / home-interface not
# connected) and fall back to its own profile in ~/snap/firefox/common/.
# Clean all reachable Firefox profile roots so the fallback path is also
# lock-free.  Use find so the sweep handles arbitrary subdirectory nesting
# without needing an explicit glob.
for _ff_root in \
        "${HOME}/.mozilla/firefox" \
        "${HOME}/snap/firefox/common/.mozilla/firefox" \
        "${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox"; do
    [[ -d "${_ff_root}" ]] || continue
    while IFS= read -r -d '' _ff_lock; do
        echo "kiosk-launch: removing stale Firefox lock: ${_ff_lock}" >&2
        rm -f "${_ff_lock}"
    done < <(find "${_ff_root}" -maxdepth 3 \
                  \( -name 'lock' -o -name '.parentlock' \) -print0 2>/dev/null)
done

# ── Write renderer preferences into the kiosk profile ────────────────────
# Rewrite user.js on every launch so renderer settings are always current.
cat > "${_FF_PROFILE_DIR}/user.js" <<'EOF'
/* kiosk-managed — rewritten by kiosk-launch.sh before every launch */
/* Force software (CPU) WebRender to prevent black screens on Wayland kiosk.
   gfx.webrender.software uses Firefox's own swgl (software WebGL) backend
   so rendering works on any hardware regardless of GPU driver support.      */
user_pref("gfx.webrender.software", true);
user_pref("gfx.webrender.software.opengl", false);
/* Suppress crash-restore prompt for clean kiosk startup */
user_pref("browser.sessionstore.resume_from_crash", false);
EOF

# ── Launch Firefox in background ───────────────────────────────────────────
# Run Firefox natively in the current session (Wayland on GNOME by default).
#
# Rendering back-end selection:
#
# snap Firefox on Wayland (Ubuntu 22.04+ / 24.04+)
#   Snap Firefox running as a native Wayland client cannot be reliably
#   activated by xdotool or wmctrl because those tools communicate via
#   XWayland / EWMH, which only knows about X11 windows.  A native Wayland
#   window also requires an XDG activation token for GNOME Shell (≥ 44/46) to
#   grant fullscreen focus; without one the --kiosk surface is mapped but
#   never receives an expose/focus event from Mutter, leaving the screen
#   permanently black.
#
#   Fix: force snap Firefox onto XWayland with MOZ_ENABLE_WAYLAND=0.
#   XWayland windows are visible to xdotool/wmctrl and don't require an
#   activation token for focus.  MOZ_WEBRENDER=0 disables GPU WebRender
#   (hardware WebRender on XWayland/Mesa can produce artefacts or a black
#   surface on VMs and systems with limited driver support).
#   NOTE: GDK_BACKEND=x11 is intentionally NOT used — Firefox manages its
#   window backend via MOZ_ENABLE_WAYLAND, not GTK's GDK_BACKEND.  Setting
#   GDK_BACKEND=x11 targets only GTK dialogs and causes a crash inside the
#   snap sandbox before Firefox opens any window.
#
# apt/non-snap Firefox on a Wayland session
#   MOZ_ENABLE_WAYLAND=1 requests the native Wayland back-end.  Without this,
#   apt Firefox may auto-detect Wayland unreliably from $WAYLAND_DISPLAY in
#   a systemd user-service environment.
#
# X11/XWayland session (non-Wayland)
#   MOZ_WEBRENDER=0 prevents GPU WebRender artefacts seen on some X11 drivers.
#
# Common flags:
#   -profile  – dedicated kiosk profile; user.js settings are applied every
#               launch so renderer preferences survive profile wipes.
#   --kiosk   – full-screen, no browser UI, no keyboard-shortcut exit.
#   -no-remote – always start a fresh process; never reuse an existing
#               instance that might not be in kiosk mode.
_LAUNCH_SESSION_LC="$(printf '%s' "${XDG_SESSION_TYPE:-}" | tr '[:upper:]' '[:lower:]')"
# _FF_USING_XWAYLAND: set to true when snap Firefox is forced onto XWayland so
# the activation subshell can treat the window as X11 (full 30-retry poll,
# skip the Wayland GNOME Shell Eval fallback path).
_FF_USING_XWAYLAND=false
if "${_FF_IS_SNAP}" && [[ "${_LAUNCH_SESSION_LC}" == "wayland" ]]; then
    # snap Firefox on Wayland → force XWayland so xdotool/wmctrl can manage
    # the window and --kiosk focus is granted without an activation token.
    #
    # Two mechanisms are combined to ensure Firefox uses X11/XWayland:
    #
    # 1. env -u WAYLAND_DISPLAY – removes WAYLAND_DISPLAY from the subprocess
    #    environment.  Firefox's auto-detection falls back to X11 when
    #    WAYLAND_DISPLAY is absent, regardless of Firefox version.  This is
    #    necessary because Firefox 131+ silently ignores MOZ_ENABLE_WAYLAND=0.
    #
    # 2. MOZ_ENABLE_WAYLAND=0 – kept for Firefox versions prior to 131 that
    #    still honour the variable.
    #
    # NOTE: GDK_BACKEND=x11 is intentionally NOT set.  Firefox manages its own
    # Wayland/X11 backend independently of GTK; GDK_BACKEND targets only GTK
    # dialogs and crashes inside the snap sandbox before any window opens.
    #
    # XAUTHORITY: in a systemd user service XAUTHORITY may not be propagated
    # from the GNOME session.  Without it Firefox cannot authenticate with the
    # XWayland server and silently falls back to the Wayland backend.  Probe
    # Mutter's XWayland auth file (written to $XDG_RUNTIME_DIR on every boot)
    # and export it before launching so Firefox always gets a valid credential.
    if [[ -z "${XAUTHORITY:-}" ]]; then
        _xauth_rt="${XDG_RUNTIME_DIR:-}"
        # XDG_RUNTIME_DIR is always set in GNOME systemd user services; the
        # fallback constructs the standard path only after validating the UID
        # is numeric to prevent unexpected command-substitution results.
        if [[ -z "${_xauth_rt}" ]]; then
            _xauth_uid="$(id -u 2>/dev/null || true)"
            [[ "${_xauth_uid}" =~ ^[0-9]+$ ]] && _xauth_rt="/run/user/${_xauth_uid}"
        fi
        _xauth_cand=""
        if [[ -n "${_xauth_rt}" ]]; then
            # Select the most recently modified Mutter XWayland auth file;
            # sort by mtime so any stale copies from a crash are skipped.
            _xauth_cand="$(find "${_xauth_rt}" -maxdepth 1 \
                -name '.mutter-Xwaylandauth.*' -printf '%T@\t%p\n' 2>/dev/null \
                | sort -rn | head -1 | cut -f2)"
        fi
        [[ -z "${_xauth_cand}" ]] && _xauth_cand="${HOME}/.Xauthority"
        if [[ -f "${_xauth_cand}" ]]; then
            export XAUTHORITY="${_xauth_cand}"
            echo "kiosk-launch: using XWayland auth file: ${_xauth_cand}" >&2
        fi
    fi
    _FF_USING_XWAYLAND=true
    echo "kiosk-launch: launching snap Firefox on XWayland (DISPLAY=${DISPLAY:-:0})" >&2
    env -u WAYLAND_DISPLAY \
        DISPLAY="${DISPLAY:-:0}" MOZ_ENABLE_WAYLAND=0 MOZ_WEBRENDER=0 \
        "${BROWSER}" \
        --kiosk \
        -no-remote \
        -profile "${_FF_PROFILE_DIR}" \
        "${URL}" 9>&- &
elif [[ "${_LAUNCH_SESSION_LC}" == "wayland" ]]; then
    # apt (non-snap) Firefox on a Wayland session → native Wayland back-end.
    MOZ_ENABLE_WAYLAND=1 "${BROWSER}" \
        --kiosk \
        -no-remote \
        -profile "${_FF_PROFILE_DIR}" \
        "${URL}" 9>&- &
else
    # X11 / XWayland session → disable GPU WebRender to prevent artefacts.
    MOZ_WEBRENDER=0 "${BROWSER}" \
        --kiosk \
        -no-remote \
        -profile "${_FF_PROFILE_DIR}" \
        "${URL}" 9>&- &
fi
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
    _ACTIVATION_RETRIES=3       # how many times to re-send each activation method
    _RETRY_DELAY=1              # seconds between retry attempts
    _WAYLAND_SURFACE_DELAY=5    # seconds to wait for Firefox's Wayland surface to
                                # register with GNOME Shell before activating
    _SESSION_TYPE="${XDG_SESSION_TYPE:-}"
    _SESSION_TYPE_LC="$(printf '%s' "${_SESSION_TYPE}" | tr '[:upper:]' '[:lower:]')"
    _IS_WAYLAND=false
    [[ "${_SESSION_TYPE_LC}" == "wayland" ]] && _IS_WAYLAND=true

    # When snap Firefox was forced onto XWayland, treat the window as X11 for
    # all activation logic: use the full 30-retry X11 poll (not the 3-retry
    # Wayland shortcut) and skip the Wayland-only GNOME Shell Eval fallback.
    if "${_FF_USING_XWAYLAND:-false}"; then
        _IS_WAYLAND=false
    fi

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

    # ── Wait for Firefox X11 window to appear (best-effort) ───────────────
    # On native Wayland Firefox may not expose an X11 window to xdotool at all.
    # Keep this check best-effort and short on Wayland sessions.
    _WINDOW_SEARCH_RETRIES=30
    if "${_IS_WAYLAND}"; then
        _WINDOW_SEARCH_RETRIES=3
    fi
    # Poll up to _WINDOW_SEARCH_RETRIES seconds (1s intervals).  Firefox's
    # browser window WM_CLASS:
    #   instance = "Navigator"   class = "Firefox"
    # Try the most reliable pattern first, then fall back to others.
    _WIN_ID=""
    for _i in $(seq 1 "${_WINDOW_SEARCH_RETRIES}"); do
        for _pat in "--classname Navigator" "--class Firefox" "--classname firefox"; do
            # shellcheck disable=SC2086
            _WIN_ID=$(DISPLAY="${_DISP}" xdotool search ${_pat} 2>/dev/null | head -1)
            [[ -n "${_WIN_ID}" ]] && break 2
        done
        sleep 1
    done

    if [[ -z "${_WIN_ID}" ]] && "${_IS_WAYLAND}"; then
        echo "kiosk-launch: no X11 Firefox window detected on Wayland; trying Wayland-compatible activation" >&2
        # On Wayland we only polled for an X11 window for 3 s; Firefox's Wayland
        # surface may not be registered with GNOME Shell yet.  Wait before
        # attempting activation so we don't activate a not-yet-mapped window.
        sleep "${_WAYLAND_SURFACE_DELAY}"
        # GNOME Shell Eval (works on GNOME < 41; silently rejected on GNOME 41+
        # without unsafe-mode – safe to attempt regardless).
        if command -v gdbus &>/dev/null; then
            _JS="let _win=global.get_window_actors()"
            _JS+=".find(a=>a.meta_window.get_wm_class()?.toLowerCase().includes('firefox'));"
            _JS+="if(_win)_win.meta_window.activate(global.display.get_current_time())"
            if ! gdbus call --session \
                --dest org.gnome.Shell \
                --object-path /org/gnome/Shell \
                --method org.gnome.Shell.Eval \
                "${_JS}" \
                2>/dev/null; then
                echo "kiosk-launch: GNOME Shell Eval activation unavailable on this session" >&2
            fi
        else
            echo "kiosk-launch: gdbus not found; no Wayland-native activation helper available" >&2
        fi
        # wmctrl by window title: on GNOME Wayland, Mutter populates EWMH's
        # _NET_CLIENT_LIST and _NET_WM_NAME for Wayland-native clients, so
        # title-based matching works even when WM_CLASS is not bridged.
        if command -v wmctrl &>/dev/null; then
            DISPLAY="${_DISP}" wmctrl -a "Mozilla Firefox" 2>/dev/null || true
            DISPLAY="${_DISP}" wmctrl -a "Firefox"         2>/dev/null || true
        fi
        # Do NOT exit here; fall through to FALLBACK A (wmctrl by WM_CLASS –
        # Mutter may also provide WM_CLASS for the bridged Wayland window).
    fi

    # ── Wait for Firefox to paint its first frame ─────────────────────────
    # xdotool finds the XWayland window handle as soon as Firefox maps it
    # (i.e. creates the surface), which can happen before any pixel content
    # has been committed to the compositor.  Activating at that point hands
    # focus to an unpainted surface that stays solid black.
    #
    # Poll xdotool with --onlyvisible to detect the moment the compositor
    # has received Firefox's first rendered frame.  Allow up to 10 seconds
    # (20 × 0.5 s); on success add a short 1-second settle delay.  If the
    # visible-window check times out (window is mapped but no content yet),
    # fall back to a longer 5-second sleep so we never activate a surface
    # that has not rendered.
    if [[ -n "${_WIN_ID}" ]]; then
        _PAINTED=""
        for _i in $(seq 1 20); do
            for _vpat in "--classname Navigator" "--class Firefox" "--classname firefox"; do
                # shellcheck disable=SC2086
                _PAINTED=$(DISPLAY="${_DISP}" xdotool search --onlyvisible ${_vpat} 2>/dev/null | head -1)
                [[ -n "${_PAINTED}" ]] && break 2
            done
            sleep 0.5
        done
        if [[ -n "${_PAINTED}" ]]; then
            _WIN_ID="${_PAINTED}"   # prefer the confirmed-visible ID
            sleep 1                 # short settle after first paint
        else
            sleep 5                 # window mapped but not yet painted; wait longer
        fi
    fi

    # ── Activate the window ───────────────────────────────────────────────
    # PRIMARY: wmctrl -i -a sends _NET_ACTIVE_WINDOW with source=2 (pager).
    # Mutter MUST honor source=2, bypassing focus-stealing prevention for
    # both X11 and Wayland-native (via XWayland-bridge) client windows.
    # Retry up to 3 times (1 s apart) in case the first attempt races with
    # Firefox's Wayland surface commit.
    #
    # After wmctrl we also run xdotool windowfocus and GNOME Shell Eval as
    # belt-and-suspenders: on GNOME versions where source=2 is not reliably
    # forwarded to Wayland-native clients, one of the additional methods will
    # succeed.  GNOME Shell Eval is silently rejected on GNOME 41+ (where the
    # Shell.Eval method requires unsafe-mode), so it is harmless to attempt.
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
            # Belt-and-suspenders: xdotool windowfocus (sets X11 input focus
            # directly; complements wmctrl's EWMH approach).
            DISPLAY="${_DISP}" xdotool windowfocus --sync "${_WIN_ID}" 2>/dev/null || true
            # GNOME Shell JavaScript eval (most reliable on GNOME < 41; silently
            # rejected on GNOME 41+ without unsafe-mode – safe to attempt).
            # Finds the Firefox MetaWindow and calls activate() on it directly,
            # bypassing focus-stealing prevention entirely.
            if command -v gdbus &>/dev/null; then
                _JS="let w=global.get_window_actors()"
                _JS+=".find(a=>a.meta_window.get_wm_class()?.toLowerCase().includes('firefox'));"
                _JS+="if(w)w.meta_window.activate(global.display.get_current_time())"
                gdbus call --session \
                    --dest org.gnome.Shell \
                    --object-path /org/gnome/Shell \
                    --method org.gnome.Shell.Eval \
                    "${_JS}" \
                    2>/dev/null || true
            fi
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
) 9>&- &

# ── Wait for Firefox process to start, then launch the overlay ───────────
# The overlay itself polls (via xdotool) until Firefox's window is on
# screen before showing, so no fixed fullscreen-settle sleep is needed here.
for _i in $(seq 1 15); do
    kill -0 "${FIREFOX_PID}" 2>/dev/null && break || true
    sleep 1
done

OVERLAY_PID=""
if [[ -f "${EXIT_OVERLAY}" ]]; then
    python3 "${EXIT_OVERLAY}" "${FIREFOX_PID}" 9>&- &
    OVERLAY_PID=$!
fi

_cleanup_overlay() {
    [[ -n "${OVERLAY_PID}" ]] && kill "${OVERLAY_PID}" 2>/dev/null || true
}
trap '_cleanup_overlay' EXIT

# Keep this script alive until Firefox exits
wait "${FIREFOX_PID}" || true

# ── When the browser exits, reopen the config app ─────────────────────────
# Release the single-instance lock first so the new kiosk-launch.sh that
# "Launch Kiosk" spawns from the config app is able to acquire it.
exec 9>&-
python3 "${CONFIG_APP}"
