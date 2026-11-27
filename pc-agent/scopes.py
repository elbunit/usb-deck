"""
USB Deck - Scopes profesionale (Waveform, RGB Parade, Vectorscope, Histogram).

Kap nje zone te ekranit (p.sh. Program Monitor-in), llogarit scopes me numpy
dhe i dergon si imazhe te vogla JPEG te iPad-i (vijat e matjes vizatohen ne iPad).
"""

from __future__ import annotations

import io
import os
import threading
import time
from typing import Callable

IS_WINDOWS = os.name == "nt"
KIND_WAVEFORM, KIND_PARADE, KIND_VECTOR = 2, 3, 4


def select_region() -> tuple[int, int, int, int] | None:
    """Full-screen translucent overlay; drag a rectangle with the mouse. Esc cancels."""
    try:
        import tkinter as tk
    except Exception:
        return None
    x0 = y0 = 0
    vw, vh = 1920, 1080
    if IS_WINDOWS:
        import ctypes
        m = ctypes.windll.user32.GetSystemMetrics
        x0, y0, vw, vh = m(76), m(77), m(78), m(79)     # virtual screen (all monitors)
    result: dict = {}
    root = tk.Tk()
    root.overrideredirect(True)
    root.geometry(f"{vw}x{vh}+{x0}+{y0}")
    root.attributes("-topmost", True)
    root.attributes("-alpha", 0.35)
    root.configure(bg="black")
    cv = tk.Canvas(root, bg="black", highlightthickness=0, cursor="crosshair")
    cv.pack(fill="both", expand=True)
    cv.create_text(vw // 2 - x0 if x0 < 0 else vw // 2, 60, fill="white", font=("Segoe UI", 20, "bold"),
                   text="Tërhiq mausin mbi Program Monitor (vetëm figura, pa kornizë) – Esc për të anuluar")
    rect = {"id": None, "sx": 0, "sy": 0}

    def down(e):
        rect["sx"], rect["sy"] = e.x, e.y
        if rect["id"]:
            cv.delete(rect["id"])
        rect["id"] = cv.create_rectangle(e.x, e.y, e.x, e.y, outline="#52a0ff", width=3)

    def move(e):
        if rect["id"]:
            cv.coords(rect["id"], rect["sx"], rect["sy"], e.x, e.y)

    def up(e):
        x1, y1 = min(rect["sx"], e.x), min(rect["sy"], e.y)
        x2, y2 = max(rect["sx"], e.x), max(rect["sy"], e.y)
        if x2 - x1 > 40 and y2 - y1 > 30:
            result["r"] = (x0 + x1, y0 + y1, x2 - x1, y2 - y1)
        root.destroy()

    cv.bind("<ButtonPress-1>", down)
    cv.bind("<B1-Motion>", move)
    cv.bind("<ButtonRelease-1>", up)
    root.bind("<Escape>", lambda e: root.destroy())
    root.focus_force()
    root.mainloop()
    return result.get("r")


