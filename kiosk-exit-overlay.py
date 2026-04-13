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
_SPACING  = 4
# Milliseconds to wait after the 'map' signal before calling move(), giving the
# window manager time to complete its initial window placement.
_WM_SETTLE_MS = 100
# Milliseconds between polls while waiting for Chromium's window to appear.
_CHROMIUM_POLL_MS = 500
# Maximum number of polls before showing the overlay unconditionally (so the
# button always appears even when xdotool cannot detect the window class).
# 60 polls × 500 ms = 30 seconds.
_CHROMIUM_POLL_MAX = 60


class ExitOverlay(Gtk.Window):

    def __init__(self, chromium_pid=None):
        super().__init__()
        self._chromium_pid = chromium_pid
        self._poll_count = 0

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

        btn_shutdown = Gtk.Button(label='⏻ Shutdown')
        btn_shutdown.set_size_request(_BUTTON_W, _BUTTON_H)
        btn_shutdown.set_tooltip_text('Shut down the system')
        btn_shutdown.connect('clicked', self._on_shutdown)

        btn = Gtk.Button(label='⚙ Exit')
        btn.set_size_request(_BUTTON_W, _BUTTON_H)
        btn.set_tooltip_text('Exit kiosk mode')
        btn.connect('clicked', self._on_exit)

        btn_kbd = Gtk.Button(label='⌨ Keyboard')
        btn_kbd.set_size_request(_BUTTON_W, _BUTTON_H)
        btn_kbd.set_tooltip_text(
            'Use the GNOME built-in Screen Keyboard:\n'
            'swipe up from the bottom of the screen,\n'
            'or enable via Settings → Accessibility → Typing → Screen Keyboard'
        )
        btn_kbd.connect('clicked', self._on_keyboard)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=_SPACING)
        vbox.pack_start(btn_shutdown, False, False, 0)
        vbox.pack_start(btn, False, False, 0)
        vbox.pack_start(btn_kbd, False, False, 0)
        self.add(vbox)

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
        if display is None:
            return False
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return False
        geo = monitor.get_geometry()
        scale = monitor.get_scale_factor()
        # geo.x/geo.y give the monitor's origin in global screen coordinates;
        # include them so positioning is correct on multi-monitor setups and on
        # X11 configurations where the primary monitor is not at (0, 0).
        sx = geo.x + geo.width * scale
        sy = geo.y + geo.height * scale
        # Use the actual allocated window size rather than a hardcoded estimate
        # so the window is flush with the bottom-right corner regardless of
        # widget padding or font scaling.
        win_w, win_h = self.get_size()
        self.move(sx - win_w - _MARGIN, sy - win_h - _MARGIN)
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
        except ProcessLookupError:
            return None  # process gone
        except PermissionError:
            pass  # process exists but owned by another user; continue
        # Use xdotool to confirm the window is mapped.
        # Chromium's UI window belongs to a child renderer process, not the
        # launcher PID, so --pid never matches the kiosk window.  We search
        # by window class name instead.  The preceding os.kill(pid, 0) check
        # ensures our Chromium launcher is alive; on a dedicated kiosk there
        # is only ever one Chromium instance, so class-name matching is safe.
        # We try both --classname (WM_CLASS instance, e.g. "chromium") and
        # --class (WM_CLASS class, e.g. "Chromium") to cover all package
        # variants (apt, snap, etc.).
        # --onlyvisible is tried first; if it returns nothing (Chromium's
        # --kiosk fullscreen window is mapped but not reported as IsViewable
        # on some compositors), we retry without it so any mapped window counts.
        try:
            class_args = [
                ('--classname', 'chromium'),
                ('--classname', 'chromium-browser'),
                ('--class',     'Chromium'),
                ('--class',     'Chromium-browser'),
            ]
            for visible_flag in (['--onlyvisible'], []):
                for flag, name in class_args:
                    result = subprocess.run(
                        ['xdotool', 'search'] + visible_flag + [flag, name],
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
        window is on screen; quits if the process has already gone.  After
        _CHROMIUM_POLL_MAX polls the overlay is shown unconditionally so it
        always appears even when xdotool cannot detect the window class.
        """
        self._poll_count += 1
        status = self._chromium_window_visible()
        if status is None:
            # Chromium exited before we showed — nothing to do
            Gtk.main_quit()
            return False
        if status or self._poll_count >= _CHROMIUM_POLL_MAX:
            if not status:
                print(
                    "kiosk-exit-overlay: xdotool did not detect Chromium window "
                    "after 30 s; showing overlay unconditionally.",
                    file=sys.stderr,
                )
            self.show_all()
            GLib.timeout_add(1000, self._keep_on_top)
            return False  # stop polling
        return True  # keep polling

    def _on_shutdown(self, _btn):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.QUESTION,
            buttons=Gtk.ButtonsType.YES_NO,
            text='Shut down the system?',
        )
        dialog.format_secondary_text('The kiosk will power off. Are you sure?')
        response = dialog.run()
        dialog.destroy()
        if response != Gtk.ResponseType.YES:
            return
        self.hide()
        if self._chromium_pid is not None:
            try:
                os.kill(self._chromium_pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
        subprocess.Popen(['sudo', 'systemctl', 'poweroff'])
        Gtk.main_quit()

    def _on_keyboard(self, _btn):
        """Show a reminder about the GNOME built-in Screen Keyboard.

        The GNOME Screen Keyboard is the recommended on-screen keyboard on
        Ubuntu 24.04 GNOME Shell under Wayland.  Enable it via:
          Settings → Accessibility → Typing → Screen Keyboard
        Then swipe up from the bottom of the screen to show it.

        Onboard is no longer launched by this button.
        """
        dialog = Gtk.MessageDialog(
            transient_for=self,
            flags=0,
            message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.OK,
            text='GNOME Screen Keyboard',
        )
        dialog.format_secondary_text(
            'Swipe up from the bottom of the screen to show the keyboard.\n\n'
            'If it does not appear, enable it first:\n'
            'Settings → Accessibility → Typing → Screen Keyboard → On'
        )
        dialog.run()
        dialog.destroy()

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
