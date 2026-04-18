# 1.Kiosk

A self-contained kiosk system for **Ubuntu Desktop LTS** that automatically
logs in, opens a configured website in full-screen kiosk mode, and provides
an operator configuration app for network settings and URL management.


---

## Features

| Feature | Details |
|---|---|
| **Auto login** | Configures GDM3 or LightDM to log in automatically as the kiosk user on boot |
| **Website launcher** | Opens a configured URL in Firefox kiosk mode (full-screen, no address bar) |
| **Break-out shortcut** | Press **Ctrl+Alt+C** at any time to close the browser and reopen the config app |
| **Break-out button** | Tap or click the **⚙ Exit** button (bottom-right corner, always visible) — works on touchscreens and in VirtualBox |
| **Shutdown button** | Tap or click the **⏻ Shutdown** button (above the Exit button) to power off the system with a confirmation prompt |
| **IP / DHCP settings** | GUI to switch any wired or wireless interface between DHCP and static IP |
| **WiFi management** | Scan for networks, select one, enter a password, and connect |
| **URL management** | Enter or change the kiosk website and relaunch instantly |

---

## File Layout

```
1.Kiosk/
├── install.sh              # Run once as root to install everything
├── uninstall.sh            # Removes the installation
├── kiosk-launch.sh         # Launches Firefox in kiosk mode (or config app if no URL set)
├── kiosk-break.sh          # Kills the browser and reopens the config app
├── kiosk-exit-overlay.py   # Always-on-top exit button (touchscreen / VirtualBox)
├── kiosk-diag.sh           # Diagnostic script – run if autologin is not working
├── kiosk-config/
│   └── config_app.py       # GTK 3 configuration application
├── autostart/
│   └── kiosk.desktop       # GNOME autostart entry installed for the kiosk user
├── LICENSE                 # MIT license (covers the code in this repository)
└── README.md
```

---

## Requirements

- Ubuntu Desktop **22.04 LTS** or **24.04 LTS** (or any Ubuntu Desktop LTS release using GDM3 or LightDM)
- **Ubuntu 24.04 GNOME Shell**: run under **Wayland** (the default) for best on-screen keyboard support (see [On-Screen Keyboard](#on-screen-keyboard) below).
- The following packages must be installed: `firefox`, `python3-gi`, `python3-gi-cairo`, `gir1.2-gtk-3.0`, `network-manager`  
  On Ubuntu Desktop LTS, all packages except `firefox` are pre-installed.  
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
5. Firefox opens full-screen showing the configured site.
6. Press **Ctrl+Alt+C** at any time to close the browser and return to the config app.  
   Alternatively, tap or click the **⚙ Exit** button in the bottom-right corner of the screen.
   To power off the device, tap or click the **⏻ Shutdown** button directly above the Exit button.

---

## Configuration App

The config app has three tabs:

### Website tab
- Enter the URL to display (e.g. `https://intranet.company.com`).
- **Save URL** – persists the URL to `~/.config/kiosk/kiosk.conf`.
- **Launch Kiosk** – saves the URL and starts Firefox in kiosk mode.
- **Restart Kiosk** – kills any running Firefox instance and relaunches it.
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

## On-Screen Keyboard

On **Ubuntu 24.04 GNOME Shell**, the recommended on-screen keyboard is the
**GNOME built-in Screen Keyboard**.  It works natively under Wayland and
integrates cleanly with GNOME's touch gestures.

### Enabling the GNOME Screen Keyboard

1. Open **Settings → Accessibility**.
2. Under **Typing**, toggle **Screen Keyboard** to **On**.
3. The keyboard will appear automatically when a text field gains focus, or
   you can swipe up from the bottom edge of the screen to show it manually.

> **Note:** Onboard (a separate X11 on-screen keyboard) is no longer installed
> by default and is not launched by the overlay.  If you need Onboard for an
> older Xorg-based setup, install it manually: `sudo apt-get install onboard`.

---

## Break Out of Kiosk Mode

There are two ways to exit kiosk mode and return to the configuration app:

1. **On-screen button (touchscreen / VirtualBox)** – Tap or click the **⚙ Exit** button
   visible in the bottom-right corner of the screen at all times while the kiosk is running.
   This method works on touchscreen displays and in VirtualBox environments where
   keyboard shortcuts may be intercepted by the host.

2. **Keyboard shortcut** – Press **Ctrl+Alt+C** while the kiosk browser is open.
   This shortcut is registered as a GNOME system shortcut during installation and
   works even when Firefox has keyboard focus.

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

## Troubleshooting

### Autologin not working after installation

Run the built-in diagnostic script to check all autologin prerequisites in one step:

```bash
sudo /opt/kiosk/kiosk-diag.sh
```

The script checks:
- `/etc/gdm3/custom.conf` for `AutomaticLoginEnable=true` and `AutomaticLogin=kiosk`
- That the kiosk OS user and home directory exist
- That the GNOME autostart entry and first-run wizard suppression marker are in place
- Recent GDM3 journal entries for session startup errors

> **Wayland vs Xorg:** On Ubuntu 24.04 GNOME Shell, Wayland is the default and
> is recommended for this kiosk (it provides the best GNOME on-screen keyboard
> experience).  The diagnostic script no longer requires `WaylandEnable=false`.
> If you previously forced Xorg by setting `WaylandEnable=false` in
> `/etc/gdm3/custom.conf`, you can remove or revert that line to re-enable
> Wayland.  Forcing Xorg is optional and may break GNOME OSK swipe gestures.

If any check fails, re-run `sudo ./install.sh` from the repository directory.

If all checks pass but autologin still does not work, check the GDM3 journal directly:

```bash
sudo journalctl -u gdm3 --since "10 minutes ago" --no-pager
```

---

## License Compliance

All components used are permitted for **commercial deployment**:

| Component | License | Commercial use |
|---|---|---|
| Code in this repository | **MIT License** | ✅ Unrestricted |
| Python 3 | PSF License 2 | ✅ Permissive |
| PyGObject (python3-gi) | LGPL 2.1+ | ✅ Dynamic linking — no source obligation |
| GTK 3 | LGPL 2.1+ | ✅ Dynamic linking — no source obligation |
| Firefox | MPL 2.0 | ✅ Permissive |
| NetworkManager / nmcli | GPL 2 | ✅ Used as an unmodified system tool; GPL applies only to distribution of modified source |
| Ubuntu Desktop LTS | Mixed (Canonical) | ✅ Standard commercial deployment permitted |

> **Note on GPL system tools:** Installing and running unmodified GPL software
> (such as NetworkManager) on a deployed system does **not** require you to
> release your own source code.  The GPL copyleft clause is triggered only when
> you *distribute* a modified copy of the GPL-licensed program itself.
