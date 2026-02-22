#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Kiosk Configuration Application
Provides a GTK3 GUI for managing the kiosk URL, network (IP/DHCP), and WiFi.

License notes:
  - This file: MIT
  - PyGObject / GTK 3: LGPL 2.1+ (commercially deployable)
  - NetworkManager (nmcli): used as a system tool; GPL does not restrict deployment
"""

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

import json
import os
import re
import subprocess
import threading

CONFIG_DIR  = os.path.expanduser('~/.config/kiosk')
CONFIG_FILE = os.path.join(CONFIG_DIR, 'kiosk.conf')

DEFAULT_CONFIG = {
    'url': '',
    'network': {
        'interface': '',
        'mode': 'dhcp',
        'ip': '',
        'netmask': '',
        'gateway': '',
        'dns1': '',
        'dns2': '',
    }
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r') as f:
                cfg = json.load(f)
            # Ensure all top-level keys exist
            for key, val in DEFAULT_CONFIG.items():
                cfg.setdefault(key, val)
            cfg.setdefault('network', {})
            for key, val in DEFAULT_CONFIG['network'].items():
                cfg['network'].setdefault(key, val)
            return cfg
        except (json.JSONDecodeError, IOError):
            pass
    return {k: (v.copy() if isinstance(v, dict) else v)
            for k, v in DEFAULT_CONFIG.items()}


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, 'w') as f:
        json.dump(cfg, f, indent=2)


def run_cmd(cmd, timeout=30):
    """Return (returncode, stdout, stderr)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return -1, '', 'Command timed out'
    except Exception as exc:
        return -1, '', str(exc)


