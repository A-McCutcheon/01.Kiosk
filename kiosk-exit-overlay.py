#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
kiosk-exit-overlay.py
Displays a small, always-on-top "Exit Kiosk" button in the bottom-right
corner of the screen while the kiosk browser is running.

Usage: kiosk-exit-overlay.py [CHROMIUM_PID]

When CHROMIUM_PID is supplied the overlay stays hidden until Chromium's
window is detected on screen (via xdotool), ensuring the button always
appears on top of the kiosk window.  The button also kills that exact PID
on click, avoiding any risk of killing the wrong process.

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
import signal
import subprocess
import sys

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
# Milliseconds between polls while waiting for Chromium's window to appear.
_CHROMIUM_POLL_MS = 500


class ExitOverlay(Gtk.Window):

    def __init__(self, chromium_pid=None):
        super().__init__()
        self._chromium_pid = chromium_pid

        # DOCK-type windows sit in the "dock" stacking layer which the X11/EWMH
        # spec places above fullscreen windows.  This ensures the button remains
        # visible on top of Chromium's --kiosk fullscreen window.
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
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

    def _chromium_window_visible(self):
        """
        Return True if Chromium's window is on screen,
               False if not yet visible,
               None if the process has already exited.
        """
        if self._chromium_pid is None:
            return True
        # Verify the process is still alive
        try:
            os.kill(self._chromium_pid, 0)
        except (ProcessLookupError, PermissionError):
            return None  # process gone
        # Use xdotool to confirm the window is mapped and visible.
        # Chromium's UI window belongs to a child renderer process, not the
        # launcher PID, so --pid never matches the kiosk window.  We search
        # by window class name instead.  The preceding os.kill(pid, 0) check
        # ensures our Chromium launcher is alive; on a dedicated kiosk there
        # is only ever one Chromium instance, so class-name matching is safe.
        try:
            for classname in ('chromium', 'chromium-browser'):
                result = subprocess.run(
                    ['xdotool', 'search', '--onlyvisible', '--classname', classname],
                    capture_output=True, timeout=2,
                )
                if result.returncode == 0 and result.stdout.strip():
                    return True
            return False
        except (FileNotFoundError, subprocess.TimeoutExpired):
            # xdotool not available; treat alive process as ready
            return True

    def _poll_for_chromium(self):
        """
        Called every _CHROMIUM_POLL_MS ms.  Shows the overlay once Chromium's
        window is on screen; quits if the process has already gone.
        """
        status = self._chromium_window_visible()
        if status is None:
            # Chromium exited before we showed — nothing to do
            Gtk.main_quit()
            return False
        if status:
            self.show_all()
            GLib.timeout_add(1000, self._keep_on_top)
            return False  # stop polling
        return True  # keep polling

    def _on_exit(self, _btn):
        self.hide()
        # Kill the tracked Chromium process directly by PID
        if self._chromium_pid is not None:
            try:
                os.kill(self._chromium_pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        subprocess.Popen(['/bin/bash', BREAK_SCRIPT])
        Gtk.main_quit()


def main():
    chromium_pid = None
    if len(sys.argv) > 1:
        try:
            chromium_pid = int(sys.argv[1])
        except ValueError:
            pass

    overlay = ExitOverlay(chromium_pid=chromium_pid)
    if chromium_pid is not None:
        # Stay hidden until Chromium's window is on screen
        GLib.timeout_add(_CHROMIUM_POLL_MS, overlay._poll_for_chromium)
    else:
        overlay.show_all()
        GLib.timeout_add(1000, overlay._keep_on_top)
    Gtk.main()


if __name__ == '__main__':
    main()
