"""
USB Deck - iPad-i si monitor i dyte (transmetim i ekranit neper kabllo USB).

* Kap nje monitor (ose nje dritare) me `mss`, e ngjesh ne JPEG dhe e dergon
  si mesazh binar. Kuadri tjeter dergohet vetem pasi iPad-i konfirmon (ack),
  keshtu nuk krijohet vonese edhe kur kablloja eshte e ngadalte.
* Prekja ne iPad -> klikim / terheqje me mausin ne PC.
* Me nje "monitor virtual" (driver falas) iPad-i behet monitor i vertete shtese.
"""

from __future__ import annotations

import hashlib
import io
import os
import threading
import time
from typing import Callable

IS_WINDOWS = os.name == "nt"
FRAME_KIND_JPEG = 1


def _user32():
    import ctypes
    return ctypes.windll.user32


def foreground_window_rect() -> tuple[int, int, int, int, int] | None:
    """(hwnd, left, top, width, height) of the active window."""
    if not IS_WINDOWS:
        return None
    import ctypes
    from ctypes import wintypes
    u = _user32()
    hwnd = u.GetForegroundWindow()
    r = wintypes.RECT()
    if not hwnd or not u.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    return hwnd, r.left, r.top, r.right - r.left, r.bottom - r.top


def window_rect(hwnd: int) -> tuple[int, int, int, int] | None:
    if not IS_WINDOWS:
        return None
    import ctypes
    from ctypes import wintypes
    u = _user32()
    if not u.IsWindow(hwnd):
        return None
    r = wintypes.RECT()
    if not u.GetWindowRect(hwnd, ctypes.byref(r)):
        return None
    return r.left, r.top, r.right - r.left, r.bottom - r.top


def cursor_pos() -> tuple[int, int] | None:
    if not IS_WINDOWS:
        return None
    import ctypes
    from ctypes import wintypes
    p = wintypes.POINT()
    _user32().GetCursorPos(ctypes.byref(p))
    return p.x, p.y


