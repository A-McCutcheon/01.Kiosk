#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# uninstall.sh  –  Remove the Kiosk system installed by install.sh
#
# Usage:
#   sudo ./uninstall.sh [kiosk-username]

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run this script as root:  sudo ./uninstall.sh [username]"
    exit 1
fi

KIOSK_USER="${1:-kiosk}"
INSTALL_DIR="/opt/kiosk"

echo "╔══════════════════════════════════════════════╗"
echo "║       Kiosk System Uninstaller               ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Kiosk user  : ${KIOSK_USER}"
echo ""

# 1. Remove installed scripts
echo "[1/5] Removing ${INSTALL_DIR}…"
rm -rf "${INSTALL_DIR}"
echo "      Done."

# 2. Remove sudoers entry
echo "[2/5] Removing sudoers entry…"
rm -f /etc/sudoers.d/kiosk-nmcli
echo "      Done."

# 3. Remove dconf system database
echo "[3/5] Removing dconf system database…"
rm -rf /etc/dconf/db/kiosk.d
# Only remove the profile override if it still points to our database
if [[ -f /etc/dconf/profile/user ]]; then
    sed -i '/^system-db:kiosk$/d' /etc/dconf/profile/user
fi
command -v dconf &>/dev/null && dconf update || true
echo "      Done."

# 4. Remove autostart entry for kiosk user
echo "[4/5] Removing autostart entry…"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" 2>/dev/null | cut -d: -f6 || echo "")"
if [[ -n "${KIOSK_HOME}" && -f "${KIOSK_HOME}/.config/autostart/kiosk.desktop" ]]; then
    rm -f "${KIOSK_HOME}/.config/autostart/kiosk.desktop"
fi
echo "      Done."

# 5. Disable auto-login
echo "[5/5] Disabling automatic login…"
if [[ -f /etc/gdm3/custom.conf ]]; then
    sed -i \
        -e 's/^AutomaticLoginEnable=true/AutomaticLoginEnable=false/' \
        -e "s/^AutomaticLogin=${KIOSK_USER}/# AutomaticLogin=/" \
        /etc/gdm3/custom.conf
    echo "      Disabled GDM3 auto-login."
elif [[ -f /etc/lightdm/lightdm.conf ]]; then
    sed -i \
        -e "s|^autologin-user=${KIOSK_USER}|#autologin-user=|" \
        -e 's|^autologin-user-timeout=0|#autologin-user-timeout=0|' \
        /etc/lightdm/lightdm.conf
    gpasswd -d "${KIOSK_USER}" autologin 2>/dev/null || true
    echo "      Disabled LightDM auto-login."
fi

echo ""
echo "Kiosk system uninstalled."
echo "The OS user '${KIOSK_USER}' was NOT deleted."
echo "To delete it run:  sudo userdel -r ${KIOSK_USER}"
echo ""
