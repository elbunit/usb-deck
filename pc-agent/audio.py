"""
USB Deck - mikseri i volumit per Windows.

Perdor Windows Core Audio (permes pycaw/comtypes):
  * volumi + mute per cdo aplikacion qe luan ze
  * volumi kryesor (master) i pajisjes aktive
  * mute i mikrofonit
  * nderrimi i pajisjes se daljes (kufje <-> altoparlante)

Te gjitha thirrjet COM behen ne nje thread te vetem (AudioService), sepse
COM kerkon CoInitialize per cdo thread.
Ne sisteme jo-Windows (ose pa pycaw) punon nje "simulim" qe lejon testimin.
"""

from __future__ import annotations

import json
import os
import queue
import threading
import time
from typing import Callable

FRIENDLY = {
    "chrome.exe": ("Chrome", "globe"),
    "msedge.exe": ("Edge", "globe"),
    "firefox.exe": ("Firefox", "globe"),
    "opera.exe": ("Opera", "globe"),
    "brave.exe": ("Brave", "globe"),
    "spotify.exe": ("Spotify", "music.note"),
    "discord.exe": ("Discord", "bubble.left.and.bubble.right.fill"),
    "teams.exe": ("Teams", "person.3.fill"),
    "ms-teams.exe": ("Teams", "person.3.fill"),
    "zoom.exe": ("Zoom", "video.fill"),
    "whatsapp.exe": ("WhatsApp", "message.fill"),
    "telegram.exe": ("Telegram", "paperplane.fill"),
    "vlc.exe": ("VLC", "play.rectangle.fill"),
    "adobe premiere pro.exe": ("Premiere Pro", "film"),
    "afterfx.exe": ("After Effects", "sparkles"),
    "adobe media encoder.exe": ("Media Encoder", "film.stack"),
    "resolve.exe": ("Resolve", "paintpalette.fill"),
    "photoshop.exe": ("Photoshop", "paintbrush.fill"),
    "audition.exe": ("Audition", "waveform"),
    "obs64.exe": ("OBS", "record.circle"),
    "steam.exe": ("Steam", "gamecontroller.fill"),
    "system": ("Tingujt e sistemit", "bell.fill"),
}

AUDIO_COMMANDS = {
    "mic_toggle": "Mikrofoni on/off",
    "master_mute": "Mute (kompjuteri)",
    "output_next": "Pajisja tjetër e zërit",
}


def describe(exe: str) -> tuple[str, str]:
    if exe in FRIENDLY:
        return FRIENDLY[exe]
    name = exe[:-4] if exe.endswith(".exe") else exe
    return (name[:1].upper() + name[1:], "speaker.wave.2.fill")


# --------------------------------------------------------------------------- #
# Windows backend
# --------------------------------------------------------------------------- #

