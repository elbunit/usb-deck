"""
USB Deck - njoftimi i render-it.

Ndjek dosjet e eksportit. Kur shfaqet nje skedar i ri video/audio qe po
rritet, e quan "duke u renderuar"; kur madhesia nuk ndryshon me per disa
sekonda, njofton "render-i perfundoi".
"""

from __future__ import annotations

import os
import threading
import time
from pathlib import Path
from typing import Callable

MEDIA_EXT = {".mp4", ".mov", ".mxf", ".avi", ".mkv", ".m4v", ".webm", ".wav", ".mp3",
             ".aac", ".aif", ".aiff", ".gif", ".m4a", ".flac", ".h264", ".hevc", ".mpg", ".mpeg"}
IGNORE_PARTS = (".tmp", ".part", ".crdownload", "~", "auto-save", "autosave", ".pek", ".cfa", ".ims")
STABLE_SECONDS = 4.0
SCAN_INTERVAL = 1.5
MAX_DEPTH = 3


def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def human_duration(sec: float) -> str:
    sec = int(round(sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}o {m:02d}m"
    if m:
        return f"{m}m {s:02d}s"
    return f"{s}s"


class RenderWatcher(threading.Thread):
    def __init__(self, get_settings: Callable[[], dict], emit: Callable[[dict], None],
                 log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="render-watch")
        self.get_settings = get_settings
        self.emit = emit
        self.log = log
        self.known: dict[str, tuple[int, float]] = {}   # path -> (size, mtime) at baseline
        self.jobs: dict[str, dict] = {}                 # path -> {start, size, changed, grew}
        self.folders_sig = ""
        self.extra: set[str] = set()      # e.g. export folders chosen from the iPad

    # ------------------------------------------------------------------ helpers
    def folders(self) -> list[Path]:
        s = self.get_settings()
        if not s.get("render_notify", True):
            return []
        out = []
        for f in list(s.get("render_folders", [])) + sorted(self.extra):
            p = Path(os.path.expandvars(os.path.expanduser(str(f).strip())))
            if str(f).strip() and p.is_dir():
                out.append(p)
        return out

    def scan(self, roots: list[Path]) -> dict[str, tuple[int, float]]:
        found: dict[str, tuple[int, float]] = {}

        def walk(d: Path, depth: int) -> None:
            try:
                with os.scandir(d) as it:
                    for e in it:
                        name = e.name.lower()
                        if e.is_dir(follow_symlinks=False):
                            if depth < MAX_DEPTH and not name.startswith("."):
                                walk(Path(e.path), depth + 1)
                            continue
                        if os.path.splitext(name)[1] not in MEDIA_EXT:
                            continue
                        if any(part in name for part in IGNORE_PARTS):
                            continue
                        try:
                            st = e.stat()
                        except OSError:
                            continue
                        found[e.path] = (st.st_size, st.st_mtime)
            except OSError:
                pass

        for r in roots:
            walk(r, 0)
        return found

    # ------------------------------------------------------------------ loop
    def run(self) -> None:
        while True:
            try:
                self.tick()
            except Exception as e:
                self.log(f"Gabim te ndjekja e render-it: {e}")
            time.sleep(SCAN_INTERVAL)

    def tick(self) -> None:
        roots = self.folders()
        sig = "|".join(sorted(str(r) for r in roots))
        now = time.time()
        if sig != self.folders_sig:
            # New folder list: take a silent baseline so existing files don't trigger.
            self.folders_sig = sig
            self.known = self.scan(roots)
            self.jobs.clear()
            if roots:
                self.log("Njoftimi i render-it ndjek: " + ", ".join(str(r) for r in roots))
            return
        if not roots:
            return

        current = self.scan(roots)
        for path, (size, mtime) in current.items():
            old = self.known.get(path)
            job = self.jobs.get(path)
            if job is None:
                is_new = old is None
                is_rewritten = old is not None and (size != old[0] or mtime != old[1])
                if is_new or is_rewritten:
                    self.jobs[path] = {"start": now, "size": size, "changed": now, "grew": False,
                                       "announced": False}
                continue
            if size != job["size"]:
                job["grew"] = True
                job["size"] = size
                job["changed"] = now
                if not job["announced"] and size > 0:
                    job["announced"] = True
                    self.emit({"type": "render", "state": "started", "path": path,
                               "name": os.path.basename(path)})
            elif now - job["changed"] >= STABLE_SECONDS:
                if job["grew"] and size > 0:
                    elapsed = job["changed"] - job["start"]
                    self.emit({
                        "type": "render", "state": "done", "path": path,
                        "name": os.path.basename(path), "folder": os.path.dirname(path),
                        "size": human_size(size), "duration": human_duration(max(elapsed, 1)),
                        "finished": time.strftime("%H:%M"),
                    })
                    self.log(f"Render-i perfundoi: {os.path.basename(path)} ({human_size(size)})")
                # A file that appeared already complete (copy/download) is ignored.
                del self.jobs[path]
        for path in list(self.jobs):
            if path not in current:   # deleted / renamed while writing
                job = self.jobs.pop(path)
                if job.get("announced"):
                    self.emit({"type": "render", "state": "cancelled", "path": path,
                               "name": os.path.basename(path)})
        self.known = current
