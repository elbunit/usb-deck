"""
USB Deck - lidhja e thelle me Premiere Pro.

Paneli "USB Deck" brenda Premiere-s (CEP) pyet agjentin 10 here ne sekonde:
  POST /api/ppro/state  -> gjendja (sekuenca, playhead, markerat)
                        <- komandat ne pritje (shko te koha, shto marker, eksport...)
Agjenti ia kalon gjendjen iPad-it dhe komandat e iPad-it panelit.
"""

from __future__ import annotations

import glob
import os
import shutil
import threading
import time
import uuid
from pathlib import Path
from typing import Callable

IS_WINDOWS = os.name == "nt"
PANEL_ID = "com.usbdeck.ppro"

FAVORITE_PRESET_WORDS = ("match source - high", "youtube", "vimeo", "instagram", "tiktok", "twitter",
                         "facebook", "prores", "dnxhr", "h.264", "hevc", "4k")


def install_panel(src_dir: Path) -> str:
    """Copies the panel into the CEP extensions folder and enables unsigned panels."""
    if not IS_WINDOWS:
        return "Paneli instalohet vetëm në Windows."
    dest = Path(os.path.expandvars(r"%APPDATA%\Adobe\CEP\extensions")) / PANEL_ID
    try:
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(src_dir, dest)
    except OSError as e:
        return f"Kopjimi dështoi: {e}"
    try:
        import winreg
        for v in range(9, 14):
            key = winreg.CreateKey(winreg.HKEY_CURRENT_USER, rf"Software\Adobe\CSXS.{v}")
            winreg.SetValueEx(key, "PlayerDebugMode", 0, winreg.REG_SZ, "1")
            winreg.CloseKey(key)
    except OSError as e:
        return f"Paneli u kopjua, por regjistri dështoi: {e}"
    return "ok"


def panel_installed() -> bool:
    if not IS_WINDOWS:
        return False
    return (Path(os.path.expandvars(r"%APPDATA%\Adobe\CEP\extensions")) / PANEL_ID / "host.jsx").exists()


def find_presets() -> list[dict]:
    """Media Encoder presets (.epr): the user's own + the useful system ones."""
    roots = []
    if IS_WINDOWS:
        roots += glob.glob(r"C:\Program Files\Adobe\Adobe Media Encoder*\MediaIO\systempresets")
        roots += glob.glob(os.path.expandvars(r"%USERPROFILE%\Documents\Adobe\Adobe Media Encoder\*\Presets"))
    seen, out = set(), []
    for root in sorted(roots, reverse=True):          # newest version first
        user = "Documents" in root
        for p in glob.glob(os.path.join(root, "**", "*.epr"), recursive=True):
            name = Path(p).stem
            if name.lower() in seen:
                continue
            if not user and not any(w in name.lower() for w in FAVORITE_PRESET_WORDS):
                continue
            seen.add(name.lower())
            out.append({"name": name, "path": p, "user": user})
    out.sort(key=lambda x: (not x["user"], x["name"].lower()))
    return out[:150]