class WindowsAudio:
    def __init__(self) -> None:
        import comtypes  # noqa: F401
        from comtypes import CLSCTX_ALL, GUID, HRESULT, IUnknown, COMMETHOD
        from ctypes import POINTER, c_int, cast
        from ctypes.wintypes import LPCWSTR
        from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume, IMMDeviceEnumerator

        self.comtypes = comtypes
        self.CLSCTX_ALL = CLSCTX_ALL
        self.POINTER, self.cast = POINTER, cast
        self.AudioUtilities = AudioUtilities
        self.IAudioEndpointVolume = IAudioEndpointVolume

        comtypes.CoInitialize()
        clsid_enum = GUID("{BCDE0395-E52F-467C-8E3D-C4579291692E}")
        self.enum = comtypes.CoCreateInstance(clsid_enum, IMMDeviceEnumerator, comtypes.CLSCTX_INPROC_SERVER)

        # Undocumented-but-stable IPolicyConfig: the only way to change the default device.
        class IPolicyConfig(IUnknown):
            _iid_ = GUID("{f8679f50-850a-41cf-9c72-430f290290c8}")
            _methods_ = [COMMETHOD([], HRESULT, n) for n in (
                "GetMixFormat", "GetDeviceFormat", "ResetDeviceFormat", "SetDeviceFormat",
                "GetProcessingPeriod", "SetProcessingPeriod", "GetShareMode", "SetShareMode",
                "GetPropertyValue", "SetPropertyValue")] + [
                COMMETHOD([], HRESULT, "SetDefaultEndpoint",
                          (["in"], LPCWSTR, "wszDeviceId"), (["in"], c_int, "eRole")),
            ]
        self.IPolicyConfig = IPolicyConfig
        self.policy_clsid = GUID("{870af99c-171d-4f9e-af0d-e63df40c2bc9}")
        self._devices_cache: list[dict] = []
        self._devices_time = 0.0

    # -- endpoints --
    def _endpoint_volume(self, flow: int):
        dev = self.enum.GetDefaultAudioEndpoint(flow, 1)  # role: eMultimedia
        iface = dev.Activate(self.IAudioEndpointVolume._iid_, self.CLSCTX_ALL, None)
        return self.cast(iface, self.POINTER(self.IAudioEndpointVolume)), dev.GetId()

    def _outputs(self) -> list[dict]:
        if time.time() - self._devices_time < 4 and self._devices_cache:
            return self._devices_cache
        out = []
        try:
            coll = self.enum.EnumAudioEndpoints(0, 1)  # eRender, DEVICE_STATE_ACTIVE
            for i in range(coll.GetCount()):
                dev = coll.Item(i)
                ad = self.AudioUtilities.CreateDevice(dev)
                out.append({"id": ad.id, "name": ad.FriendlyName or "Pajisje"})
        except Exception:
            out = []
        self._devices_cache, self._devices_time = out, time.time()
        return out

    def snapshot(self) -> dict:
        state: dict = {"available": True}
        try:
            ev, default_id = self._endpoint_volume(0)
            state["master"] = {"volume": round(float(ev.GetMasterVolumeLevelScalar()), 3),
                               "muted": bool(ev.GetMute())}
        except Exception:
            default_id = ""
            state["master"] = None
        try:
            mic, _ = self._endpoint_volume(1)
            state["mic"] = {"muted": bool(mic.GetMute())}
        except Exception:
            state["mic"] = None
        outs = self._outputs()
        state["outputs"] = [dict(o, default=(o["id"] == default_id)) for o in outs]

        apps: dict[str, dict] = {}
        for s in self.AudioUtilities.GetAllSessions():
            try:
                if getattr(s, "State", 1) == 2:          # expired
                    continue
                exe = s.Process.name().lower() if s.Process else "system"
                vol = s.SimpleAudioVolume
                entry = apps.get(exe)
                if entry is None:
                    name, symbol = describe(exe)
                    apps[exe] = {"key": exe, "name": name, "symbol": symbol,
                                 "volume": round(float(vol.GetMasterVolume()), 3),
                                 "muted": bool(vol.GetMute()),
                                 "active": getattr(s, "State", 0) == 1}
                elif getattr(s, "State", 0) == 1:
                    entry["active"] = True
            except Exception:
                continue
        ordered = sorted(apps.values(), key=lambda a: (a["key"] == "system", not a["active"], a["name"].lower()))
        state["apps"] = ordered
        return state

    # -- commands --
    def _sessions(self, key: str):
        for s in self.AudioUtilities.GetAllSessions():
            exe = s.Process.name().lower() if s.Process else "system"
            if exe == key:
                yield s.SimpleAudioVolume

    def set_volume(self, target: str, key: str, value: float) -> None:
        value = max(0.0, min(1.0, float(value)))
        if target == "master":
            ev, _ = self._endpoint_volume(0)
            ev.SetMasterVolumeLevelScalar(value, None)
            if value > 0 and ev.GetMute():
                ev.SetMute(0, None)
        else:
            for v in self._sessions(key):
                v.SetMasterVolume(value, None)
                if value > 0 and v.GetMute():
                    v.SetMute(0, None)

    def set_mute(self, target: str, key: str, muted: bool | None) -> None:
        if target in ("master", "mic"):
            ev, _ = self._endpoint_volume(0 if target == "master" else 1)
            new = (not ev.GetMute()) if muted is None else muted
            ev.SetMute(1 if new else 0, None)
        else:
            vols = list(self._sessions(key))
            if not vols:
                return
            new = (not vols[0].GetMute()) if muted is None else muted
            for v in vols:
                v.SetMute(1 if new else 0, None)

    def set_output(self, device_id: str) -> None:
        policy = self.comtypes.CoCreateInstance(self.policy_clsid, self.IPolicyConfig, self.CLSCTX_ALL)
        for role in (0, 1, 2):  # console, multimedia, communications
            policy.SetDefaultEndpoint(device_id, role)
        self._devices_time = 0.0

    def next_output(self) -> str:
        outs = self._outputs()
        if len(outs) < 2:
            return ""
        _, default_id = self._endpoint_volume(0)
        ids = [o["id"] for o in outs]
        idx = ids.index(default_id) if default_id in ids else -1
        nxt = outs[(idx + 1) % len(outs)]
        self.set_output(nxt["id"])
        return nxt["name"]


