"""
USB Deck - hap programet me nje prekje.

* Skanon Start Menu (shortcut-et .lnk) dhe merr shtegun e .exe + ikonen e
  programit (permes PowerShell, nje here; ruhet ne apps_cache.json).
* Nese programi eshte i hapur, e sjell dritaren e tij perpara; perndryshe e hap.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Callable

IS_WINDOWS = os.name == "nt"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

KNOWN = ["premiere pro", "after effects", "davinci resolve", "photoshop", "illustrator", "media encoder",
         "audition", "lightroom", "spotify", "google chrome", "microsoft edge", "firefox", "whatsapp",
         "telegram", "discord", "obs studio", "vlc", "capcut", "blender", "cinema 4d"]
SKIP_WORDS = ("uninstall", "readme", "help", "documentation", "website", "release notes", "license",
              "safe mode", "debug", "update", "repair")

PS_SCAN = r"""
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Drawing
$sh = New-Object -ComObject WScript.Shell
$dirs = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")
$out = @()
foreach ($d in $dirs) {
  Get-ChildItem -Path $d -Recurse -Filter *.lnk | ForEach-Object {
    $t = $sh.CreateShortcut($_.FullName).TargetPath
    if ($t -and $t.ToLower().EndsWith('.exe') -and (Test-Path $t)) {
      $icon = ''
      try {
        $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($t)
        $bmp = $ic.ToBitmap()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $icon = [Convert]::ToBase64String($ms.ToArray())
      } catch {}
      $out += [pscustomobject]@{ name = $_.BaseName; lnk = $_.FullName; target = $t; icon = $icon }
    }
  }
}
$out | ConvertTo-Json -Compress
"""


def running_exes() -> set[str]:
    if not IS_WINDOWS:
        return set()
    try:
        out = subprocess.run(["tasklist", "/FO", "CSV", "/NH"], capture_output=True, text=True,
                             timeout=8, creationflags=NO_WINDOW).stdout
        return {line.split('","')[0].strip('"').lower() for line in out.splitlines() if line.startswith('"')}
    except Exception:
        return set()


def focus_process(exe: str) -> bool:
    """Bring the main window of a running program to the front."""
    if not IS_WINDOWS:
        return False
    import ctypes
    from ctypes import wintypes
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    found: list[int] = []

    def exe_of(pid: int) -> str:
        h = kernel32.OpenProcess(0x1000, False, pid)
        if not h:
            return ""
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = wintypes.DWORD(1024)
            if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                return os.path.basename(buf.value).lower()
        finally:
            kernel32.CloseHandle(h)
        return ""

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(hwnd, _lparam):
        if user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0 \
                and not user32.GetWindow(hwnd, 4):            # GW_OWNER: skip tool windows
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if exe_of(pid.value) == exe:
                found.append(hwnd)
                return False
        return True

    user32.EnumWindows(cb, 0)
    if not found:
        return False
    hwnd = found[0]
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)          # SW_RESTORE
    # Windows only lets the foreground process change focus - a tap of Alt unlocks it.
    user32.keybd_event(0x12, 0, 0, 0)
    user32.keybd_event(0x12, 0, 2, 0)
    user32.SetForegroundWindow(hwnd)
    return True


class AppCatalog:
    def __init__(self, cache_path: Path, log: Callable[[str], None]) -> None:
        self.cache_path = cache_path
        self.log = log
        self.apps: list[dict] = []
        self.ready = threading.Event()
        try:
            self.apps = json.loads(cache_path.read_text(encoding="utf-8"))
            self.ready.set()
        except (OSError, ValueError):
            pass

    def scan_async(self, force: bool = False) -> None:
        if self.apps and not force:
            return
        threading.Thread(target=self.scan, daemon=True, name="app-scan").start()

    def scan(self) -> None:
        if not IS_WINDOWS:
            self.ready.set()
            return
        try:
            raw = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", PS_SCAN],
                                 capture_output=True, timeout=180, creationflags=NO_WINDOW).stdout
            data = json.loads(raw.decode("utf-8", "replace").strip() or "[]")
            if isinstance(data, dict):
                data = [data]
            seen, apps = set(), []
            for a in data:
                name = str(a.get("name", "")).strip()
                low = name.lower()
                key = str(a.get("target", "")).lower()
                if not name or key in seen or any(w in low for w in SKIP_WORDS):
                    continue
                seen.add(key)
                apps.append({"name": name, "path": a.get("lnk", ""), "target": a.get("target", ""),
                             "exe": os.path.basename(str(a.get("target", ""))).lower(), "icon": a.get("icon", "")})
            apps.sort(key=lambda x: x["name"].lower())
            self.apps = apps
            self.cache_path.write_text(json.dumps(apps, ensure_ascii=False), encoding="utf-8")
            self.log(f"Programet: u gjetën {len(apps)} programe të instaluara.")
        except Exception as e:
            self.log(f"Programet: skanimi dështoi ({e})")
        finally:
            self.ready.set()

    def icon_for(self, exe: str) -> str:
        for a in self.apps:
            if a["exe"] == exe and a.get("icon"):
                return a["icon"]
        return ""

    def defaults(self) -> list[dict]:
        out, used = [], set()
        for word in KNOWN:
            for a in self.apps:
                if word in a["name"].lower() and a["exe"] not in used:
                    used.add(a["exe"])
                    out.append({"name": a["name"], "path": a["path"], "exe": a["exe"]})
                    break
        return out


def launch(item: dict, log: Callable[[str], None]) -> str:
    exe = str(item.get("exe") or "").lower()
    path = os.path.expandvars(str(item.get("path") or ""))
    name = item.get("name") or os.path.basename(path)
    if exe and exe in running_exes() and focus_process(exe):
        return f"↗ {name}"
    if not path:
        return f"Mungon shtegu për {name}"
    if not IS_WINDOWS:
        log(f"[hap] {path}")
        return f"Duke hapur {name}…"
    try:
        os.startfile(path)  # type: ignore[attr-defined]
        return f"🚀 Duke hapur {name}…"
    except OSError as e:
        return f"{name} nuk u hap: {e}"
