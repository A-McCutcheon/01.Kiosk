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
from gi.repository import Gtk, Gdk

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


class ExitOverlay(Gtk.Window):

    def __init__(self):
        super().__init__()

        # Floating notification-style window: always on top, no taskbar entry
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.set_keep_above(True)
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

        self.connect('realize', self._on_realize)

    def _on_realize(self, _widget):
        """Position the button in the bottom-right corner after realization."""
        screen = Gdk.Screen.get_default()
        sw = screen.get_width()
        sh = screen.get_height()
        self.move(sw - _BUTTON_W - _MARGIN, sh - _BUTTON_H - _MARGIN)

    def _on_exit(self, _btn):
        self.hide()
        subprocess.Popen(['/bin/bash', BREAK_SCRIPT])
        Gtk.main_quit()


def main():
    overlay = ExitOverlay()
    overlay.show_all()
    Gtk.main()


if __name__ == '__main__':
    main()
