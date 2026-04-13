#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install.sh  –  Kiosk System Installer for Ubuntu Desktop LTS
#
# Usage:
#   sudo ./install.sh [kiosk-username]
#
# The optional argument sets the dedicated kiosk OS user (default: "kiosk").
# The user is created automatically if it does not already exist.
#
# What this script does
# ─────────────────────
#  1. Installs required packages (Firefox, Python 3 + GTK bindings)
#  2. Creates the kiosk OS user with a locked password
#  3. Grants the kiosk user password-less nmcli access (sudoers)
#  4. Copies the kiosk scripts to /opt/kiosk
#  5. Configures GNOME autostart so the kiosk launcher runs on login
#  6. Registers Ctrl+Alt+C as a GNOME shortcut to break out of kiosk mode
#     and installs a persistent on-screen overlay button for touchscreens
#     and VirtualBox environments

set -euo pipefail

# ── Privilege check ────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root:  sudo ./install.sh [username]"
    exit 1
fi

KIOSK_USER="${1:-kiosk}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/kiosk"

echo "╔══════════════════════════════════════════════╗"
echo "║       Kiosk System Installer                 ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Kiosk user  : ${KIOSK_USER}"
echo "  Install dir : ${INSTALL_DIR}"
echo ""

# ── 1. Packages ────────────────────────────────────────────────────────────
echo "[1/6] Checking required packages…"
REQUIRED_PKGS=(firefox python3-gi python3-gi-cairo gir1.2-gtk-3.0 network-manager dnsmasq xdotool)
# onboard is no longer required.  The recommended on-screen keyboard on
# Ubuntu 24.04 GNOME Shell is the built-in GNOME Screen Keyboard (enable via
# Settings → Accessibility → Typing → Screen Keyboard).  If you need the
# legacy Onboard keyboard instead, install it manually: apt-get install onboard
MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg-query -W -f='${db:Status-Status}' "${pkg}" 2>/dev/null | grep -q '^installed$'; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -eq 0 ]]; then
    echo "      All required packages are already installed."
else
    echo "      Installing missing packages: ${MISSING_PKGS[*]}"
    apt-get update -qq
    apt-get install -y "${MISSING_PKGS[@]}"
fi
echo "      Done."

# ── 2. Kiosk OS user ───────────────────────────────────────────────────────
echo "[2/6] Setting up OS user '${KIOSK_USER}'…"
if ! id "${KIOSK_USER}" &>/dev/null; then
    useradd -m -s /bin/bash -c "Kiosk User" "${KIOSK_USER}"
    # Lock the password – the account should only be accessed via display manager
    # autologin (configured separately outside this script).
    passwd -l "${KIOSK_USER}"
    echo "      Created locked user: ${KIOSK_USER}"
else
    echo "      User ${KIOSK_USER} already exists, skipping creation."
fi

KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"