class PremiereBridge:
    def __init__(self, send: Callable[[dict], bool], get_settings: Callable[[], dict],
                 log: Callable[[str], None]) -> None:
        self.send = send
        self.get_settings = get_settings
        self.log = log
        self.lock = threading.Lock()
        self.commands: list[dict] = []
        self.last_seen = 0.0
        self.state: dict | None = None
        self.markers: list = []
        self._sig = ""
        self._last_pos = None
        self._last_pos_sent = 0.0
        self.project_dir = ""
        self.presets: list[dict] = []
        self._presets_time = 0.0

    # -------------------------------------------------- from the panel
    def on_panel_state(self, body: dict) -> list[dict]:
        self.last_seen = time.time()
        st = body.get("state") or {}
        if st.get("projectPath"):
            self.project_dir = os.path.dirname(str(st["projectPath"]))
        seq = st.get("sequence") or None
        if body.get("markers") and seq is not None:
            self.markers = seq.get("markers") or []
        compact = {
            "connected": True, "project": st.get("project", ""), "sequences": st.get("sequences", []),
            "sequence": None if not seq else {k: seq.get(k) for k in ("id", "name", "fps", "zero", "end")},
            "markers": self.markers if seq else [],
        }
        sig = repr(compact)
        if sig != self._sig:
            self._sig = sig
            self.state = compact
            self.send({"type": "ppro_state", **compact})
        if seq is not None:
            pos = seq.get("seconds")
            now = time.time()
            if pos != self._last_pos and now - self._last_pos_sent > 0.08:
                self._last_pos, self._last_pos_sent = pos, now
                self.send({"type": "ppro_pos", "seconds": pos})
        with self.lock:
            cmds, self.commands = self.commands, []
        return cmds

    def on_result(self, body: dict) -> None:
        cmd, result = body.get("cmd"), str(body.get("result") or "")
        if cmd == "export":
            if result.startswith("ok|"):
                self.send({"type": "toast", "text": "📤 U dërgua te Media Encoder: " + os.path.basename(result[3:])})
            else:
                self.send({"type": "toast", "text": f"Eksporti dështoi: {result or 'pa përgjigje'}"})
        elif cmd == "organize":
            try:
                import json as _json
                data = _json.loads(result)
            except ValueError:
                data = {"ok": False, "error": result or "pa përgjigje"}
            if data.get("ok"):
                parts = ", ".join(f"{k.split(' ', 1)[-1]} {v}" for k, v in sorted((data.get("counts") or {}).items()))
                extra = f" · {data['removedBins']} bin-e bosh u hoqën" if data.get("removedBins") else ""
                self.send({"type": "toast", "text": f"✓ U rregulluan {data.get('moved', 0)} skedarë: {parts}{extra}"})
            else:
                self.send({"type": "toast", "text": f"Rregullimi dështoi: {data.get('error')}"})
        elif cmd == "import":
            msg = {"ok": "✓ Logo u vendos në Premiere (bin “Logot”)",
                   "ok-nosequence": "✓ Logo u importua (hap një sekuencë për ta vendosur në timeline)"}.get(result)
            self.send({"type": "toast", "text": msg or f"Premiere: {result or 'pa përgjigje'}"})
        elif result and result != "ok":
            self.send({"type": "toast", "text": f"Premiere: {result}"})

    # -------------------------------------------------- from the iPad
    @property
    def connected(self) -> bool:
        return time.time() - self.last_seen < 2.5

    def queue(self, cmd: dict) -> None:
        if not self.connected:
            self.send({"type": "toast", "text": "Hap Premiere-n me panelin USB Deck (Window › Extensions › USB Deck)"})
            return
        cmd.setdefault("id", uuid.uuid4().hex[:8])
        with self.lock:
            self.commands.append(cmd)

    def export(self, preset: str, rng: int, start: bool) -> str:
        s = self.get_settings()
        folder = str(s.get("ppro_export_folder") or "").strip()
        if not folder:
            folder = os.path.join(self.project_dir, "Eksporte") if self.project_dir \
                else os.path.expandvars(r"%USERPROFILE%\Videos")
        folder = os.path.expandvars(folder)
        self.queue({"cmd": "export", "preset": preset, "folder": folder, "range": rng, "start": start})
        return folder

    def status(self) -> dict:
        if time.time() - self._presets_time > 60 or not self.presets:
            self.presets = find_presets()
            self._presets_time = time.time()
        st = {"type": "ppro_status", "connected": self.connected, "installed": panel_installed(),
              "presets": [{"name": p["name"], "path": p["path"], "user": p["user"]} for p in self.presets]}
        return st

    def watchdog(self) -> None:
        """Tell the iPad when the panel goes away (Premiere closed)."""
        was = False
        while True:
            now = self.connected
            if was and not now:
                self._sig = ""
                self.send({"type": "ppro_state", "connected": False})
            was = now
            time.sleep(1.0)
