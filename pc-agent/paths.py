"""Folder-path shortcuts ("Rrugët"): saved paths that the iPad pastes into the field
you're in (Save As dialogs, export location, Media Browser...). Stored in paths.json."""
from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import uuid
from pathlib import Path

IS_WINDOWS = os.name == "nt"
MAX_PATHS = 200


def _expand(p: str) -> str:
    return os.path.expandvars(os.path.expanduser(p.strip().strip('"')))


def _default_name(path: str) -> str:
    p = Path(_expand(path))
    return p.name or str(p)


class PathStore:
    def __init__(self, file: Path) -> None:
        self.file = file
        self.lock = threading.Lock()
        self.items: list[dict] = []
        try:
            self.items = self.normalize(json.loads(file.read_text(encoding="utf-8")))
        except (OSError, ValueError, TypeError):
            self.items = []

    @staticmethod
    def normalize(raw) -> list[dict]:
        if isinstance(raw, dict):
            raw = raw.get("paths", [])
        if not isinstance(raw, list):
            raise ValueError("Lista e rrugëve është e pavlefshme")
        out, seen = [], set()
        for it in raw[:MAX_PATHS]:
            if isinstance(it, str):
                it = {"path": it}
            if not isinstance(it, dict):
                continue
            path = str(it.get("path", "")).strip().strip('"')
            if not path:
                continue
            pid = str(it.get("id") or "") or "p_" + uuid.uuid4().hex[:8]
            while pid in seen:
                pid = "p_" + uuid.uuid4().hex[:8]
            seen.add(pid)
            out.append({"id": pid, "name": str(it.get("name") or "").strip()[:60] or _default_name(path),
                        "path": path[:1000]})
        return out

    def save(self, raw) -> list[dict]:
        items = self.normalize(raw)
        with self.lock:
            self.items = items
            tmp = self.file.with_suffix(".tmp")
            tmp.write_text(json.dumps({"paths": items}, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, self.file)
        return items

    def add(self, path: str, name: str = "") -> dict | None:
        path = path.strip().strip('"')
        if not path:
            return None
        items = [i for i in self.items if os.path.normcase(_expand(i["path"])) != os.path.normcase(_expand(path))]
        new = {"id": "p_" + uuid.uuid4().hex[:8], "name": name or _default_name(path), "path": path}
        self.save([new] + items)          # newest on top: you change project folders often
        return new

    def remove(self, pid: str) -> None:
        self.save([i for i in self.items if i["id"] != pid])

    def get(self, pid: str) -> dict | None:
        return next((i for i in self.items if i["id"] == pid), None)

    def view(self) -> list[dict]:
        return [{**i, "exists": os.path.isdir(_expand(i["path"])) or os.path.isfile(_expand(i["path"]))}
                for i in self.items]


def resolve(path: str) -> str:
    return _expand(path)


def explorer_folders() -> list[dict]:
    """Folders open in File Explorer windows, most recently used first."""
    if not IS_WINDOWS:
        return []
    ps = ("$ErrorActionPreference='SilentlyContinue';"
          "(New-Object -ComObject Shell.Application).Windows() | ForEach-Object {"
          " $p = $_.Document.Folder.Self.Path; if ($p) { '' + $_.HWND + '|' + $p } }")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                             capture_output=True, text=True, timeout=10,
                             creationflags=0x08000000, encoding="utf-8", errors="replace").stdout
    except (OSError, subprocess.SubprocessError):
        return []
    wins: dict[int, str] = {}
    for line in out.splitlines():
        hwnd, _, p = line.strip().partition("|")
        if hwnd.isdigit() and p and not p.startswith("::"):   # skip virtual folders (This PC, Recycle Bin)
            wins.setdefault(int(hwnd), p)
    order = _zorder()
    rank = {h: i for i, h in enumerate(order)}
    items = sorted(wins.items(), key=lambda kv: rank.get(kv[0], 10_000))
    seen, out_items = set(), []
    for _, p in items:
        if p.lower() in seen:
            continue
        seen.add(p.lower())
        out_items.append({"path": p, "name": _default_name(p)})
    return out_items


def _zorder() -> list[int]:
    """Top-level windows from front to back."""
    import ctypes
    user32 = ctypes.windll.user32
    user32.GetTopWindow.restype = ctypes.c_void_p
    user32.GetWindow.restype = ctypes.c_void_p
    user32.GetWindow.argtypes = (ctypes.c_void_p, ctypes.c_uint)
    out, h = [], user32.GetTopWindow(None)
    while h and len(out) < 5000:
        out.append(int(h))
        h = user32.GetWindow(h, 2)   # GW_HWNDNEXT
    return out


def pick_folder(initial: str = "") -> str:
    """Native folder picker on the PC (used by the editor's 'Zgjidh…' button)."""
    import tkinter as tk
    from tkinter import filedialog
    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    try:
        return filedialog.askdirectory(parent=root, title="Zgjidh dosjen",
                                       initialdir=resolve(initial) if initial else None) or ""
    finally:
        root.destroy()


def short(path: str) -> str:
    return re.sub(r"^[A-Za-z]:\\Users\\[^\\]+", "~", path)