def netmask_to_cidr(netmask):
    """Accept dotted-decimal or plain integer; return CIDR prefix length string."""
    netmask = netmask.strip()
    if re.fullmatch(r'\d+', netmask):
        return netmask
    try:
        bits = ''.join(f'{int(p):08b}' for p in netmask.split('.'))
        return str(bits.count('1'))
    except Exception:
        return '24'


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class KioskConfigApp(Gtk.Window):

    def __init__(self):
        super().__init__(title='Kiosk Configuration')
        self.set_default_size(640, 520)
        self.set_border_width(12)
        self.connect('delete-event', Gtk.main_quit)

        self.config = load_config()

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.add(root)

        # Header
        header = Gtk.Label()
        header.set_markup('<big><b>Kiosk Configuration</b></big>')
        header.set_margin_bottom(6)
        root.pack_start(header, False, False, 0)

        # Notebook
        nb = Gtk.Notebook()
        root.pack_start(nb, True, True, 0)
        nb.append_page(self._build_website_tab(), Gtk.Label(label='Website'))
        nb.append_page(self._build_network_tab(), Gtk.Label(label='Network'))
        nb.append_page(self._build_wifi_tab(),    Gtk.Label(label='WiFi'))

        # Status bar
        self._status = Gtk.Label(label='')
        self._status.set_xalign(0)
        self._status.set_ellipsize(3)   # PANGO_ELLIPSIZE_END
        root.pack_end(self._status, False, False, 4)

    # ------------------------------------------------------------------
    # Status helpers
    # ------------------------------------------------------------------

    def _set_status(self, msg, error=False):
        colour = 'red' if error else 'darkgreen'
        self._status.set_markup(
            f'<span foreground="{colour}">{GLib.markup_escape_text(msg)}</span>'
        )

    # ------------------------------------------------------------------
    # Website tab
    # ------------------------------------------------------------------

    def _build_website_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)

        lbl = Gtk.Label(label='Enter the URL to open in kiosk mode:')
        lbl.set_xalign(0)
        box.pack_start(lbl, False, False, 0)

        self._url_entry = Gtk.Entry()
        self._url_entry.set_text(self.config.get('url', ''))
        self._url_entry.set_placeholder_text('https://www.example.com')
        box.pack_start(self._url_entry, False, False, 0)

        btn_row = Gtk.Box(spacing=8)
        box.pack_start(btn_row, False, False, 6)

        save_btn = Gtk.Button(label='Save URL')
        save_btn.connect('clicked', self._on_save_url)
        btn_row.pack_start(save_btn, False, False, 0)

        launch_btn = Gtk.Button(label='Launch Kiosk')
        launch_btn.get_style_context().add_class('suggested-action')
        launch_btn.connect('clicked', self._on_launch_kiosk)
        btn_row.pack_start(launch_btn, False, False, 0)

        btn_row2 = Gtk.Box(spacing=8)
        box.pack_start(btn_row2, False, False, 0)

        restart_btn = Gtk.Button(label='Restart Kiosk')
        restart_btn.connect('clicked', self._on_restart_kiosk)
        btn_row2.pack_start(restart_btn, False, False, 0)

        reboot_btn = Gtk.Button(label='Reboot Device')
        reboot_btn.get_style_context().add_class('destructive-action')
        reboot_btn.connect('clicked', self._on_reboot_device)
        btn_row2.pack_start(reboot_btn, False, False, 0)

        return box

    # ------------------------------------------------------------------
    # Network tab
    # ------------------------------------------------------------------

    def _build_network_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)

        # Interface selector
        iface_row = Gtk.Box(spacing=8)
        iface_row.pack_start(Gtk.Label(label='Interface:'), False, False, 0)
        self._iface_combo = Gtk.ComboBoxText()
        self._populate_interfaces()
        iface_row.pack_start(self._iface_combo, True, True, 0)
        box.pack_start(iface_row, False, False, 0)

        # DHCP / Static radio buttons
        mode_row = Gtk.Box(spacing=12)
        self._dhcp_radio   = Gtk.RadioButton.new_with_label(None, 'DHCP (automatic)')
        self._static_radio = Gtk.RadioButton.new_with_label_from_widget(
            self._dhcp_radio, 'Static IP')
        net_cfg = self.config.get('network', {})
        if net_cfg.get('mode', 'dhcp') == 'static':
            self._static_radio.set_active(True)
        else:
            self._dhcp_radio.set_active(True)
        self._dhcp_radio.connect('toggled', self._on_mode_changed)
        mode_row.pack_start(self._dhcp_radio,   False, False, 0)
        mode_row.pack_start(self._static_radio, False, False, 0)
        box.pack_start(mode_row, False, False, 0)

        # Static IP fields
        self._static_frame = Gtk.Frame(label='Static IP Settings')
        grid = Gtk.Grid(column_spacing=10, row_spacing=6)
        grid.set_border_width(10)
        self._static_frame.add(grid)

        fields = [
            ('IP Address:',  'ip',      '192.168.1.100'),
            ('Subnet Mask:', 'netmask', '255.255.255.0 or 24'),
            ('Gateway:',     'gateway', '192.168.1.1'),
            ('DNS 1:',       'dns1',    '8.8.8.8'),
            ('DNS 2:',       'dns2',    '8.8.4.4'),
        ]
        self._net_entries = {}
        for row, (label_text, key, placeholder) in enumerate(fields):
            lbl = Gtk.Label(label=label_text)
            lbl.set_xalign(1)
            entry = Gtk.Entry()
            entry.set_text(net_cfg.get(key, ''))
            entry.set_placeholder_text(placeholder)
            grid.attach(lbl,   0, row, 1, 1)
            grid.attach(entry, 1, row, 1, 1)
            self._net_entries[key] = entry

        box.pack_start(self._static_frame, False, False, 0)

        apply_btn = Gtk.Button(label='Apply Network Settings')
        apply_btn.connect('clicked', self._on_apply_network)
        box.pack_start(apply_btn, False, False, 0)

        # Sync sensitivity
        self._on_mode_changed(self._dhcp_radio)
        return box

    # ------------------------------------------------------------------
    # WiFi tab
    # ------------------------------------------------------------------

    def _build_wifi_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(20)

        scan_btn = Gtk.Button(label='Scan for WiFi Networks')
        scan_btn.connect('clicked', self._on_wifi_scan)
        box.pack_start(scan_btn, False, False, 0)

        # Network list
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_height(200)
        self._wifi_store = Gtk.ListStore(str, str, str)   # SSID, Signal, Security
        tv = Gtk.TreeView(model=self._wifi_store)
        for idx, col_name in enumerate(['SSID', 'Signal', 'Security']):
            col = Gtk.TreeViewColumn(
                col_name, Gtk.CellRendererText(), text=idx)
            col.set_resizable(True)
            tv.append_column(col)
        self._wifi_tv = tv
        scroll.add(tv)
        box.pack_start(scroll, True, True, 0)

        # Password
        pwd_row = Gtk.Box(spacing=8)
        pwd_row.pack_start(Gtk.Label(label='Password:'), False, False, 0)
        self._wifi_pwd = Gtk.Entry()
        self._wifi_pwd.set_visibility(False)
        self._wifi_pwd.set_placeholder_text('Leave blank for open networks')
        pwd_row.pack_start(self._wifi_pwd, True, True, 0)
        box.pack_start(pwd_row, False, False, 0)

        connect_btn = Gtk.Button(label='Connect to Selected Network')
        connect_btn.connect('clicked', self._on_wifi_connect)
        box.pack_start(connect_btn, False, False, 0)

        return box

    # ------------------------------------------------------------------
    # Interface list population
    # ------------------------------------------------------------------

    def _populate_interfaces(self):
        self._iface_combo.remove_all()
        _, out, _ = run_cmd(['nmcli', '-t', '-f', 'DEVICE,TYPE', 'dev'])
        saved = self.config.get('network', {}).get('interface', '')
        active_idx = 0
        idx = 0
        for line in out.splitlines():
            parts = line.split(':')
            if len(parts) >= 2 and parts[1] in ('ethernet', 'wifi') and parts[0] != 'lo':
                self._iface_combo.append_text(parts[0])
                if parts[0] == saved:
                    active_idx = idx
                idx += 1
        if idx > 0:
            self._iface_combo.set_active(active_idx)

    # ------------------------------------------------------------------
    # Signal handlers – Website
    # ------------------------------------------------------------------

    def _on_save_url(self, _btn):
        url = self._url_entry.get_text().strip()
        if not url:
            self._set_status('Please enter a URL.', error=True)
            return
        if not re.match(r'^https?://', url):
            url = 'https://' + url
            self._url_entry.set_text(url)
        self.config['url'] = url
        save_config(self.config)
        self._set_status('URL saved.')

    def _on_launch_kiosk(self, _btn):
        url = self._url_entry.get_text().strip()
        if not url:
            self._set_status('Please enter a URL first.', error=True)
            return
        if not re.match(r'^https?://', url):
            url = 'https://' + url
            self._url_entry.set_text(url)
        self.config['url'] = url
        save_config(self.config)
        self._set_status('Launching kiosk…')
        # Locate the launch script relative to this file or in /opt/kiosk
        here    = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        script  = os.path.join(here, 'kiosk-launch.sh')
        if not os.path.isfile(script):
            script = '/opt/kiosk/kiosk-launch.sh'
        subprocess.Popen(['/bin/bash', script])
        self.hide()

    def _on_restart_kiosk(self, _btn):
        self._set_status('Restarting kiosk…')
        # Kill any running Chromium instance then relaunch
        subprocess.run(['pkill', '-x', 'chromium-browser'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['pkill', '-x', 'chromium'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        here   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        script = os.path.join(here, 'kiosk-launch.sh')
        if not os.path.isfile(script):
            script = '/opt/kiosk/kiosk-launch.sh'
        subprocess.Popen(['/bin/bash', script])
        self.hide()

    def _on_reboot_device(self, _btn):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=Gtk.DialogFlags.MODAL,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text='Reboot Device?',
        )
        dialog.format_secondary_text(
            'Are you sure you want to reboot the device?')
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.YES:
            self._set_status('Rebooting…')
            subprocess.run(['sudo', 'systemctl', 'reboot'])

    # ------------------------------------------------------------------
    # Signal handlers – Network
    # ------------------------------------------------------------------

    def _on_mode_changed(self, _radio):
        self._static_frame.set_sensitive(self._static_radio.get_active())

    def _on_apply_network(self, _btn):
        iface = self._iface_combo.get_active_text()
        if not iface:
            self._set_status('Please select a network interface.', error=True)
            return

        mode = 'static' if self._static_radio.get_active() else 'dhcp'

        if mode == 'static':
            ip      = self._net_entries['ip'].get_text().strip()
            netmask = self._net_entries['netmask'].get_text().strip()
            if not ip or not netmask:
                self._set_status('IP address and subnet mask are required.', error=True)
                return

        # Save to config
        self.config.setdefault('network', {})
        self.config['network']['interface'] = iface
        self.config['network']['mode']      = mode
        for key in self._net_entries:
            self.config['network'][key] = self._net_entries[key].get_text().strip()
        save_config(self.config)

        self._set_status('Applying network settings…')
        t = threading.Thread(target=self._apply_network_thread,
                             args=(iface, mode), daemon=True)
        t.start()

    def _apply_network_thread(self, iface, mode):
        # Resolve the NetworkManager connection name for this interface
        con_name = self._find_connection(iface)

        net = self.config.get('network', {})
        try:
            if mode == 'dhcp':
                cmds = [
                    ['sudo', 'nmcli', 'con', 'mod', con_name,
                     'ipv4.method', 'auto',
                     'ipv4.addresses', '',
                     'ipv4.gateway',  '',
                     'ipv4.dns',      ''],
                    ['sudo', 'nmcli', 'con', 'up', con_name],
                ]
            else:
                cidr    = netmask_to_cidr(net.get('netmask', '24'))
                ip_cidr = f"{net['ip']}/{cidr}"
                gateway = net.get('gateway', '')
                dns     = ' '.join(
                    filter(None, [net.get('dns1', ''), net.get('dns2', '')]))

                mod_args = ['ipv4.method', 'manual',
                            'ipv4.addresses', ip_cidr]
                if gateway:
                    mod_args += ['ipv4.gateway', gateway]
                if dns:
                    mod_args += ['ipv4.dns', dns]

                cmds = [
                    ['sudo', 'nmcli', 'con', 'mod', con_name] + mod_args,
                    ['sudo', 'nmcli', 'con', 'up', con_name],
                ]

            for cmd in cmds:
                rc, _, err = run_cmd(cmd)
                if rc != 0:
                    GLib.idle_add(self._set_status,
                                  f'Error applying settings: {err}', True)
                    return

            GLib.idle_add(self._set_status, 'Network settings applied.')
        except Exception as exc:
            GLib.idle_add(self._set_status, f'Error: {exc}', True)

    def _find_connection(self, iface):
        """Return the NM connection name associated with *iface*, or iface itself."""
        for active in (True, False):
            args = ['nmcli', '-t', '-f', 'NAME,DEVICE', 'con', 'show']
            if active:
                args.append('--active')
            _, out, _ = run_cmd(args)
            for line in out.splitlines():
                parts = line.split(':')
                if len(parts) >= 2 and parts[1] == iface:
                    return parts[0]
        return iface

    # ------------------------------------------------------------------
    # Signal handlers – WiFi
    # ------------------------------------------------------------------

    def _on_wifi_scan(self, _btn):
        self._set_status('Scanning…')
        self._wifi_store.clear()
        t = threading.Thread(target=self._wifi_scan_thread, daemon=True)
        t.start()

    def _wifi_scan_thread(self):
        _, out, _ = run_cmd(
            ['nmcli', '-t', '-f', 'SSID,SIGNAL,SECURITY', 'dev', 'wifi', 'list'])
        seen   = set()
        rows   = []
        for line in out.splitlines():
            # nmcli terse mode escapes literal ':' as '\:' in field values
            parts = re.split(r'(?<!\\):', line)
            if len(parts) < 3:
                continue
            ssid     = parts[0].replace('\\:', ':')
            signal   = parts[1] + '%'
            security = parts[2] if parts[2] else 'Open'
            if ssid and ssid not in seen:
                seen.add(ssid)
                rows.append((ssid, signal, security))
        GLib.idle_add(self._update_wifi_list, rows)

    def _update_wifi_list(self, rows):
        self._wifi_store.clear()
        for row in rows:
            self._wifi_store.append(row)
        self._set_status(f'Found {len(rows)} network(s).')

    def _on_wifi_connect(self, _btn):
        model, it = self._wifi_tv.get_selection().get_selected()
        if it is None:
            self._set_status('Please select a network first.', error=True)
            return
        ssid     = model[it][0]
        password = self._wifi_pwd.get_text()
        self._set_status(f'Connecting to {ssid}…')
        t = threading.Thread(target=self._wifi_connect_thread,
                             args=(ssid, password), daemon=True)
        t.start()

    def _wifi_connect_thread(self, ssid, password):
        cmd = ['sudo', 'nmcli', 'dev', 'wifi', 'connect', ssid]
        if password:
            cmd += ['password', password]
        rc, _, err = run_cmd(cmd, timeout=60)
        if rc == 0:
            GLib.idle_add(self._set_status, f'Connected to {ssid}.')
        else:
            GLib.idle_add(self._set_status,
                          f'Failed to connect to {ssid}: {err}', True)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    app = KioskConfigApp()
    app.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