class ScreenStreamer(threading.Thread):
    def __init__(self, link, get_settings: Callable[[], dict], log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="screen")
        self.link = link
        self.get_settings = get_settings
        self.log = log
        self.active = threading.Event()
        self.acked = threading.Event()
        self.lock = threading.Lock()
        self.source = "m1"
        self.window: tuple[int, str] | None = None      # (hwnd, title) for the "window" source
        self.region = (0, 0, 1920, 1080)                 # last captured region (for touch mapping)
        self.monitors: list[dict] = []
        self.dragging = False
        self.force = True

    # ------------------------------------------------------------------ control
    def sources(self) -> list[dict]:
        out = [{"id": f"m{i + 1}", "name": f"Monitori {i + 1}", "detail": f"{m['width']}×{m['height']}"}
               for i, m in enumerate(self.monitors)]
        if IS_WINDOWS:
            out.append({"id": "window", "name": "Dritarja aktive",
                        "detail": (self.window[1][:40] if self.window else "ngrin dritaren që ke përpara")})
        if not out:
            out.append({"id": "m1", "name": "Ekran test", "detail": "simulim"})
        return out

    def start_stream(self, source: str) -> None:
        with self.lock:
            if source == "window":
                fg = foreground_window_rect()
                if fg:
                    title = self._title(fg[0])
                    self.window = (fg[0], title or "Dritarja")
            self.source = source or "m1"
            self.force = True
        self.acked.set()
        self.active.set()

    def stop_stream(self) -> None:
        self.active.clear()
        self._release_mouse()

    def ack(self) -> None:
        self.acked.set()

    @staticmethod
    def _title(hwnd: int) -> str:
        try:
            import ctypes
            u = _user32()
            n = u.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(n + 1)
            u.GetWindowTextW(hwnd, buf, n + 1)
            return buf.value
        except Exception:
            return ""

    # ------------------------------------------------------------------ touch -> mouse
    def touch(self, x: float, y: float, action: str) -> None:
        if not IS_WINDOWS or not self.get_settings().get("screen_touch", True):
            return
        left, top, w, h = self.region
        px = int(left + max(0.0, min(1.0, x)) * (w - 1))
        py = int(top + max(0.0, min(1.0, y)) * (h - 1))
        u = _user32()
        u.SetCursorPos(px, py)
        if action == "down":
            u.mouse_event(0x0002, 0, 0, 0, 0)    # LEFTDOWN
            self.dragging = True
        elif action == "up":
            u.mouse_event(0x0004, 0, 0, 0, 0)    # LEFTUP
            self.dragging = False
        elif action == "right":
            u.mouse_event(0x0008, 0, 0, 0, 0)
            u.mouse_event(0x0010, 0, 0, 0, 0)
        elif action == "scroll":
            pass

    def scroll(self, x: float, y: float, dy: float) -> None:
        if not IS_WINDOWS or not self.get_settings().get("screen_touch", True):
            return
        self.touch(x, y, "move")
        _user32().mouse_event(0x0800, 0, 0, int(-dy * 120), 0)   # WHEEL

    def _release_mouse(self) -> None:
        if self.dragging and IS_WINDOWS:
            _user32().mouse_event(0x0004, 0, 0, 0, 0)
        self.dragging = False

    # ------------------------------------------------------------------ capture loop
    def run(self) -> None:
        try:
            from PIL import Image
        except ImportError:
            self.log("Monitori: mungon Pillow (python -m pip install pillow)")
            return
        sct = None
        try:
            import mss
            sct = mss.mss()
            self.monitors = [dict(m) for m in sct.monitors[1:]]
        except Exception as e:
            if IS_WINDOWS:
                self.log(f"Monitori: mungon 'mss' ({e}). Instalo: python -m pip install mss")
            self.monitors = []

        last_hash = b""
        frame_no = 0
        while True:
            self.active.wait()
            s = self.get_settings()
            fps = max(5, min(int(s.get("screen_fps", 20)), 30))
            max_w = max(800, min(int(s.get("screen_max_width", 1600)), 2732))
            quality = max(40, min(int(s.get("screen_quality", 70)), 95))
            t0 = time.time()
            if not self.acked.wait(1.0):          # iPad still busy / lost one ack
                self.acked.set()
                continue
            try:
                img, region, cursor = self._grab(sct, Image, frame_no)
            except Exception as e:
                self.log(f"Monitori: kapja dështoi ({e})")
                time.sleep(1)
                continue
            frame_no += 1
            self.region = region
            if img.width > max_w:
                img = img.resize((max_w, round(img.height * max_w / img.width)), Image.BILINEAR)
            digest = hashlib.md5(img.tobytes()[::97]).digest()
            changed = digest != last_hash or self.force
            if changed:
                self.force = False
                last_hash = digest
                buf = io.BytesIO()
                img.save(buf, "JPEG", quality=quality, optimize=False)
                cx = cy = None
                if cursor:
                    cx = (cursor[0] - region[0]) / max(region[2], 1)
                    cy = (cursor[1] - region[1]) / max(region[3], 1)
                self.acked.clear()
                self.link.send({"type": "screen_meta", "w": img.width, "h": img.height,
                                "cx": cx, "cy": cy, "source": self.source})
                if not self.link.send_binary(FRAME_KIND_JPEG, buf.getvalue()):
                    self.active.clear()
            elif cursor:
                # Picture unchanged - just move the cursor dot.
                self.link.send({"type": "screen_cursor",
                                "cx": (cursor[0] - region[0]) / max(region[2], 1),
                                "cy": (cursor[1] - region[1]) / max(region[3], 1)})
            spent = time.time() - t0
            time.sleep(max(0.0, 1.0 / fps - spent))

    def _grab(self, sct, Image, frame_no: int):
        with self.lock:
            source, window = self.source, self.window
        if sct is None:
            return self._test_pattern(Image, frame_no), (0, 0, 1600, 1000), None
        region = None
        if source == "window" and window:
            r = window_rect(window[0])
            if r and r[2] > 20 and r[3] > 20:
                region = r
        if region is None:
            idx = int(source[1:]) - 1 if source.startswith("m") and source[1:].isdigit() else 0
            mons = sct.monitors[1:] or sct.monitors
            m = mons[min(max(idx, 0), len(mons) - 1)]
            region = (m["left"], m["top"], m["width"], m["height"])
        shot = sct.grab({"left": region[0], "top": region[1], "width": region[2], "height": region[3]})
        img = Image.frombytes("RGB", shot.size, shot.rgb)
        return img, region, cursor_pos()

    @staticmethod
    def _test_pattern(Image, n: int):
        from PIL import ImageDraw
        img = Image.new("RGB", (1600, 1000), (20, 22, 28))
        d = ImageDraw.Draw(img)
        x = (n * 23) % 1500
        d.rectangle([x, 400, x + 100, 500], fill=(82, 140, 255))
        d.text((40, 40), f"USB Deck - test {n}", fill=(255, 255, 255))
        return img
