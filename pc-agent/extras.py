"""
USB Deck - vecori shtese:
  * FileReceiver    - merr skedare nga iPad-i neper kabllo
  * timecode_steps  - si te shkohet te nje timecode ne Premiere / Resolve / AE
"""

from __future__ import annotations

import base64
import os
import re
import threading
import time
from pathlib import Path

IS_WINDOWS = os.name == "nt"


# --------------------------------------------------------------------------- #
# File transfer
# --------------------------------------------------------------------------- #

def _safe_name(name: str) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", str(name)).strip(" .")
    return name[:180] or "skedar"


def _unique(path: Path) -> Path:
    if not path.exists():
        return path
    stem, ext = path.stem, path.suffix
    i = 1
    while True:
        cand = path.with_name(f"{stem} ({i}){ext}")
        if not cand.exists():
            return cand
        i += 1


class FileReceiver:
    def __init__(self, folder_getter) -> None:
        self.folder_getter = folder_getter
        self.files: dict[str, dict] = {}
        self.lock = threading.Lock()

    def folder(self) -> Path:
        raw = str(self.folder_getter() or "").strip() or "%USERPROFILE%\\Desktop\\Nga iPad-i"
        p = Path(os.path.expandvars(os.path.expanduser(raw)))
        p.mkdir(parents=True, exist_ok=True)
        return p

    def begin(self, fid: str, name: str, size: int) -> None:
        with self.lock:
            self._drop(fid)
            target = _unique(self.folder() / _safe_name(name))
            part = target.with_name(target.name + ".part")
            self.files[fid] = {"target": target, "part": part, "fh": open(part, "wb"),
                               "size": int(size or 0), "got": 0, "start": time.time()}

    def chunk(self, fid: str, data: str) -> None:
        with self.lock:
            f = self.files.get(fid)
            if not f:
                raise ValueError("transferim i panjohur")
            raw = base64.b64decode(data)
            f["fh"].write(raw)
            f["got"] += len(raw)

    def end(self, fid: str) -> dict:
        with self.lock:
            f = self.files.pop(fid, None)
            if not f:
                raise ValueError("transferim i panjohur")
            f["fh"].close()
            target = _unique(f["target"])
            os.replace(f["part"], target)
            return {"path": str(target), "name": target.name, "bytes": f["got"],
                    "seconds": round(time.time() - f["start"], 1)}

    def _drop(self, fid: str) -> None:
        f = self.files.pop(fid, None)
        if f:
            try:
                f["fh"].close()
                f["part"].unlink(missing_ok=True)
            except OSError:
                pass

    def abort(self, fid: str) -> None:
        with self.lock:
            self._drop(fid)

    def abort_all(self) -> None:
        with self.lock:
            for fid in list(self.files):
                self._drop(fid)


# --------------------------------------------------------------------------- #
# Timecode navigation
# --------------------------------------------------------------------------- #

DEFAULT_TC_START = {"adobe premiere pro.exe": 0, "resolve.exe": 1, "afterfx.exe": 0}


def timecode_steps(exe: str | None, seconds: float, frames: int, start_hours: dict) -> list[dict] | None:
    """Keyboard steps that move the playhead to the timecode in the focused app."""
    if exe not in DEFAULT_TC_START:
        return None
    offset = int(start_hours.get(exe, DEFAULT_TC_START[exe]) or 0)
    total = int(seconds) + offset * 3600
    hh, mm, ss = total // 3600, (total % 3600) // 60, total % 60
    digits = f"{hh:02d}{mm:02d}{ss:02d}{max(0, int(frames)):02d}".lstrip("0") or "0"
    if exe == "adobe premiere pro.exe":
        # Shift+3 focuses the Timeline; typing digits edits the playhead timecode.
        return [{"keys": "shift+3"}, {"wait": 0.15}, {"text": digits}, {"keys": "enter"}]
    if exe == "resolve.exe":
        return [{"text": digits}, {"keys": "enter"}]
    if exe == "afterfx.exe":
        # Alt+Shift+J = "Go to Time" dialog.
        return [{"keys": "alt+shift+j"}, {"wait": 0.4}, {"keys": "ctrl+a"}, {"text": digits}, {"keys": "enter"}]
    return None



# --------------------------------------------------------------------------- #
# Windows clipboard (read) - for pasting client feedback from the PC
# --------------------------------------------------------------------------- #

def read_clipboard() -> str:
    if not IS_WINDOWS:
        return ""
    try:
        import ctypes
        from ctypes import wintypes

        user32 = ctypes.WinDLL("user32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        user32.OpenClipboard.argtypes = [wintypes.HWND]
        user32.OpenClipboard.restype = wintypes.BOOL
        user32.GetClipboardData.argtypes = [wintypes.UINT]
        user32.GetClipboardData.restype = wintypes.HANDLE
        kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
        kernel32.GlobalLock.restype = wintypes.LPVOID
        kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]

        for _ in range(10):
            if user32.OpenClipboard(None):
                break
            time.sleep(0.05)
        else:
            return ""
        try:
            handle = user32.GetClipboardData(13)  # CF_UNICODETEXT
            if not handle:
                return ""
            ptr = kernel32.GlobalLock(handle)
            if not ptr:
                return ""
            try:
                return ctypes.wstring_at(ptr)
            finally:
                kernel32.GlobalUnlock(handle)
        finally:
            user32.CloseClipboard()
    except Exception:
        return ""