# --------------------------------------------------------------------------- #
# Simulated backend (non-Windows / testing)
# --------------------------------------------------------------------------- #

class FakeAudio:
    def __init__(self) -> None:
        self.state = {
            "available": True, "simulated": True,
            "master": {"volume": 0.6, "muted": False},
            "mic": {"muted": False},
            "outputs": [{"id": "spk", "name": "Altoparlantët", "default": True},
                        {"id": "hp", "name": "Kufjet", "default": False}],
            "apps": [
                {"key": "spotify.exe", "name": "Spotify", "symbol": "music.note", "volume": 0.5, "muted": False, "active": True},
                {"key": "adobe premiere pro.exe", "name": "Premiere Pro", "symbol": "film", "volume": 1.0, "muted": False, "active": True},
                {"key": "chrome.exe", "name": "Chrome", "symbol": "globe", "volume": 0.8, "muted": False, "active": False},
                {"key": "system", "name": "Tingujt e sistemit", "symbol": "bell.fill", "volume": 1.0, "muted": False, "active": False},
            ],
        }

    def snapshot(self) -> dict:
        return json.loads(json.dumps(self.state))

    def _app(self, key):
        return next((a for a in self.state["apps"] if a["key"] == key), None)

    def set_volume(self, target, key, value):
        tgt = self.state["master"] if target == "master" else self._app(key)
        if tgt:
            tgt["volume"] = round(max(0.0, min(1.0, float(value))), 3)

    def set_mute(self, target, key, muted):
        tgt = {"master": self.state["master"], "mic": self.state["mic"]}.get(target) or self._app(key)
        if tgt:
            tgt["muted"] = (not tgt["muted"]) if muted is None else bool(muted)

    def set_output(self, device_id):
        for o in self.state["outputs"]:
            o["default"] = o["id"] == device_id

    def next_output(self):
        outs = self.state["outputs"]
        idx = next(i for i, o in enumerate(outs) if o["default"])
        nxt = outs[(idx + 1) % len(outs)]
        self.set_output(nxt["id"])
        return nxt["name"]


# --------------------------------------------------------------------------- #
# Service thread
# --------------------------------------------------------------------------- #

class AudioService(threading.Thread):
    """Owns the COM objects; polls state and runs commands in one thread."""

    def __init__(self, on_change: Callable[[dict], None], log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="audio")
        self.on_change = on_change
        self.log = log
        self.commands: queue.Queue = queue.Queue()
        self.last_json = ""
        self.state: dict = {"available": False}
        self.backend_name = "none"

    def submit(self, fn_name: str, *args, reply: Callable[[str], None] | None = None) -> None:
        self.commands.put((fn_name, args, reply))

    def run(self) -> None:
        backend = None
        if os.name == "nt":
            try:
                backend = WindowsAudio()
                self.backend_name = "windows"
            except Exception as e:
                self.log(f"Mikseri i volumit nuk u nis ({e}). Instalo: python -m pip install pycaw")
        else:
            backend = FakeAudio()
            self.backend_name = "simulated"
        if backend is None:
            return

        while True:
            batch = []
            try:
                batch.append(self.commands.get(timeout=0.35))
                while True:
                    batch.append(self.commands.get_nowait())
            except queue.Empty:
                pass
            # Slider drags send many values - keep only the latest per channel.
            latest: dict = {}
            for i, (name, args, _r) in enumerate(batch):
                if name == "set_volume":
                    latest[(args[0], args[1])] = i
            for i, (name, args, reply) in enumerate(batch):
                if name == "set_volume" and latest.get((args[0], args[1])) != i:
                    continue
                try:
                    result = getattr(backend, name)(*args)
                    if reply:
                        reply(result if isinstance(result, str) else "")
                except Exception as e:
                    self.log(f"Gabim audio ({name}): {e}")
                    if reply:
                        reply("")
            try:
                snap = backend.snapshot()
            except Exception as e:
                snap = {"available": False}
                if str(e) != getattr(self, "_last_err", None):
                    self._last_err = str(e)
                    self.log(f"Gabim audio: {e}")
            js = json.dumps(snap, sort_keys=True)
            if js != self.last_json:
                self.last_json = js
                self.state = snap
                self.on_change(snap)
