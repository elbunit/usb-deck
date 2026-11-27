"""System-tray icon (next to the clock) for running the agent without a console window."""
from __future__ import annotations

import os
import threading
import webbrowser
from typing import Callable


def _icon_image(connected: bool, update: bool):
    from PIL import Image, ImageDraw
    s = 64
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    # rounded square with a blue -> violet diagonal gradient
    grad = Image.new("RGBA", (s, s))
    gd = ImageDraw.Draw(grad)
    for i in range(2 * s):
        t = i / (2 * s - 1)
        col = (int(82 + (138 - 82) * t), int(137 + (91 - 137) * t), 255, 255)
        gd.line([(i, 0), (0, i)], fill=col, width=2)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((2, 2, s - 3, s - 3), radius=14, fill=255)
    img.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(img)
    # 2x2 "deck" keys
    for x, y in ((16, 16), (35, 16), (16, 35), (35, 35)):
        d.rounded_rectangle((x, y, x + 13, y + 13), radius=3, fill=(255, 255, 255, 235))
    # status dot
    col = (51, 204, 115, 255) if connected else (242, 84, 84, 255)
    d.ellipse((s - 24, s - 24, s - 2, s - 2), fill=col, outline=(20, 20, 20, 255), width=3)
    if update:
        d.ellipse((s - 22, 0, s - 2, 20), fill=(232, 163, 23, 255), outline=(20, 20, 20, 255), width=3)
    return img


class Tray:
    def __init__(self, *, version: str, editor_url: str, log_path: str,
                 is_connected: Callable[[], bool], device: Callable[[], str],
                 update_available: Callable[[], bool], on_update: Callable[[], None],
                 on_restart: Callable[[], None], on_quit: Callable[[], None]) -> None:
        import pystray  # noqa: F401  (raises ImportError if missing)
        self.version = version
        self.editor_url = editor_url
        self.log_path = log_path
        self.is_connected = is_connected
        self.device = device
        self.update_available = update_available
        self.on_update = on_update
        self.on_restart = on_restart
        self.on_quit = on_quit
        self.icon = None
        self._state = None

    def _title(self) -> str:
        c = self.is_connected()
        t = f"USB Deck v{self.version} – " + (f"iPad i lidhur ({self.device()})" if c else "iPad jo i lidhur")
        if self.update_available():
            t += " – ka përditësim"
        return t[:120]

    def run(self) -> None:
        """Blocks (call from the main thread)."""
        import pystray
        from pystray import Menu, MenuItem as Item

        def status_text(_):
            return ("🟢 iPad i lidhur" if self.is_connected() else "🔴 iPad jo i lidhur")

        menu = Menu(
            Item(status_text, None, enabled=False),
            Item("Hap editorin e butonave", lambda *_: webbrowser.open(self.editor_url), default=True),
            Item(lambda _: "⬆ Instalo përditësimin" if self.update_available() else "Kontrollo përditësimet",
                 lambda *_: threading.Thread(target=self.on_update, daemon=True).start()),
            Item("Shfaq log-un", lambda *_: os.startfile(self.log_path) if os.path.exists(self.log_path) else None),
            Menu.SEPARATOR,
            Item("Rinis agjentin", lambda *_: self.on_restart()),
            Item("Mbyll USB Deck", lambda *_: self._quit()),
        )
        self.icon = pystray.Icon("USBDeck", _icon_image(False, False), self._title(), menu)
        threading.Thread(target=self._refresh_loop, daemon=True, name="tray-refresh").start()
        self.icon.run()

    def notify(self, text: str) -> None:
        try:
            if self.icon is not None:
                self.icon.notify(text, "USB Deck")
        except Exception:
            pass

    def _refresh_loop(self) -> None:
        import time
        while True:
            time.sleep(2)
            try:
                st = (self.is_connected(), self.update_available())
                if st != self._state and self.icon is not None:
                    self._state = st
                    self.icon.icon = _icon_image(*st)
                    self.icon.title = self._title()
                    self.icon.update_menu()
            except Exception:
                pass

    def _quit(self) -> None:
        try:
            if self.icon is not None:
                self.icon.stop()
        finally:
            self.on_quit()