# ── 3. Sudoers – nmcli without password ────────────────────────────────────
echo "[3/6] Configuring nmcli sudo privileges…"
SUDOERS_FILE="/etc/sudoers.d/kiosk-nmcli"
cat > "${SUDOERS_FILE}" <<EOF
# Allow the kiosk user to manage network connections without a password prompt.
# Only /usr/bin/nmcli is permitted; no shell escapes are possible via nmcli.
${KIOSK_USER} ALL=(ALL) NOPASSWD: /usr/bin/nmcli
# Allow the kiosk user to reboot the device without a password prompt.
${KIOSK_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot
# Allow the kiosk user to shut down the device without a password prompt.
${KIOSK_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl poweroff
EOF
chmod 0440 "${SUDOERS_FILE}"
echo "      Wrote ${SUDOERS_FILE}"

# ── 4. Install kiosk scripts ────────────────────────────────────────────────
echo "[4/6] Installing kiosk scripts to ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"
cp "${SCRIPT_DIR}/kiosk-launch.sh"        "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/kiosk-break.sh"         "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/kiosk-exit-overlay.py"  "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/kiosk-diag.sh"          "${INSTALL_DIR}/"
cp -r "${SCRIPT_DIR}/kiosk-config/"       "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/kiosk-launch.sh"
chmod +x "${INSTALL_DIR}/kiosk-break.sh"
chmod +x "${INSTALL_DIR}/kiosk-exit-overlay.py"
chmod +x "${INSTALL_DIR}/kiosk-diag.sh"
chmod +x "${INSTALL_DIR}/kiosk-config/config_app.py"
echo "      Done."

# ── 5. GNOME autostart & systemd user service ─────────────────────────────
echo "[5/6] Configuring kiosk autostart…"
AUTOSTART_DIR="${KIOSK_HOME}/.config/autostart"
SYSTEMD_USER_DIR="${KIOSK_HOME}/.config/systemd/user"
SYSTEMD_WANTS_DIR="${SYSTEMD_USER_DIR}/graphical-session.target.wants"
mkdir -p "${AUTOSTART_DIR}" "${SYSTEMD_WANTS_DIR}"

# Install the systemd user service (preferred over .desktop autostart).
# The service uses After=graphical-session.target which is only reached by
# gnome-session once GNOME Shell and the Mutter compositor have completed
# their startup handshake — eliminating the compositor-race black screen.
cp "${SCRIPT_DIR}/systemd/kiosk-browser.service" "${SYSTEMD_USER_DIR}/kiosk-browser.service"
ln -sf "../kiosk-browser.service" "${SYSTEMD_WANTS_DIR}/kiosk-browser.service"
echo "      Installed systemd user service: ${SYSTEMD_USER_DIR}/kiosk-browser.service"

# Deploy the .desktop autostart entry (disabled in source; the systemd
# service is the sole startup mechanism).  kiosk-launch.sh also uses a
# flock guard so a second launch exits cleanly if both entries are active.
cp "${SCRIPT_DIR}/autostart/kiosk.desktop" "${AUTOSTART_DIR}/"
echo "      Wrote ${AUTOSTART_DIR}/kiosk.desktop (autostart disabled – service is primary)"

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config"

# ── 6. Ctrl+Alt+C break-out shortcut ──────────────────────────────────────
echo "[6/6] Registering Ctrl+Alt+C keyboard shortcut and Firefox policies…"
# gsettings must run as the target user inside a D-Bus session.
# At install time there is no live user session, so we write the shortcut
# into the user's dconf database directly via a profile override file.
DCONF_PROFILE_DIR="/etc/dconf/profile"
DCONF_DB_DIR="/etc/dconf/db/kiosk.d"
mkdir -p "${DCONF_PROFILE_DIR}" "${DCONF_DB_DIR}"

# Profile: tell dconf to read from the 'kiosk' system database first
cat > "${DCONF_PROFILE_DIR}/user" <<'EOF'
user-db:user
system-db:kiosk
EOF

# Database: define the custom keybinding and accessibility settings
cat > "${DCONF_DB_DIR}/00-kiosk-keybindings" <<'EOF'
[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0]
name='Kiosk Config'
command='/opt/kiosk/kiosk-break.sh'
binding='<Control><Alt>c'

[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true

# ── Prevent screen blanking and lock on a kiosk display ──────────────────
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-timeout=0
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-timeout=0
sleep-inactive-battery-type='nothing'
idle-dim=false

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0
EOF

# Compile the dconf database
if command -v dconf &>/dev/null; then
    dconf update
    echo "      Ctrl+Alt+C shortcut registered via dconf."
else
    echo "      WARNING: dconf not found; settings will be applied on first login."
fi

# ── Firefox policies ───────────────────────────────────────────────────────
# Suppress first-run pages, default-browser prompts, and telemetry so the
# kiosk opens cleanly on every boot.  /etc/firefox/policies/policies.json
# is read by both the deb and snap packages of Firefox.
FIREFOX_POLICY_DIR="/etc/firefox/policies"
mkdir -p "${FIREFOX_POLICY_DIR}"
cat > "${FIREFOX_POLICY_DIR}/policies.json" <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "DisplayBookmarksToolbar": "never",
    "DisplayMenuBar": "default-off",
    "Preferences": {
      "gfx.webrender.all": {
        "Value": false,
        "Status": "locked"
      },
      "layers.acceleration.disabled": {
        "Value": true,
        "Status": "locked"
      }
    }
  }
}
EOF
echo "      Firefox policies written to ${FIREFOX_POLICY_DIR}/policies.json"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Installation complete                      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Next steps (after reboot):"
echo "  1. Configure autologin for '${KIOSK_USER}' in your display manager, then reboot."
echo "  2. Enter the website URL and click 'Launch Kiosk'."
echo "  3. Press Ctrl+Alt+C at any time to return to the config app."
echo "     Or tap/click the on-screen '⚙ Exit' button (bottom-right corner)."
echo "     Or tap/click the on-screen '⏻ Shutdown' button to power off."
echo "  4. Use GNOME's built-in Screen Keyboard (swipe up from the bottom, or enable via"
echo "     Settings → Accessibility → Typing → Screen Keyboard)."
echo "  Note: the kiosk browser is now started by a systemd user service"
echo "        (graphical-session.target.wants/kiosk-browser.service)."
echo "        The .desktop autostart entry has been disabled to prevent a double-launch."
echo ""
echo "  Rebooting now…"
sleep 3
systemctl reboot
