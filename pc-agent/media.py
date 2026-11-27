"""
USB Deck - "Muzika qe po luan".

Lexon sesionin e medias se Windows-it (i njejti qe shfaqet kur shtyp tastet e
volumit): Spotify, YouTube ne Chrome/Edge, VLC, Windows Media Player etj.
Jep titullin, artistin, kopertinen, pozicionin dhe kontrollet.

Kerkon paketat pywinrt (instalohen vete nga "Start USB Deck.bat"):
  winrt-runtime winrt-Windows.Media.Control winrt-Windows.Foundation
  winrt-Windows.Foundation.Collections winrt-Windows.Storage.Streams
"""

from __future__ import annotations

import asyncio
import base64
import io
import os
import queue
import threading
import time
from datetime import datetime, timezone
from typing import Callable

IS_WINDOWS = os.name == "nt"


def pretty_app(aumid: str) -> tuple[str, str]:
    """(display name, exe for the volume mixer) from an AppUserModelID."""
    low = (aumid or "").lower()
    table = [("spotify", "Spotify", "spotify.exe"), ("chrome", "Chrome", "chrome.exe"),
             ("msedge", "Edge", "msedge.exe"), ("edge", "Edge", "msedge.exe"),
             ("firefox", "Firefox", "firefox.exe"), ("308046b0af4a39cb", "Firefox", "firefox.exe"),
             ("opera", "Opera", "opera.exe"), ("brave", "Brave", "brave.exe"), ("vlc", "VLC", "vlc.exe"),
             ("zunemusic", "Media Player", ""), ("zunevideo", "Filma & TV", ""), ("deezer", "Deezer", "deezer.exe"),
             ("tidal", "TIDAL", "tidal.exe"), ("apple", "Apple Music", ""), ("youtube", "YouTube Music", "")]
    for key, name, exe in table:
        if key in low:
            return name, exe
    base = (aumid or "Media").split("!")[0].split("\\")[-1]
    if base.lower().endswith(".exe"):
        return base[:-4], base.lower()
    return base.split(".")[0] or "Media", ""


BROWSER_EXES = {"chrome.exe", "msedge.exe", "firefox.exe", "opera.exe", "brave.exe", "vivaldi.exe"}
SITES = [("youtube music", "YouTube Music"), ("youtube", "YouTube"), ("soundcloud", "SoundCloud"),
         ("spotify", "Spotify Web"), ("netflix", "Netflix"), ("twitch", "Twitch"), ("vimeo", "Vimeo"),
         ("tiktok", "TikTok"), ("instagram", "Instagram"), ("facebook", "Facebook"), ("deezer", "Deezer"),
         ("apple music", "Apple Music"), ("tidal", "TIDAL"), ("mixcloud", "Mixcloud"), ("bandcamp", "Bandcamp")]


def browser_site(exe: str, media_title: str) -> str | None:
    """Which website is playing in the browser - read from the browser's window titles."""
    if not IS_WINDOWS or exe not in BROWSER_EXES:
        return None
    try:
        import ctypes
        from ctypes import wintypes
        user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
        titles: list[str] = []

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
        def cb(hwnd, _lp):
            n = user32.GetWindowTextLengthW(hwnd)
            if n and user32.IsWindowVisible(hwnd):
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
                if exe_of(pid.value) == exe:
                    buf = ctypes.create_unicode_buffer(n + 1)
                    user32.GetWindowTextW(hwnd, buf, n + 1)
                    titles.append(buf.value.lower())
            return True

        user32.EnumWindows(cb, 0)
        mt = (media_title or "").lower()
        # Prefer the window whose title contains the playing media's title.
        ordered = sorted(titles, key=lambda t: 0 if mt and mt[:30] in t else 1)
        for t in ordered:
            for key, name in SITES:
                if key in t:
                    return name
    except Exception:
        return None
    return None


