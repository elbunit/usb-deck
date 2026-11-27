"""
USB Deck - vecorite e punes:
  * BrandStore     - paletat e ngjyrave sipas brendit (brands.json)
  * ProjectIndex   - projektet e fundit (.prproj / .aep) + backup automatik
  * create_project - struktura e dosjeve per projekt te ri
  * TimeTracker    - sa kohe ke punuar ne cdo projekt (timelog.json)
  * send_document  - dergon PDF / imazh / video nga PC te iPad-i
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Callable

IS_WINDOWS = os.name == "nt"
HEX_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")


def expand(p: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(str(p).strip())))


def safe_name(name: str, fallback: str = "pa emer") -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", str(name)).strip(" .")
    return name[:120] or fallback


# --------------------------------------------------------------------------- #
# Brand palettes
# --------------------------------------------------------------------------- #

DEFAULT_BRANDS = [
    {"id": "shembull", "name": "Shembull (fshije)", "note": "Fonti: Montserrat Bold / Inter",
     "colors": [{"hex": "#0B1F3A", "name": "Navy"}, {"hex": "#F2B705", "name": "Ari"},
                {"hex": "#F25C05", "name": "Portokalli"}, {"hex": "#FFFFFF", "name": "E bardhë"}]},
]


def normalize_brands(brands) -> list[dict]:
    if not isinstance(brands, list):
        raise ValueError("brands duhet te jete liste")
    out, seen = [], set()
    for b in brands:
        if not isinstance(b, dict):
            continue
        bid = str(b.get("id") or "").strip() or uuid.uuid4().hex[:8]
        if bid in seen:
            bid = uuid.uuid4().hex[:8]
        seen.add(bid)
        colors = []
        for c in b.get("colors") or []:
            hx = str((c or {}).get("hex", "")).strip().upper()
            if hx and not hx.startswith("#"):
                hx = "#" + hx
            if HEX_RE.match(hx):
                colors.append({"hex": hx, "name": str((c or {}).get("name") or "")[:40]})
        out.append({"id": bid, "name": str(b.get("name") or "Brend")[:60],
                    "note": str(b.get("note") or "")[:300], "colors": colors[:60]})
    return out


class BrandStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        try:
            self.brands = normalize_brands(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            self.brands = normalize_brands(DEFAULT_BRANDS)

    def save(self, brands) -> list[dict]:
        clean = normalize_brands(brands)
        with self.lock:
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(clean, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, self.path)
            self.brands = clean
        return clean


def hex_to_rgb01(hx: str) -> list[float]:
    hx = hx.lstrip("#")
    return [round(int(hx[i:i + 2], 16) / 255.0, 5) for i in (0, 2, 4)]


def copy_to_clipboard(text: str) -> bool:
    if not IS_WINDOWS:
        return False
    try:
        subprocess.run(["clip"], input=text.encode("utf-16-le"), check=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# Projects: recent list + automatic backups
# --------------------------------------------------------------------------- #

PROJECT_EXT = {".prproj": "Premiere Pro", ".aep": "After Effects"}
SKIP_DIRS = ("auto-save", "autosave", "backup", "_usbdeck", "node_modules", "$recycle.bin",
             "appdata", "cache", "media cache", "proxies", "proxy")


class ProjectIndex(threading.Thread):
    SCAN_INTERVAL = 12.0
    MAX_DEPTH = 5

    def __init__(self, get_settings: Callable[[], dict], log: Callable[[str], None],
                 on_backup: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="projects")
        self.get_settings = get_settings
        self.log = log
        self.on_backup = on_backup
        self.files: dict[str, float] = {}           # path -> mtime
        self.last_backup: dict[str, float] = {}     # path -> time of last backup
        self.pending: set[str] = set()
        self.lock = threading.Lock()
        self.first_scan_done = False
        self.wake = threading.Event()

    def roots(self) -> list[Path]:
        out = []
        for f in self.get_settings().get("project_folders", []):
            p = expand(f)
            if str(f).strip() and p.is_dir():
                out.append(p)
        return out

    def scan(self) -> dict[str, float]:
        found: dict[str, float] = {}

        def walk(d: Path, depth: int) -> None:
            try:
                with os.scandir(d) as it:
                    for e in it:
                        name = e.name.lower()
                        if e.is_dir(follow_symlinks=False):
                            if depth < self.MAX_DEPTH and not name.startswith((".", "~")) \
                                    and not any(s in name for s in SKIP_DIRS):
                                walk(Path(e.path), depth + 1)
                        elif os.path.splitext(name)[1] in PROJECT_EXT and not name.startswith("~"):
                            try:
                                found[e.path] = e.stat().st_mtime
                            except OSError:
                                pass
            except OSError:
                pass

        for r in self.roots():
            walk(r, 0)
        return found

    def run(self) -> None:
        while True:
            try:
                self.tick()
            except Exception as e:
                self.log(f"Gabim te projektet: {e}")
            self.wake.wait(self.SCAN_INTERVAL)
            self.wake.clear()

    def tick(self) -> None:
        current = self.scan()
        s = self.get_settings()
        now = time.time()
        with self.lock:
            if self.first_scan_done and s.get("backup_enabled", True):
                for path, mtime in current.items():
                    old = self.files.get(path)
                    if old is not None and mtime > old:
                        self.pending.add(path)
            min_gap = float(s.get("backup_interval_minutes", 2)) * 60
            for path in list(self.pending):
                mtime = current.get(path)
                if mtime is None:
                    self.pending.discard(path)
                    continue
                if now - mtime < 3:                     # still being written
                    continue
                if now - self.last_backup.get(path, 0) < min_gap:
                    continue
                self.pending.discard(path)
                self.backup(path, s)
            self.files = current
            self.first_scan_done = True

    def backup(self, path: str, s: dict) -> None:
        src = Path(path)
        dest_dir = expand(s.get("backup_folder") or "%USERPROFILE%\\Documents\\USB Deck Backups") / safe_name(src.stem)
        try:
            dest_dir.mkdir(parents=True, exist_ok=True)
            dest = dest_dir / f"{src.stem}_{time.strftime('%Y%m%d-%H%M%S')}{src.suffix}"
            shutil.copy2(src, dest)
            self.last_backup[path] = time.time()
            keep = max(3, int(s.get("backup_keep", 30)))
            olds = sorted(dest_dir.glob(f"{src.stem}_*{src.suffix}"))
            for old in olds[:-keep]:
                old.unlink(missing_ok=True)
            self.log(f"Backup: {src.name}")
            self.on_backup(src.name)
        except OSError as e:
            self.log(f"Backup deshtoi per {src.name}: {e}")

    def recent(self, limit: int = 30) -> list[dict]:
        with self.lock:
            items = sorted(self.files.items(), key=lambda kv: kv[1], reverse=True)[:limit]
            out = []
            for path, mtime in items:
                p = Path(path)
                lb = self.last_backup.get(path)
                out.append({
                    "path": path, "name": p.stem, "app": PROJECT_EXT.get(p.suffix.lower(), ""),
                    "ext": p.suffix.lower().lstrip("."), "folder": str(p.parent),
                    "modified": datetime.fromtimestamp(mtime).strftime("%d.%m %H:%M"),
                    "backup": datetime.fromtimestamp(lb).strftime("%H:%M") if lb else None,
                })
            return out

    def backup_dir_for(self, path: str) -> Path:
        s = self.get_settings()
        return expand(s.get("backup_folder") or "%USERPROFILE%\\Documents\\USB Deck Backups") / safe_name(Path(path).stem)


DEFAULT_TEMPLATE = ["01_Footage", "02_Audio/Muzika", "02_Audio/SFX", "02_Audio/VO", "03_Grafika",
                    "04_Projekti", "05_Eksporte", "06_Referenca"]


def create_project(s: dict, client: str, name: str) -> Path:
    root = expand(s.get("projects_root") or "%USERPROFILE%\\Desktop\\Projekte")
    title = safe_name(name, "Projekt")
    folder_name = f"{date.today().isoformat()} {safe_name(client)} - {title}" if client.strip() \
        else f"{date.today().isoformat()} {title}"
    folder = root / folder_name
    i = 2
    while folder.exists():
        folder = root / f"{folder_name} ({i})"
        i += 1
    template = s.get("project_template") or DEFAULT_TEMPLATE
    for sub in template:
        parts = [safe_name(x) for x in re.split(r"[\\/]", str(sub)) if x.strip()]
        if parts:
            folder.joinpath(*parts).mkdir(parents=True, exist_ok=True)
    folder.mkdir(parents=True, exist_ok=True)
    proj_dir = next((folder / safe_name(t) for t in template if "projekt" in t.lower() or "project" in t.lower()), folder)
    for tpl in s.get("project_template_files") or []:
        src = expand(tpl)
        if src.is_file():
            shutil.copy2(src, proj_dir / f"{title}{src.suffix}")
    return folder


def open_path(path: str | Path, select: bool = False) -> None:
    path = str(path)
    if not IS_WINDOWS:
        return
    if select:
        subprocess.Popen(f'explorer /select,"{path}"')
    else:
        os.startfile(path)  # type: ignore[attr-defined]


# --------------------------------------------------------------------------- #
# Time tracker
# --------------------------------------------------------------------------- #

TRACKED_APPS = {
    "adobe premiere pro.exe": "Premiere Pro", "afterfx.exe": "After Effects", "resolve.exe": "Resolve",
    "photoshop.exe": "Photoshop", "illustrator.exe": "Illustrator", "adobe media encoder.exe": "Media Encoder",
    "audition.exe": "Audition", "blender.exe": "Blender", "cinema 4d.exe": "Cinema 4D", "capcut.exe": "CapCut",
}


def window_title() -> str:
    if not IS_WINDOWS:
        return ""
    try:
        import ctypes
        user32 = ctypes.windll.user32
        hwnd = user32.GetForegroundWindow()
        n = user32.GetWindowTextLengthW(hwnd)
        buf = ctypes.create_unicode_buffer(n + 1)
        user32.GetWindowTextW(hwnd, buf, n + 1)
        return buf.value
    except Exception:
        return ""


def idle_seconds() -> float:
    if not IS_WINDOWS:
        return 0.0
    try:
        import ctypes

        class LASTINPUTINFO(ctypes.Structure):
            _fields_ = [("cbSize", ctypes.c_uint), ("dwTime", ctypes.c_uint)]

        info = LASTINPUTINFO()
        info.cbSize = ctypes.sizeof(LASTINPUTINFO)
        if not ctypes.windll.user32.GetLastInputInfo(ctypes.byref(info)):
            return 0.0
        return ((ctypes.windll.kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF) / 1000.0
    except Exception:
        return 0.0


def project_from_title(exe: str, title: str) -> str:
    app = TRACKED_APPS.get(exe, exe)
    m = re.search(r"([^\\/]+)\.(prproj|aep|psd|psb|ai|blend|c4d)\b", title, re.I)
    if m:
        return m.group(1).strip()
    if exe == "resolve.exe" and " - " in title:
        return title.split(" - ", 1)[1].strip() or app
    return f"({app})"


class TimeTracker(threading.Thread):
    def __init__(self, path: Path, get_settings: Callable[[], dict],
                 get_exe: Callable[[], str | None], log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="time")
        self.path = path
        self.get_settings = get_settings
        self.get_exe = get_exe
        self.log = log
        self.lock = threading.Lock()
        self.current: dict | None = None
        try:
            self.data: dict = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.data = {}

    def run(self) -> None:
        last_save = time.time()
        while True:
            time.sleep(1.0)
            s = self.get_settings()
            if not s.get("time_tracking", True):
                self.current = None
                continue
            exe = self.get_exe()
            idle_limit = float(s.get("idle_minutes", 5)) * 60
            if exe in TRACKED_APPS and idle_seconds() < idle_limit:
                project = project_from_title(exe, window_title())
                app = TRACKED_APPS[exe]
                day = date.today().isoformat()
                with self.lock:
                    bucket = self.data.setdefault(day, {}).setdefault(project, {})
                    bucket[app] = bucket.get(app, 0) + 1
                self.current = {"project": project, "app": app}
            else:
                self.current = None
            if time.time() - last_save > 30:
                self.save()
                last_save = time.time()

    def save(self) -> None:
        with self.lock:
            try:
                tmp = self.path.with_suffix(".tmp")
                tmp.write_text(json.dumps(self.data, ensure_ascii=False), encoding="utf-8")
                os.replace(tmp, self.path)
            except OSError as e:
                self.log(f"Kohematesi nuk u ruajt: {e}")

    def summary(self, rng: str) -> dict:
        today = date.today()
        if rng == "week":
            start = today - timedelta(days=today.weekday())
        elif rng == "month":
            start = today.replace(day=1)
        else:
            rng, start = "today", today
        totals: dict[str, dict] = {}
        with self.lock:
            for day, projects in self.data.items():
                try:
                    d = date.fromisoformat(day)
                except ValueError:
                    continue
                if start <= d <= today:
                    for project, apps in projects.items():
                        t = totals.setdefault(project, {"project": project, "seconds": 0, "apps": {}})
                        for app, secs in apps.items():
                            t["seconds"] += secs
                            t["apps"][app] = t["apps"].get(app, 0) + secs
        items = sorted(totals.values(), key=lambda x: x["seconds"], reverse=True)
        for it in items:
            it["apps"] = [{"app": a, "seconds": v} for a, v in sorted(it["apps"].items(), key=lambda kv: -kv[1])]
        return {"type": "time", "range": rng, "items": items,
                "total": sum(i["seconds"] for i in items), "current": self.current}

    def csv(self) -> str:
        lines = ["Data;Projekti;Programi;Minuta"]
        with self.lock:
            for day in sorted(self.data):
                for project, apps in self.data[day].items():
                    for app, secs in apps.items():
                        lines.append(f"{day};{project};{app};{round(secs / 60, 1)}")
        return "\r\n".join(lines)


# --------------------------------------------------------------------------- #
# Documents PC -> iPad
# --------------------------------------------------------------------------- #

def send_document(link, path: Path, name: str | None = None, delete_after: bool = False,
                  log: Callable[[str], None] = print) -> bool:
    if not link.connected:
        return False
    did = uuid.uuid4().hex
    name = name or path.name
    size = path.stat().st_size
    ok = link.send({"type": "doc_begin", "id": did, "name": name, "size": size})
    try:
        with open(path, "rb") as fh:
            while ok:
                chunk = fh.read(512 * 1024)
                if not chunk:
                    break
                ok = link.send({"type": "doc_chunk", "id": did, "data": base64.b64encode(chunk).decode("ascii")})
        if ok:
            ok = link.send({"type": "doc_end", "id": did})
        log(f"Dokumenti u dergua te iPad-i: {name}" if ok else f"Dergimi deshtoi: {name}")
        return ok
    finally:
        if delete_after:
            try:
                path.unlink()
            except OSError:
                pass


# --------------------------------------------------------------------------- #
# Screenshot of the PC screen
# --------------------------------------------------------------------------- #

def _copy_image_to_clipboard(img) -> bool:
    if not IS_WINDOWS:
        return False
    try:
        import ctypes
        import io
        from ctypes import wintypes

        buf = io.BytesIO()
        img.convert("RGB").save(buf, "BMP")
        data = buf.getvalue()[14:]                 # strip BITMAPFILEHEADER -> CF_DIB

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
        kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
        kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalLock.restype = wintypes.LPVOID
        kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
        user32.OpenClipboard.argtypes = [wintypes.HWND]
        user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
        user32.SetClipboardData.restype = wintypes.HANDLE

        handle = kernel32.GlobalAlloc(0x0002, len(data))   # GMEM_MOVEABLE
        if not handle:
            return False
        ptr = kernel32.GlobalLock(handle)
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(handle)
        for _ in range(10):
            if user32.OpenClipboard(None):
                break
            time.sleep(0.05)
        else:
            return False
        try:
            user32.EmptyClipboard()
            return bool(user32.SetClipboardData(8, handle))  # CF_DIB
        finally:
            user32.CloseClipboard()
    except Exception:
        return False


def _ask_save_path(default_dir: Path, default_name: str) -> str | None:
    """Shows the Windows "Save As" dialog on top of everything. Returns "" if cancelled, None if unavailable."""
    try:
        import tkinter as tk
        from tkinter import filedialog
    except Exception:
        return None
    try:
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        root.lift()
        root.focus_force()
        path = filedialog.asksaveasfilename(
            parent=root, title="Ruaj screenshot-in", initialdir=str(default_dir), initialfile=default_name,
            defaultextension=".png",
            filetypes=[("PNG (cilësi e plotë)", "*.png"), ("JPG (më i vogël)", "*.jpg *.jpeg"), ("Të gjitha", "*.*")])
        root.destroy()
        return path or ""
    except Exception:
        return None


def take_screenshot(folder: str, ask: bool = True) -> tuple[Path | None, str]:
    """Captures all monitors, copies it to the clipboard and saves it.
    ask=True opens the Windows "Save As" dialog; otherwise saves straight into `folder`.
    Returns (saved path or None, message for the iPad)."""
    try:
        from PIL import ImageGrab
    except ImportError:
        return None, "Mungon Pillow: python -m pip install pillow"
    try:
        img = ImageGrab.grab(all_screens=True)
    except Exception as e:
        return None, f"Screenshot dështoi: {e}"
    copied = _copy_image_to_clipboard(img)
    out_dir = expand(folder or "%USERPROFILE%\\Pictures\\USB Deck Screenshots")
    out_dir.mkdir(parents=True, exist_ok=True)
    name = f"Screenshot {time.strftime('%Y-%m-%d %H.%M.%S')}.png"

    path: Path | None = out_dir / name
    if ask:
        chosen = _ask_save_path(out_dir, name)
        if chosen == "":
            return None, "Screenshot nuk u ruajt" + (" (por është kopjuar – Ctrl+V)" if copied else "")
        if chosen:
            path = Path(chosen)
    try:
        if path.suffix.lower() in (".jpg", ".jpeg"):
            img.convert("RGB").save(path, "JPEG", quality=95)
        else:
            if path.suffix.lower() != ".png":
                path = path.with_suffix(".png")
            img.save(path, "PNG")
    except OSError as e:
        return None, f"Nuk u ruajt: {e}"
    return path, f"📸 U ruajt: {path.name}" + (" · edhe e kopjuar (Ctrl+V)" if copied else "")


# --------------------------------------------------------------------------- #
# Brand logos (one folder per brand)
# --------------------------------------------------------------------------- #

LOGO_EXT = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".psd", ".svg", ".ai", ".eps", ".pdf",
            ".mov", ".mp4", ".gif", ".bmp"}
THUMB_EXT = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".psd", ".gif", ".bmp"}
_thumb_cache: dict[str, tuple[float, str]] = {}


def logos_dir(settings: dict, brand_name: str) -> Path:
    root = expand(settings.get("logos_folder") or "%USERPROFILE%\\Documents\\USB Deck Logos")
    d = root / safe_name(brand_name, "Brend")
    d.mkdir(parents=True, exist_ok=True)
    return d


def _thumb(path: Path) -> str:
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return ""
    key = str(path)
    hit = _thumb_cache.get(key)
    if hit and hit[0] == mtime:
        return hit[1]
    data = ""
    try:
        import base64
        import io
        from PIL import Image
        img = Image.open(path)
        img.seek(0)
        img = img.convert("RGBA")
        img.thumbnail((220, 220))
        out = io.BytesIO()
        img.save(out, "PNG")
        data = base64.b64encode(out.getvalue()).decode("ascii")
    except Exception:
        data = ""
    _thumb_cache[key] = (mtime, data)
    return data


def list_logos(folder: Path) -> list[dict]:
    items = []
    try:
        files = sorted((p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in LOGO_EXT),
                       key=lambda p: p.name.lower())
    except OSError:
        files = []
    for p in files[:80]:
        ext = p.suffix.lower()
        items.append({"name": p.stem, "path": str(p), "ext": ext.lstrip("."),
                      "thumb": _thumb(p) if ext in THUMB_EXT else ""})
    return items
