#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
kiosk-exit-overlay.py
Displays a small, always-on-top "Exit Kiosk" button in the bottom-right
corner of the screen while the kiosk browser is running.

Tapping or clicking the button invokes kiosk-break.sh, which closes the
browser and reopens the configuration app.  This provides a break-out
method for touchscreen displays and for VirtualBox environments where
keyboard shortcuts (Ctrl+Alt+C) may be intercepted by the host.
"""

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GLib

import os
import subprocess

# Locate kiosk-break.sh relative to this file, falling back to /opt/kiosk
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BREAK_SCRIPT = os.path.join(_SCRIPT_DIR, 'kiosk-break.sh')
if not os.path.isfile(BREAK_SCRIPT):
    BREAK_SCRIPT = '/opt/kiosk/kiosk-break.sh'

_BUTTON_W = 90
_BUTTON_H = 50
_MARGIN   = 10
# Milliseconds to wait after the 'map' signal before calling move(), giving the
# window manager time to complete its initial window placement.
_WM_SETTLE_MS = 100


class ExitOverlay(Gtk.Window):

    def __init__(self):
        super().__init__()

        # Floating notification-style window: no taskbar entry
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        # Do not steal keyboard focus from the kiosk browser
        self.set_accept_focus(False)
        self.set_focus_on_map(False)

        btn = Gtk.Button(label='⚙ Exit')
        btn.set_size_request(_BUTTON_W, _BUTTON_H)
        btn.set_tooltip_text('Exit kiosk mode')
        btn.connect('clicked', self._on_exit)
        self.add(btn)

        # set_keep_above is applied after mapping so the WM sees it on the
        # already-visible window rather than as a pre-map hint it may ignore.
        self.connect('map', self._on_map)

    def _on_map(self, _widget):
        """Apply keep-above and schedule positioning after the WM has mapped us."""
        self.set_keep_above(True)
        GLib.timeout_add(_WM_SETTLE_MS, self._position_window)

    def _position_window(self):
        """Position the button in the bottom-right corner."""
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        geo = monitor.get_geometry()
        scale = monitor.get_scale_factor()
        sw = geo.width * scale
        sh = geo.height * scale
        self.move(sw - _BUTTON_W - _MARGIN, sh - _BUTTON_H - _MARGIN)
        return False  # one-shot

    def _keep_on_top(self):
        """Periodically raise the overlay above Chromium's kiosk window."""
        if self.get_visible():
            self.set_keep_above(True)
            gdk_win = self.get_window()
            if gdk_win:
                gdk_win.raise_()
        return True  # repeat

    def _on_exit(self, _btn):
        self.hide()
        subprocess.Popen(['/bin/bash', BREAK_SCRIPT])
        Gtk.main_quit()


def main():
    overlay = ExitOverlay()
    overlay.show_all()
    # Re-raise every 1000 ms so the button stays above Chromium's kiosk window
    GLib.timeout_add(1000, overlay._keep_on_top)
    Gtk.main()


if __name__ == '__main__':
    main()