def _shrink_cover(data: bytes) -> str:
    try:
        from PIL import Image
        img = Image.open(io.BytesIO(data)).convert("RGB")
        img.thumbnail((480, 480))
        out = io.BytesIO()
        img.save(out, "JPEG", quality=85)
        data = out.getvalue()
    except Exception:
        pass
    return base64.b64encode(data).decode("ascii")


class MediaService(threading.Thread):
    def __init__(self, on_state: Callable[[dict], None], on_position: Callable[[dict], None],
                 log: Callable[[str], None]) -> None:
        super().__init__(daemon=True, name="media")
        self.on_state = on_state
        self.on_position = on_position
        self.log = log
        self.commands: queue.Queue = queue.Queue()
        self.selected: str | None = None
        self.state: dict = {"available": False}
        self.cover_b64: str | None = None
        self.cover_id = 0
        self._cover_key = None
        self._last_sig = ""

    def command(self, action: str, value=None) -> None:
        self.commands.put((action, value))

    def full_state(self) -> dict:
        st = dict(self.state)
        st["cover"] = self.cover_b64
        st["cover_id"] = self.cover_id
        return st

    # ------------------------------------------------------------------ thread
    def run(self) -> None:
        if not IS_WINDOWS:
            self._fake_loop()
            return
        try:
            from winrt.windows.media.control import \
                GlobalSystemMediaTransportControlsSessionManager as Manager  # noqa: F401
        except Exception as e:
            self.log(f"Muzika: mungojnë paketat winrt ({e}). Hap prapë 'Start USB Deck.bat'.")
            self._publish({"available": False, "reason": "winrt"})
            return
        try:
            asyncio.run(self._main())
        except Exception as e:
            self.log(f"Muzika: ndaloi ({e})")

    async def _main(self) -> None:
        from winrt.windows.media.control import GlobalSystemMediaTransportControlsSessionManager as Manager
        mgr = await Manager.request_async()
        last_pos = 0.0
        while True:
            try:
                while True:
                    action, value = self.commands.get_nowait()
                    await self._do(mgr, action, value)
            except queue.Empty:
                pass
            try:
                st = await self._snapshot(mgr)
            except Exception as e:
                st = {"available": True, "active": False, "error": str(e)}
            self._publish(st)
            if st.get("active") and time.time() - last_pos >= 1.0:
                last_pos = time.time()
                self.on_position({"type": "media_pos", "position": st.get("position", 0),
                                  "duration": st.get("duration", 0), "playing": st.get("playing", False)})
            await asyncio.sleep(0.4)

    def _session(self, mgr):
        sessions = list(mgr.get_sessions())
        if self.selected:
            for s in sessions:
                if s.source_app_user_model_id == self.selected:
                    return s, sessions
        return mgr.get_current_session(), sessions

    async def _do(self, mgr, action: str, value) -> None:
        if action == "select":
            self.selected = str(value) if value else None
            self._cover_key = None
            return
        s, _ = self._session(mgr)
        if s is None:
            return
        if action == "toggle":
            await s.try_toggle_play_pause_async()
        elif action == "next":
            await s.try_skip_next_async()
        elif action == "prev":
            await s.try_skip_previous_async()
        elif action == "seek":
            tl = s.get_timeline_properties()
            start = tl.start_time.total_seconds() if tl.start_time else 0
            ticks = int((start + float(value or 0)) * 10_000_000)
            await s.try_change_playback_position_async(ticks)

    async def _snapshot(self, mgr) -> dict:
        s, sessions = self._session(mgr)
        sources = []
        for x in sessions:
            name, ex = pretty_app(x.source_app_user_model_id)
            if ex in BROWSER_EXES:
                try:
                    p = await x.try_get_media_properties_async()
                    name = browser_site(ex, p.title or "") or name
                except Exception:
                    pass
            sources.append({"id": x.source_app_user_model_id, "name": name})
        if s is None:
            return {"available": True, "active": False, "sources": sources}
        props = await s.try_get_media_properties_async()
        info = s.get_playback_info()
        tl = s.get_timeline_properties()
        playing = int(info.playback_status) == 4
        start = tl.start_time.total_seconds() if tl.start_time else 0
        end = tl.end_time.total_seconds() if tl.end_time else 0
        pos = (tl.position.total_seconds() if tl.position else 0) - start
        try:
            if playing and tl.last_updated_time:
                updated = tl.last_updated_time
                if updated.tzinfo is None:
                    updated = updated.replace(tzinfo=timezone.utc)
                pos += max(0.0, (datetime.now(timezone.utc) - updated).total_seconds())
        except Exception:
            pass
        duration = max(0.0, end - start)
        if duration:
            pos = min(pos, duration)
        app, exe = pretty_app(s.source_app_user_model_id)
        title = props.title or ""
        site = browser_site(exe, title)
        if site:
            app = site
        artist = props.artist or props.album_artist or ""
        key = (s.source_app_user_model_id, title, artist)
        if key != self._cover_key:
            self._cover_key = key
            self.cover_b64 = await self._read_cover(props)
            self.cover_id += 1
        return {"available": True, "active": True, "source": s.source_app_user_model_id, "sources": sources,
                "app": app, "exe": exe, "title": title, "artist": artist, "album": props.album_title or "",
                "playing": playing, "position": round(pos, 1), "duration": round(duration, 1),
                "can_seek": bool(duration)}

    @staticmethod
    async def _read_cover(props) -> str | None:
        thumb = props.thumbnail
        if thumb is None:
            return None
        try:
            from winrt.windows.storage.streams import Buffer, DataReader, InputStreamOptions
            stream = await thumb.open_read_async()
            size = int(stream.size)
            if size <= 0 or size > 8_000_000:
                return None
            buf = Buffer(size)
            await stream.read_async(buf, size, InputStreamOptions.READ_AHEAD)
            try:
                data = bytes(buf)
            except Exception:
                reader = DataReader.from_buffer(buf)
                arr = bytearray(buf.length)
                reader.read_bytes(arr)
                data = bytes(arr)
            return _shrink_cover(data) if data else None
        except Exception:
            return None

    def _publish(self, st: dict) -> None:
        sig_state = {k: v for k, v in st.items() if k != "position"}
        sig = repr(sorted(sig_state.items())) + str(self.cover_id)
        self.state = st
        if sig != self._last_sig:
            self._last_sig = sig
            self.on_state(self.full_state())

    # ------------------------------------------------------------------ simulated (non-Windows)
    def _fake_loop(self) -> None:
        tracks = [("Blinding Lights", "The Weeknd", 200.0), ("Levitating", "Dua Lipa", 203.0)]
        i, pos, playing = 0, 12.0, True
        self.cover_id = 1
        try:
            from PIL import Image
            img = Image.new("RGB", (300, 300), (230, 60, 90))
            out = io.BytesIO()
            img.save(out, "JPEG")
            self.cover_b64 = base64.b64encode(out.getvalue()).decode()
        except Exception:
            self.cover_b64 = None
        last = time.time()
        while True:
            try:
                while True:
                    action, value = self.commands.get_nowait()
                    if action == "toggle":
                        playing = not playing
                    elif action in ("next", "prev"):
                        i = (i + (1 if action == "next" else -1)) % len(tracks)
                        pos = 0.0
                        self.cover_id += 1
                    elif action == "seek":
                        pos = float(value or 0)
            except queue.Empty:
                pass
            now = time.time()
            if playing:
                pos = min(pos + now - last, tracks[i][2])
            last = now
            t = tracks[i]
            st = {"available": True, "active": True, "source": "Chrome",
                  "sources": [{"id": "Chrome", "name": "YouTube"}, {"id": "Spotify.exe", "name": "Spotify"}],
                  "app": "YouTube", "exe": "spotify.exe", "title": t[0], "artist": t[1], "album": "",
                  "playing": playing, "position": round(pos, 1), "duration": t[2], "can_seek": True}
            self._publish(st)
            self.on_position({"type": "media_pos", "position": round(pos, 1), "duration": t[2], "playing": playing})
            time.sleep(1.0)
