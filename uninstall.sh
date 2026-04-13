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
echo "[1/4] Removing ${INSTALL_DIR}…"
rm -rf "${INSTALL_DIR}"
echo "      Done."

# 2. Remove sudoers entry
echo "[2/4] Removing sudoers entry…"
rm -f /etc/sudoers.d/kiosk-nmcli
echo "      Done."

# 3. Remove dconf system database
echo "[3/4] Removing dconf system database…"
rm -rf /etc/dconf/db/kiosk.d
# Only remove the profile override if it still points to our database
if [[ -f /etc/dconf/profile/user ]]; then
    sed -i '/^system-db:kiosk$/d' /etc/dconf/profile/user
fi
command -v dconf &>/dev/null && dconf update || true
echo "      Done."

# 4. Remove autostart entry and systemd user service for kiosk user
echo "[4/4] Removing autostart entry and systemd service…"
KIOSK_HOME="$(getent passwd "${KIOSK_USER}" 2>/dev/null | cut -d: -f6 || echo "")"
if [[ -n "${KIOSK_HOME}" ]]; then
    rm -f "${KIOSK_HOME}/.config/autostart/kiosk.desktop"
    rm -f "${KIOSK_HOME}/.config/systemd/user/kiosk-browser.service"
    rm -f "${KIOSK_HOME}/.config/systemd/user/graphical-session.target.wants/kiosk-browser.service"
fi
echo "      Done."

echo ""
echo "Kiosk system uninstalled."
echo "The OS user '${KIOSK_USER}' was NOT deleted."
echo "To delete it run:  sudo userdel -r ${KIOSK_USER}"
echo ""
