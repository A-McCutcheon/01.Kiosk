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
for tool in xdotool wmctrl gdbus; do
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
KIOSK_USER_JS="${KIOSK_HOME}/.config/kiosk/firefox-profile/user.js"
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
elif ! grep -q 'snap/firefox' "${INSTALLED_LAUNCH}" 2>/dev/null; then
    _fail "${INSTALLED_LAUNCH} is outdated (missing comprehensive Firefox lock cleanup)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
elif ! grep -q '_WAYLAND_SESSION' /opt/kiosk/kiosk-exit-overlay.py 2>/dev/null; then
    _fail "/opt/kiosk/kiosk-exit-overlay.py is outdated (missing Wayland-aware overlay detection)"
    echo "     → Re-run: sudo ./install.sh  (copies latest scripts to /opt/kiosk)"
else
    _ok  "${INSTALLED_LAUNCH} is up-to-date (Wayland-native launch, kiosk profile, lock cleanup)"
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
echo "── Kiosk browser service journal (last 50 lines) ────────────────────"
if command -v journalctl &>/dev/null && [[ -n "${KIOSK_HOME}" ]]; then
    KIOSK_UID=$(id -u "${KIOSK_USER}" 2>/dev/null || true)
    if [[ -n "${KIOSK_UID}" ]]; then
        journalctl --since "1 hour ago" --no-pager \
            _UID="${KIOSK_UID}" _SYSTEMD_USER_UNIT="kiosk-browser.service" \
            2>/dev/null | tail -50 | sed 's/^/  /' \
            || echo "  (Could not read kiosk-browser journal -- run as root or as '${KIOSK_USER}')"
    fi
else
    echo "  journalctl not available or kiosk user not found"
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
