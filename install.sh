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
#  1. Installs required packages (Chromium, Python 3 + GTK bindings)
#  2. Creates the kiosk OS user with a locked password
#  3. Configures automatic login via GDM3 or LightDM
#  4. Grants the kiosk user password-less nmcli access (sudoers)
#  5. Copies the kiosk scripts to /opt/kiosk
#  6. Configures GNOME autostart so the kiosk launcher runs on login
#  7. Registers Ctrl+Alt+C as a GNOME shortcut to break out of kiosk mode

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
echo "[1/7] Checking required packages…"
REQUIRED_PKGS=(chromium-browser python3-gi python3-gi-cairo gir1.2-gtk-3.0 network-manager)
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
echo "[2/7] Setting up OS user '${KIOSK_USER}'…"
if ! id "${KIOSK_USER}" &>/dev/null; then
    useradd -m -s /bin/bash -c "Kiosk User" "${KIOSK_USER}"
    # Lock the password – the account is access-controlled via auto-login only
    passwd -l "${KIOSK_USER}"
    echo "      Created locked user: ${KIOSK_USER}"
else
    echo "      User ${KIOSK_USER} already exists, skipping creation."
fi

KIOSK_HOME="$(getent passwd "${KIOSK_USER}" | cut -d: -f6)"

# ── 3. Auto-login ──────────────────────────────────────────────────────────
echo "[3/7] Configuring automatic login…"

configure_gdm3() {
    local user="$1"
    local conf="/etc/gdm3/custom.conf"
    python3 - "${user}" "${conf}" <<'PYEOF'
import sys, re

user, conf = sys.argv[1], sys.argv[2]
with open(conf) as f:
    text = f.read()

# Enable AutomaticLogin under [daemon]
if re.search(r'AutomaticLoginEnable', text):
    text = re.sub(r'#?\s*AutomaticLoginEnable\s*=.*',
                  'AutomaticLoginEnable=true', text)
else:
    text = text.replace('[daemon]', '[daemon]\nAutomaticLoginEnable=true', 1)

if re.search(r'AutomaticLogin\b', text):
    text = re.sub(r'#?\s*AutomaticLogin\s*=.*',
                  f'AutomaticLogin={user}', text)
else:
    text = text.replace('AutomaticLoginEnable=true',
                        f'AutomaticLoginEnable=true\nAutomaticLogin={user}', 1)

with open(conf, 'w') as f:
    f.write(text)
PYEOF
}

configure_lightdm() {
    local user="$1"
    local conf="/etc/lightdm/lightdm.conf"
    sed -i \
        -e "s|#\?autologin-user=.*|autologin-user=${user}|" \
        -e "s|#\?autologin-user-timeout=.*|autologin-user-timeout=0|" \
        "${conf}"
}

if [[ -f /etc/gdm3/custom.conf ]]; then
    configure_gdm3 "${KIOSK_USER}"
    echo "      Configured GDM3 auto-login."
elif [[ -f /etc/lightdm/lightdm.conf ]]; then
    configure_lightdm "${KIOSK_USER}"
    echo "      Configured LightDM auto-login."
else
    echo "      WARNING: No supported display manager detected."
    echo "               Please enable auto-login for '${KIOSK_USER}' manually."
fi

# ── 4. Sudoers – nmcli without password ────────────────────────────────────
echo "[4/7] Configuring nmcli sudo privileges…"
SUDOERS_FILE="/etc/sudoers.d/kiosk-nmcli"
cat > "${SUDOERS_FILE}" <<EOF
# Allow the kiosk user to manage network connections without a password prompt.
# Only /usr/bin/nmcli is permitted; no shell escapes are possible via nmcli.
${KIOSK_USER} ALL=(ALL) NOPASSWD: /usr/bin/nmcli
# Allow the kiosk user to reboot the device without a password prompt.
${KIOSK_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl reboot
EOF
chmod 0440 "${SUDOERS_FILE}"
echo "      Wrote ${SUDOERS_FILE}"

# ── 5. Install kiosk scripts ────────────────────────────────────────────────
echo "[5/7] Installing kiosk scripts to ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"
cp "${SCRIPT_DIR}/kiosk-launch.sh"  "${INSTALL_DIR}/"
cp "${SCRIPT_DIR}/kiosk-break.sh"   "${INSTALL_DIR}/"
cp -r "${SCRIPT_DIR}/kiosk-config/" "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/kiosk-launch.sh"
chmod +x "${INSTALL_DIR}/kiosk-break.sh"
chmod +x "${INSTALL_DIR}/kiosk-config/config_app.py"
echo "      Done."

# ── 6. GNOME autostart ─────────────────────────────────────────────────────
echo "[6/7] Configuring GNOME autostart…"
AUTOSTART_DIR="${KIOSK_HOME}/.config/autostart"
mkdir -p "${AUTOSTART_DIR}"
cp "${SCRIPT_DIR}/autostart/kiosk.desktop" "${AUTOSTART_DIR}/"
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config"
echo "      Wrote ${AUTOSTART_DIR}/kiosk.desktop"

# ── 7. Ctrl+Alt+C break-out shortcut ──────────────────────────────────────
echo "[7/7] Registering Ctrl+Alt+C keyboard shortcut…"
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

# Database: define the custom keybinding
cat > "${DCONF_DB_DIR}/00-kiosk-keybindings" <<'EOF'
[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0]
name='Kiosk Config'
command='/opt/kiosk/kiosk-break.sh'
binding='<Control><Alt>c'
EOF

# Compile the dconf database
if command -v dconf &>/dev/null; then
    dconf update
    echo "      Ctrl+Alt+C shortcut registered via dconf."
else
    echo "      WARNING: dconf not found; shortcut will be applied on first login."
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Installation complete                      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "  1. Reboot the machine."
echo "  2. It will auto-login as '${KIOSK_USER}' and open the config app."
echo "  3. Enter the website URL and click 'Launch Kiosk'."
echo "  4. Press Ctrl+Alt+C at any time to return to the config app."
echo ""
