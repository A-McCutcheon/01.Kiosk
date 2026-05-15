#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# kiosk-diag.sh  –  Diagnostic checks for the kiosk autologin setup
#
# Usage:
#   sudo /opt/kiosk/kiosk-diag.sh [kiosk-username]
#   sudo ./kiosk-diag.sh [kiosk-username]

KIOSK_USER="${1:-kiosk}"

echo "╔══════════════════════════════════════════════╗"
echo "║       Kiosk Diagnostic Report                ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Kiosk user : ${KIOSK_USER}"
echo ""

FAIL=0
_ok()   { echo "  ✓  $1"; }
_fail() { echo "  ✗  $1"; (( FAIL++ )) || true; }

# ── GDM3 ──────────────────────────────────────────────────────────────────
echo "── GDM3 autologin ────────────────────────────────────────────────────"
if [[ ! -f /etc/gdm3/custom.conf ]]; then
    _fail "/etc/gdm3/custom.conf not found (GDM3 may not be installed)"
else
    _ok "/etc/gdm3/custom.conf present"

    grep -qE '^\s*AutomaticLoginEnable\s*=\s*true' /etc/gdm3/custom.conf \
        && _ok  "AutomaticLoginEnable=true" \
        || _fail "AutomaticLoginEnable not set to true in /etc/gdm3/custom.conf"

    # Use fixed-string match to avoid treating the username as a regex pattern.
    grep -qF "AutomaticLogin = ${KIOSK_USER}" /etc/gdm3/custom.conf \
        || grep -qF "AutomaticLogin=${KIOSK_USER}" /etc/gdm3/custom.conf \
        && _ok  "AutomaticLogin=${KIOSK_USER}" \
        || _fail "AutomaticLogin not set to '${KIOSK_USER}' in /etc/gdm3/custom.conf"

    if grep -qE '^\s*WaylandEnable\s*=\s*false' /etc/gdm3/custom.conf; then
        echo "  ℹ  WaylandEnable=false detected – running in X11 mode."
        echo "     X11 mode may prevent GNOME OSK swipe gestures from working."
        echo "     Remove the WaylandEnable=false line to re-enable Wayland (recommended)."
    else
        _ok  "Wayland enabled (recommended for GNOME on-screen keyboard support)"
    fi

    echo ""
    echo "  Full [daemon] section of /etc/gdm3/custom.conf:"
    awk '
        /^\[daemon\]/ { in_daemon = 1; next }
        /^\[/ && in_daemon { exit }
        in_daemon { print "    " $0 }
    ' /etc/gdm3/custom.conf
fi
echo ""

# ── Kiosk user ────────────────────────────────────────────────────────────
echo "── Kiosk user ────────────────────────────────────────────────────────"
if id "${KIOSK_USER}" &>/dev/null; then
    _ok "User '${KIOSK_USER}' exists"
    KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"
    [[ -d "${KIOSK_HOME}" ]] \
        && _ok  "Home directory ${KIOSK_HOME} exists" \
        || _fail "Home directory ${KIOSK_HOME} missing"
else
    _fail "User '${KIOSK_USER}' not found – re-run install.sh"
    KIOSK_HOME=""
fi
echo ""

# ── GNOME autostart ───────────────────────────────────────────────────────
echo "── GNOME autostart ───────────────────────────────────────────────────"
if [[ -n "${KIOSK_HOME}" ]]; then
    [[ -f "${KIOSK_HOME}/.config/autostart/kiosk.desktop" ]] \
        && _ok  "autostart/kiosk.desktop present" \
        || _fail "${KIOSK_HOME}/.config/autostart/kiosk.desktop missing"

    [[ -f "${KIOSK_HOME}/.config/gnome-initial-setup-done" ]] \
        && _ok  "gnome-initial-setup-done marker present" \
        || _fail "${KIOSK_HOME}/.config/gnome-initial-setup-done missing – first-run wizard will intercept login"
fi
echo ""

# ── Installed scripts ─────────────────────────────────────────────────────
echo "── Installed kiosk scripts ───────────────────────────────────────────"
for f in kiosk-launch.sh kiosk-break.sh kiosk-exit-overlay.py kiosk-config/config_app.py; do
    [[ -f "/opt/kiosk/${f}" ]] \
        && _ok  "/opt/kiosk/${f}" \
        || _fail "/opt/kiosk/${f} missing"
done
echo ""

# ── Required runtime tools ────────────────────────────────────────────────
echo "── Required runtime tools ────────────────────────────────────────────"
for tool in xdotool wmctrl gdbus xauth; do
    if command -v "${tool}" &>/dev/null; then
        _ok  "${tool} found ($(command -v "${tool}"))"
    else
        _fail "${tool} not found -- window activation may fail, causing a black browser screen"
    fi
done
echo ""

# ── Firefox policies ──────────────────────────────────────────────────────
echo "── Firefox rendering policies ────────────────────────────────────────"
FIREFOX_POLICY="/etc/firefox/policies/policies.json"
if [[ ! -f "${FIREFOX_POLICY}" ]]; then
    _fail "${FIREFOX_POLICY} missing – re-run: sudo ./install.sh"
elif grep -qE '"gfx\.webrender\.all"|"layers\.acceleration\.disabled"' "${FIREFOX_POLICY}" 2>/dev/null; then
    _fail "${FIREFOX_POLICY} contains stale WebRender restrictions that cause a black screen on Wayland"
    echo "     → Re-run: sudo ./install.sh  (updates Firefox policies for Wayland)"
else
    _ok  "${FIREFOX_POLICY} present (no stale WebRender restrictions)"
fi
echo ""

# ── Firefox kiosk profile ─────────────────────────────────────────────────
echo "── Firefox kiosk profile ─────────────────────────────────────────────"
# Mirror kiosk-launch.sh: detect snap Firefox so we check the correct
# profile path.  Snap confinement's 'home' interface excludes dot-dirs
# (e.g. ~/.config/), so snap Firefox ignores -profile paths there and
# uses ~/snap/firefox/common/ instead.
# On Ubuntu 22.04+, apt installs a shell-script wrapper at /usr/bin/firefox
# that exec's the snap binary; readlink -f stays at /usr/bin/firefox so a
# plain path check misses it.  Use 'snap list' as the authoritative check.
_diag_ff_bin_path="$(command -v firefox 2>/dev/null || command -v firefox-esr 2>/dev/null || true)"
_diag_ff_bin_real="$(readlink -f "${_diag_ff_bin_path}" 2>/dev/null || true)"
_diag_ff_is_snap=false
if [[ "${_diag_ff_bin_path}" == /snap/* ]] || [[ "${_diag_ff_bin_real}" == /snap/* ]]; then
    _diag_ff_is_snap=true
fi
if ! "${_diag_ff_is_snap}" && command -v snap &>/dev/null; then
    snap list firefox &>/dev/null && _diag_ff_is_snap=true || true
fi
if ! "${_diag_ff_is_snap}"; then
    [[ -d /snap/firefox ]] && _diag_ff_is_snap=true || true
fi
if "${_diag_ff_is_snap}"; then
    KIOSK_USER_JS="${KIOSK_HOME}/snap/firefox/common/kiosk-profile/user.js"
else
    KIOSK_USER_JS="${KIOSK_HOME}/.config/kiosk/firefox-profile/user.js"
fi
if [[ ! -f "${KIOSK_USER_JS}" ]]; then
    _fail "${KIOSK_USER_JS} missing – profile not yet created by kiosk-launch.sh"
    echo "     → Launch the kiosk once (it will be created on first run)"
    echo "     → Or re-run: sudo ./install.sh  then reboot"
elif ! grep -q 'gfx.webrender.software' "${KIOSK_USER_JS}" 2>/dev/null; then
    _fail "${KIOSK_USER_JS} does not contain WebRender software preference"
    echo "     → Re-run: sudo ./install.sh  then reboot (copies updated kiosk-launch.sh)"
else
    _ok  "${KIOSK_USER_JS} present (WebRender software mode enabled)"
fi
echo ""

# ── snap Firefox interfaces ───────────────────────────────────────────────
echo "── snap Firefox interfaces ───────────────────────────────────────────"
if "${_diag_ff_is_snap}" && command -v snap &>/dev/null; then
    # snap-confine's 'wayland' interface plug mounts the host Wayland socket
    # inside the snap namespace and re-injects WAYLAND_DISPLAY, bypassing
    # 'env -u WAYLAND_DISPLAY'.  It must be disconnected so Firefox falls back
    # to X11/XWayland where xdotool/wmctrl can manage its window.
    _wl_state="$(snap connections firefox 2>/dev/null \
        | awk '$1 == "wayland" { print $3 }' || true)"
    if [[ "${_wl_state}" == "-" ]]; then
        _ok  "snap Firefox wayland plug disconnected (XWayland mode enforced)"
    else
        _fail "snap Firefox wayland plug is connected (Firefox will open on Wayland and remain invisible)"
        echo "     → Re-run: sudo ./install.sh"
        echo "     → Or manually: sudo snap disconnect firefox:wayland"
    fi

    # The x11 interface grants Firefox access to the X11 socket (:0).
    # If disconnected, Firefox fails with "cannot open display: :0" (exit 1).
    _x11_state="$(snap connections firefox 2>/dev/null \
        | awk '$1 == "x11" { print $3 }' || true)"
    if [[ "${_x11_state}" == "-" ]]; then
        _fail "snap Firefox x11 plug is disconnected – Firefox cannot connect to display :0 (exit 1)"
        echo "     → Run: sudo snap connect firefox:x11"
    elif [[ -n "${_x11_state}" ]]; then
        _ok  "snap Firefox x11 plug connected (${_x11_state})"
    else
        echo "  ℹ  x11 interface not listed in snap connections (may be provided via desktop interface)"
    fi

    echo ""
    echo "  Full snap connections for firefox:"
    snap connections firefox 2>/dev/null | sed 's/^/    /' \
        || echo "    (snap connections command failed)"
else
    echo "  ℹ  snap Firefox not detected – interface checks skipped."
fi
echo ""

# ── Installed script freshness ────────────────────────────────────────────
echo "── Installed script freshness ────────────────────────────────────────"
INSTALLED_LAUNCH="/opt/kiosk/kiosk-launch.sh"
if [[ ! -f "${INSTALLED_LAUNCH}" ]]; then
    _fail "${INSTALLED_LAUNCH} missing – re-run: sudo ./install.sh"
elif ! grep -q 'MOZ_ENABLE_WAYLAND=1' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing Wayland-native launch support)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'firefox-profile' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing dedicated kiosk profile for WebRender user.js)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'rm -rf.*_FF_PROFILE_DIR\|wipe.*profile\|Recreate the kiosk' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing wipe-profile-on-launch fix)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_FF_IS_SNAP\|snap/firefox/common/kiosk-profile' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing snap Firefox profile path fix)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'snap list firefox' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (snap detection uses only readlink; misses Ubuntu 22.04+ apt wrapper)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_FF_USING_XWAYLAND' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing snap-Firefox XWayland activation fix for Ubuntu 24.04)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'env -u WAYLAND_DISPLAY' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing WAYLAND_DISPLAY suppression for Firefox 131+ XWayland forcing)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_WAYLAND_SESSION' /opt/kiosk/kiosk-exit-overlay.py 2>/dev/null; then
    _fail "/opt/kiosk/kiosk-exit-overlay.py is outdated (missing Wayland-aware overlay detection)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'XWayland probe' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing XWayland wake-up probe and double-launch fix)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'snap disconnect firefox:wayland' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing snap Wayland disconnect note)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'wmctrl -xa firefox' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing Wayland-native Firefox activation fallback)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'Firefox liveness' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing Firefox liveness and window-list diagnostics)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'XDG_ACTIVATION_TOKEN' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing XDG activation token for GNOME 46 focus grant)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'RequestToken' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (XDG token uses wrong portal method: Firefox window invisible due to GNOME 46 focus-stealing prevention)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'timeout 3.*gdbus' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing timeout on gdbus portal call: script hangs when xdg-desktop-portal is unresponsive, Firefox never launches)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_xauth_cand.*\]\] ||' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (XAUTHORITY probe aborts script under set -e when Mutter auth file is found -- Firefox never launches)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'cut -f2 || true' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (find|sort|head pipeline aborts under set -o pipefail -- SIGPIPE from sort when 2+ Xwayland auth files exist, or find exits non-zero)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'ERR exit at line' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing ERR trap for set-e crash diagnostics -- cannot determine where script aborts)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'post-XDG-token state' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing post-XDG-token diagnostic log -- cannot distinguish launch branch from journal)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_ff_wayland_slot' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing snap wayland-plug runtime check)"
    echo "     Without it the activation subshell uses 3-retry Wayland poll even when snap"
    echo "     Firefox is on XWayland, so the Firefox window is never found and never appears."
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'env -u WAYLAND_DISPLAY' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing env -u WAYLAND_DISPLAY on XWayland launch path)"
    echo "     snap's 'desktop' interface exposes WAYLAND_DISPLAY inside the snap namespace even"
    echo "     when the wayland plug is disconnected.  Firefox 131+ crashes (exit 1) when both"
    echo "     WAYLAND_DISPLAY and DISPLAY=:0 are present.  WAYLAND_DISPLAY must be stripped."
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_mm_src' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (xauth extract-by-display is a silent no-op: Mutter stores cookies as 'hostname/unix:0', not ':0'; must merge ALL entries via xauth merge)"
    echo "     Also: merge is skipped on restart when XAUTHORITY is already ~/.Xauthority."
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_FF_SNAP_XAUTH=' "${INSTALLED_LAUNCH}" 2>/dev/null \
        || ! grep -Fq 'snap/firefox/common/kiosk-xauth' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (snap XWayland auth is still cached in ~/.Xauthority, which the Firefox snap may not be able to read)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '\-u GDK_BACKEND' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing GDK_BACKEND suppression: if GDK_BACKEND=wayland is set in the session environment, GTK refuses to use X11 and Firefox crashes with exit 1 on the XWayland path)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'Firefox stderr output:' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing Firefox stderr capture for crash diagnostics)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'snap logs firefox -n' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing snap logs capture on crash: cannot see Firefox's startup error from the snap journal)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'XWayland socket:' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing XWayland socket state in pre-launch diagnostics)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q 'Mutter Xauth files:' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing Mutter Xauth file list in pre-launch diagnostics)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
else
    _ok  "${INSTALLED_LAUNCH} is up-to-date (snap wayland disconnect, XWayland probe, snap native Wayland, XDG portal RequestToken with timeout, set-e XAUTHORITY block fix, liveness probe, ERR trap, snap wayland-plug runtime check, env -u WAYLAND_DISPLAY XWayland launch, snap XWayland full Xauth merge, snap-readable kiosk-xauth cache, env -u GDK_BACKEND, pre-launch env diagnostics, Firefox stderr capture, snap crash logs, XWayland socket check, Mutter Xauth file list)"
fi
echo ""

# ── Service restart check ──────────────────────────────────────────────────
# After install.sh copies new scripts, the running kiosk-browser.service
# continues to use the old in-memory code until the machine reboots.
# Check the journal: if it contains a startup log line produced only by the
# new code ("FF_USING_XWAYLAND=" in the post-XDG-token state log), the current
# code is running.  If the freshness check passed but the journal doesn't have
# the new log line, the service was not restarted after the last install.
echo "── Service restart check ─────────────────────────────────────────────"
if command -v journalctl &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    _new_code_running=false
    if [[ -n "${KIOSK_UID}" ]]; then
        _new_code_running=$(journalctl --boot --no-pager \
            _UID="${KIOSK_UID}" _SYSTEMD_USER_UNIT="kiosk-browser.service" \
            2>/dev/null \
            | grep -q 'FF_USING_XWAYLAND=' && echo true || echo false)
    fi
    if grep -q '_ff_wayland_slot' "${INSTALLED_LAUNCH}" 2>/dev/null; then
        # Installed script has the snap wayland-plug runtime check; verify it has run.
        if "${_new_code_running}"; then
            _ok  "kiosk-browser.service is running the current installed script"
        else
            _fail "kiosk-browser.service has NOT been restarted since the last install"
            echo "     The running service is using the OLD kiosk-launch.sh."
            echo "     → Reboot (preferred) OR:"
            echo "       sudo -u ${KIOSK_USER} systemctl --user restart kiosk-browser.service"
        fi
    fi
else
    echo "  journalctl not available or kiosk user not found"
fi
echo ""

# ── GDM3 journal ──────────────────────────────────────────────────────────
echo "── GDM3 recent journal (last 30 lines) ───────────────────────────────"
if command -v journalctl &>/dev/null; then
    journalctl -u gdm3 --since "1 hour ago" --no-pager 2>/dev/null | tail -30 | sed 's/^/  /' \
        || echo "  (Could not read GDM3 journal – try running as root)"
else
    echo "  journalctl not available"
fi
echo ""

# ── Kiosk browser service journal ─────────────────────────────────────────
# Run as the kiosk user so journalctl can access the user service journal.
# When collected via SSH, su -c lets a root/admin user retrieve these logs.
# Use --boot (not --since "1 hour ago") so that all log entries from the
# current boot session are visible — the service may have started at login
# time (potentially hours ago) and --since truncates those early entries.
echo "── Kiosk browser service journal (last 100 lines, this boot) ────────"
if command -v journalctl &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    if [[ -n "${KIOSK_UID}" ]]; then
        journalctl --boot --no-pager \
            _UID="${KIOSK_UID}" _SYSTEMD_USER_UNIT="kiosk-browser.service" \
            2>/dev/null | tail -100 | sed 's/^/  /' \
            || echo "  (Could not read kiosk-browser journal -- run as root or as '${KIOSK_USER}')"
    fi
else
    echo "  journalctl not available or kiosk user not found"
fi
echo ""

# ── Firefox process journal ────────────────────────────────────────────────
# Firefox logs its own startup errors under a separate journald identifier
# (_COMM=firefox), distinct from the kiosk-browser.service entries above.
# These entries are essential for diagnosing exit-status-1 startup crashes.
echo "── Firefox process journal (last 50 lines) ──────────────────────────"
if command -v journalctl &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    if [[ -n "${KIOSK_UID}" ]]; then
        _ff_log=$(journalctl --boot --no-pager _UID="${KIOSK_UID}" _COMM=firefox \
            2>/dev/null | tail -50)
        if [[ -n "${_ff_log}" ]]; then
            echo "${_ff_log}" | sed 's/^/  /'
        else
            echo "  (no Firefox journal entries this boot)"
        fi
    fi
else
    echo "  journalctl not available or kiosk user not found"
fi
echo ""

# ── snap Firefox logs ──────────────────────────────────────────────────────
# 'snap logs firefox' shows the snap.firefox.firefox systemd service journal,
# which captures Firefox's own stdout/stderr before the process crashes.
echo "── snap Firefox logs (last 50 lines) ────────────────────────────────"
if "${_diag_ff_is_snap}" && command -v snap &>/dev/null; then
    snap logs firefox 2>/dev/null | tail -50 | sed 's/^/  /' \
        || echo "  (snap logs command failed – try: sudo snap logs firefox)"
else
    echo "  ℹ  snap Firefox not detected – snap logs skipped."
fi
echo ""

# ── Firefox stderr log (captured by kiosk-launch.sh) ──────────────────────
# kiosk-launch.sh redirects Firefox's stderr to a temp file in XDG_RUNTIME_DIR
# and dumps it here after a crash.  Requires the latest kiosk-launch.sh.
echo "── Firefox stderr log ────────────────────────────────────────────────"
if [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    if [[ -n "${KIOSK_UID}" ]]; then
        _ff_stderr_file="/run/user/${KIOSK_UID}/kiosk-ff-stderr.log"
        if [[ -s "${_ff_stderr_file}" ]]; then
            echo "  ${_ff_stderr_file} (last 30 lines):"
            tail -30 "${_ff_stderr_file}" | sed 's/^/  /'
        else
            echo "  (${_ff_stderr_file} is empty or absent)"
            echo "  Re-run sudo ./install.sh to deploy the stderr-capture update."
        fi
    else
        echo "  (could not resolve UID for '${KIOSK_USER}')"
    fi
else
    echo "  (kiosk home not found)"
fi
echo ""

# ── Kiosk user session environment ────────────────────────────────────────
# Shows the systemd user environment variables that kiosk-browser.service
# inherits.  Key variables: DISPLAY, WAYLAND_DISPLAY, GDK_BACKEND, DBUS_*.
echo "── Kiosk user session environment ───────────────────────────────────"
if command -v systemctl &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    _kiosk_env=""
    if [[ -n "${KIOSK_UID}" ]]; then
        _kiosk_env=$(sudo -u "${KIOSK_USER}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${KIOSK_UID}/bus" \
            XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}" \
            systemctl --user show-environment 2>/dev/null \
            | grep -E '^(DISPLAY|WAYLAND_DISPLAY|GDK_BACKEND|DBUS_SESSION_BUS_ADDRESS|XDG_SESSION_TYPE|XDG_SESSION_CLASS|XAUTHORITY|MOZ_ENABLE_WAYLAND)=' \
            | sort || true)
    fi
    if [[ -n "${_kiosk_env}" ]]; then
        echo "${_kiosk_env}" | sed 's/^/  /'
    else
        echo "  (could not read systemd user environment for '${KIOSK_USER}')"
        echo "  Try manually: sudo -u ${KIOSK_USER} XDG_RUNTIME_DIR=/run/user/${KIOSK_UID:-1000} systemctl --user show-environment"
    fi
else
    echo "  (systemctl not available or kiosk user not found)"
fi
echo ""

# ── XWayland auth entries ──────────────────────────────────────────────────
# Shows the MIT-MAGIC-COOKIE entries in the snap-readable Xauth cache and in
# Mutter's live XWayland auth file.  Both must contain matching cookies for
# Firefox (inside the snap sandbox) to connect to display :0.
echo "── XWayland auth entries ─────────────────────────────────────────────"
if command -v xauth &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    _xauth_file="${KIOSK_HOME}/snap/firefox/common/kiosk-xauth"
    if [[ -f "${_xauth_file}" ]]; then
        echo "  ${_xauth_file}:"
        xauth -f "${_xauth_file}" list 2>/dev/null | sed 's/^/    /' \
            || echo "    (xauth list failed)"
    else
        echo "  ${_xauth_file} does not exist"
    fi
    _legacy_xauth="${KIOSK_HOME}/.Xauthority"
    if [[ -f "${_legacy_xauth}" ]]; then
        echo "  Legacy ${_legacy_xauth}:"
        xauth -f "${_legacy_xauth}" list 2>/dev/null | sed 's/^/    /' \
            || echo "    (xauth list failed)"
    fi
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    if [[ -n "${KIOSK_UID}" ]]; then
        _mutter_file="$(find "/run/user/${KIOSK_UID}" -maxdepth 1 -type f \
            -name '.mutter-Xwaylandauth.*' 2>/dev/null | head -1 || true)"
        if [[ -n "${_mutter_file}" ]]; then
            echo "  Mutter XWayland auth file: ${_mutter_file}"
            xauth -f "${_mutter_file}" list 2>/dev/null | sed 's/^/    /' \
                || echo "    (xauth list failed)"
        else
            echo "  No .mutter-Xwaylandauth.* file in /run/user/${KIOSK_UID}"
        fi
    fi
else
    echo "  (xauth not available or kiosk user not found)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║   Diagnostic Summary                         ║"
echo "╚══════════════════════════════════════════════╝"
if [[ ${FAIL} -eq 0 ]]; then
    echo "  All checks passed."
    echo "  If autologin still does not work, review the GDM3 journal above"
    echo "  for session startup errors, then reboot and try again."
else
    echo "  ${FAIL} problem(s) found. Re-run:  sudo ./install.sh"
fi
echo ""