def compute(arr, np):
    """arr: HxWx3 uint8 -> (waveform img, parade img, vectorscope img, histograms dict)."""
    rgb = arr.astype(np.float32)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    h, w = r.shape
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b

    def wave(channel, width):
        xs = (np.arange(channel.shape[1]) * width // channel.shape[1]).astype(np.int64)
        xi = np.broadcast_to(xs, channel.shape)
        vi = np.clip(channel, 0, 255).astype(np.int64)
        counts = np.bincount((255 - vi).ravel() * width + xi.ravel(), minlength=256 * width).reshape(256, width)
        return np.log1p(counts) / max(np.log1p(counts.max()), 1e-6)

    # Luma waveform (green phosphor look)
    wy = wave(y, 360)
    img_w = np.zeros((256, 360, 3), np.float32)
    img_w[..., 0] = wy * 120
    img_w[..., 1] = wy * 255
    img_w[..., 2] = wy * 140

    # RGB parade
    pr, pg, pb = wave(r, 160), wave(g, 160), wave(b, 160)
    img_p = np.zeros((256, 480, 3), np.float32)
    img_p[:, 0:160, 0] = pr * 255
    img_p[:, 0:160, 1] = pr * 60
    img_p[:, 0:160, 2] = pr * 60
    img_p[:, 160:320, 0] = pg * 60
    img_p[:, 160:320, 1] = pg * 255
    img_p[:, 160:320, 2] = pg * 80
    img_p[:, 320:480, 0] = pb * 80
    img_p[:, 320:480, 1] = pb * 110
    img_p[:, 320:480, 2] = pb * 255

    # Vectorscope (Rec.709 Cb/Cr), each point drawn in its own hue
    cb = (-0.1146 * r - 0.3854 * g + 0.5 * b)
    cr = (0.5 * r - 0.4542 * g - 0.0458 * b)
    xi = np.clip(cb + 128, 0, 255).astype(np.int64)
    yi = np.clip(128 - cr, 0, 255).astype(np.int64)
    idx = (yi * 256 + xi).ravel()
    counts = np.bincount(idx, minlength=256 * 256).reshape(256, 256)
    inten = np.log1p(counts) / max(np.log1p(counts.max()), 1e-6)
    sr = np.bincount(idx, weights=r.ravel(), minlength=65536).reshape(256, 256)
    sg = np.bincount(idx, weights=g.ravel(), minlength=65536).reshape(256, 256)
    sb = np.bincount(idx, weights=b.ravel(), minlength=65536).reshape(256, 256)
    n = np.maximum(counts, 1)
    col = np.stack([sr / n, sg / n, sb / n], axis=-1)
    col = col / np.maximum(col.max(axis=-1, keepdims=True), 1) * 255
    col = 0.55 * col + 0.45 * 255
    img_v = col * inten[..., None]

    # Histograms (256 bins, 0..1)
    def hist(c):
        hh = np.bincount(np.clip(c, 0, 255).astype(np.int64).ravel(), minlength=256)[:256].astype(np.float64)
        return hh
    hr, hg, hb, hy = hist(r), hist(g), hist(b), hist(y)
    mx = max(hr.max(), hg.max(), hb.max(), hy.max(), 1)
    hists = {k: [round(float(v) / mx, 3) for v in arr_][::2] for k, arr_ in
             (("r", hr), ("g", hg), ("b", hb), ("y", hy))}
    return img_w, img_p, img_v, hists


class ScopesService(threading.Thread):
    def __init__(self, link, get_settings: Callable[[], dict], save_region: Callable[[list], None],
                 log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="scopes")
        self.link = link
        self.get_settings = get_settings
        self.save_region = save_region
        self.log = log
        self.active = threading.Event()
        self.acked = threading.Event()
        self.acked.set()
        self.source = "region"
        self.monitors: list[dict] = []

    def start_stream(self, source: str) -> None:
        self.source = source or "region"
        self.acked.set()
        self.active.set()

    def stop_stream(self) -> None:
        self.active.clear()

    def ack(self) -> None:
        self.acked.set()

    def sources(self) -> list[dict]:
        reg = self.get_settings().get("scopes_region")
        out = [{"id": "region", "name": "Zona e zgjedhur",
                "detail": f"{reg[2]}×{reg[3]}" if reg else "zgjidhe me “Zgjidh zonën”"}]
        out += [{"id": f"m{i + 1}", "name": f"Monitori {i + 1}", "detail": f"{m['width']}×{m['height']}"}
                for i, m in enumerate(self.monitors)]
        return out

    def pick_region(self) -> None:
        was = self.active.is_set()
        self.active.clear()
        time.sleep(0.2)
        r = select_region()
        if r:
            self.save_region(list(r))
            self.source = "region"
            self.link.send({"type": "toast", "text": f"Zona u ruajt: {r[2]}×{r[3]}"})
        elif r is None:
            self.link.send({"type": "toast", "text": "Zgjedhja e zonës s'u hap (mungon tcl/tk në Python)"})
        self.link.send({"type": "scopes_sources", "items": self.sources(), "current": self.source})
        if was:
            self.active.set()

    def run(self) -> None:
        try:
            import numpy as np
            from PIL import Image
        except ImportError:
            self.log("Scopes: mungon numpy/Pillow (python -m pip install numpy pillow)")
            return
        sct = None
        try:
            import mss
            sct = mss.mss()
            self.monitors = [dict(m) for m in sct.monitors[1:]]
        except Exception:
            self.monitors = []
        n = 0
        while True:
            self.active.wait()
            fps = max(2, min(int(self.get_settings().get("scopes_fps", 10)), 20))
            t0 = time.time()
            if not self.acked.wait(1.0):
                self.acked.set()
                continue
            try:
                img = self._grab(sct, Image, np, n)
                n += 1
                img.thumbnail((640, 640))
                arr = np.asarray(img.convert("RGB"))
                w_img, p_img, v_img, hists = compute(arr, np)
            except Exception as e:
                self.log(f"Scopes: {e}")
                time.sleep(1)
                continue
            self.acked.clear()
            self.link.send({"type": "scopes_hist", **hists})
            for kind, a in ((KIND_WAVEFORM, w_img), (KIND_PARADE, p_img), (KIND_VECTOR, v_img)):
                buf = io.BytesIO()
                Image.fromarray(np.clip(a, 0, 255).astype(np.uint8)).save(buf, "JPEG", quality=82)
                if not self.link.send_binary(kind, buf.getvalue()):
                    self.active.clear()
                    break
            time.sleep(max(0.0, 1.0 / fps - (time.time() - t0)))

    def _grab(self, sct, Image, np, n):
        if sct is None:                       # test pattern (no screen available)
            x = np.linspace(0, 1, 640)[None, :, None]
            yv = np.linspace(0, 1, 360)[:, None, None]
            arr = np.concatenate([x * 255 * np.ones_like(yv), yv * 255 * np.ones_like(x),
                                  (0.5 + 0.5 * np.sin(n / 5)) * 255 * np.ones((360, 640, 1))], axis=2)
            return Image.fromarray(arr.astype(np.uint8))
        reg = self.get_settings().get("scopes_region")
        if self.source == "region" and reg:
            box = {"left": int(reg[0]), "top": int(reg[1]), "width": int(reg[2]), "height": int(reg[3])}
        else:
            idx = int(self.source[1:]) - 1 if self.source.startswith("m") and self.source[1:].isdigit() else 0
            mons = sct.monitors[1:] or sct.monitors
            m = mons[min(max(idx, 0), len(mons) - 1)]
            box = {"left": m["left"], "top": m["top"], "width": m["width"], "height": m["height"]}
        shot = sct.grab(box)
        return Image.frombytes("RGB", shot.size, shot.rgb)
