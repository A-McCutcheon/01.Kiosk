# 1.Kiosk

A self-contained kiosk system for **Ubuntu Desktop LTS** that automatically
logs in, opens a configured website in full-screen kiosk mode, and provides
an operator configuration app for network settings and URL management.

---

## Features

| Feature | Details |
|---|---|
| **Auto login** | Configures GDM3 or LightDM to log in automatically as the kiosk user on boot |
| **Website launcher** | Opens a configured URL in Chromium kiosk mode (full-screen, no address bar) |
| **Break-out shortcut** | Press **Ctrl+Alt+C** at any time to close the browser and reopen the config app |
| **IP / DHCP settings** | GUI to switch any wired or wireless interface between DHCP and static IP |
| **WiFi management** | Scan for networks, select one, enter a password, and connect |
| **URL management** | Enter or change the kiosk website and relaunch instantly |

---

## File Layout

```
1.Kiosk/
├── install.sh              # Run once as root to install everything
├── uninstall.sh            # Removes the installation
├── kiosk-launch.sh         # Launches Chromium in kiosk mode (or config app if no URL set)
├── kiosk-break.sh          # Kills the browser and reopens the config app
├── components/
│   └── kiosk/              # Kiosk component (git submodule)
│       └── config_app.py   # GTK 3 configuration application
├── autostart/
│   └── kiosk.desktop       # GNOME autostart entry installed for the kiosk user
├── LICENSE                 # MIT license (covers the code in this repository)
└── README.md
```

---

## Requirements

- Ubuntu Desktop **22.04 LTS** or **24.04 LTS** (or any Ubuntu Desktop LTS release using GDM3 or LightDM)
- The following packages must be installed: `chromium-browser`, `python3-gi`, `python3-gi-cairo`, `gir1.2-gtk-3.0`, `network-manager`  
  On Ubuntu Desktop LTS, all packages except `chromium-browser` are pre-installed.  
  If all required packages are already installed (or pre-loaded on the machine), **no internet access is required** during installation.

---

## Quick Start

```bash
# Clone or download this repository, then:
sudo ./install.sh [kiosk-username]   # default username: kiosk
```

After installation:

1. **Reboot** the machine.
2. Ubuntu logs in automatically as the kiosk user.
3. The **configuration app** opens on first login (no URL is set yet).
4. Enter the website URL on the **Website** tab and click **Launch Kiosk**.
5. Chromium opens full-screen showing the configured site.
6. Press **Ctrl+Alt+C** at any time to close the browser and return to the config app.

---

## Configuration App

The config app has three tabs:

### Website tab
- Enter the URL to display (e.g. `https://intranet.company.com`).
- **Save URL** – persists the URL to `~/.config/kiosk/kiosk.conf`.
- **Launch Kiosk** – saves the URL and starts Chromium in kiosk mode.
- **Restart Kiosk** – kills any running Chromium instance and relaunches it.
- **Reboot Device** – prompts for confirmation then reboots the device.

### Network tab
- Choose a network interface from the dropdown.
- Select **DHCP** (automatic) or **Static IP**.
- For Static IP, fill in: IP address, subnet mask, gateway, DNS 1, DNS 2.
- Click **Apply Network Settings** to activate the change immediately via NetworkManager.

### WiFi tab
- Click **Scan for WiFi Networks** to list available SSIDs.
- Select a network in the list.
- Enter the password (leave blank for open networks).
- Click **Connect to Selected Network**.

---

## Break Out of Kiosk Mode

Press **Ctrl+Alt+C** while the kiosk browser is open.  
This shortcut is registered as a GNOME system shortcut during installation and
works even when Chromium has keyboard focus.

The browser closes and the configuration app reopens automatically.

---

## Uninstall

```bash
sudo ./uninstall.sh [kiosk-username]   # default: kiosk
```

This removes `/opt/kiosk`, the sudoers rule, the dconf shortcut, and the
autostart entry, and disables auto-login.  The OS user is **not** deleted
automatically; run `sudo userdel -r kiosk` if you also want to remove it.

---

## License Compliance

All components used are permitted for **commercial deployment**:

| Component | License | Commercial use |
|---|---|---|
| Code in this repository | **MIT License** | ✅ Unrestricted |
| Python 3 | PSF License 2 | ✅ Permissive |
| PyGObject (python3-gi) | LGPL 2.1+ | ✅ Dynamic linking — no source obligation |
| GTK 3 | LGPL 2.1+ | ✅ Dynamic linking — no source obligation |
| Chromium | BSD 3-Clause | ✅ Permissive |
| NetworkManager / nmcli | GPL 2 | ✅ Used as an unmodified system tool; GPL applies only to distribution of modified source |
| Ubuntu Desktop LTS | Mixed (Canonical) | ✅ Standard commercial deployment permitted |

> **Note on GPL system tools:** Installing and running unmodified GPL software
> (such as NetworkManager) on a deployed system does **not** require you to
> release your own source code.  The GPL copyleft clause is triggered only when
> you *distribute* a modified copy of the GPL-licensed program itself.
