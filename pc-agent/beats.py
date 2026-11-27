"""
USB Deck - markera ne ritem te muzikes.

Analizon nje kenge (librosa, falas, ne PC), gjen BPM dhe cdo beat, dhe i kthen
ne markera per:
  * Premiere Pro  -> XML (sekuence e re me kengen + markerat), File > Import
  * DaVinci Resolve -> EDL markerash (Timeline > Import > Timeline Markers from EDL)
  * After Effects -> markera direkt te layer-i i zgjedhur (skript)
Librosa instalohet vete heren e pare qe perdoret kjo vegel.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable
from urllib.parse import quote

AUDIO_EXT = "*.mp3 *.wav *.m4a *.aac *.flac *.ogg *.aif *.aiff *.mp4 *.mov"


def librosa_available() -> bool:
    try:
        import librosa  # noqa: F401
        return True
    except Exception:
        return False


def install_librosa(log: Callable[[str], None]) -> bool:
    log("Ritmi: po instaloj librosa (vetëm herën e parë, ~150 MB)…")
    r = subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "-q", "librosa"],
                       capture_output=True, text=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if r.returncode != 0:
        log("Ritmi: instalimi dështoi: " + (r.stderr or r.stdout)[-400:])
        return False
    return librosa_available()


def ask_audio_file(initial_dir: str = "") -> str | None:
    """Windows "Open" dialog. Returns path, "" if cancelled, None if unavailable."""
    if os.environ.get("USBDECK_TEST_AUDIO"):
        return os.environ["USBDECK_TEST_AUDIO"]
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
        path = filedialog.askopenfilename(parent=root, title="Zgjidh këngën për markerat e ritmit",
                                          initialdir=initial_dir or None,
                                          filetypes=[("Audio / video", AUDIO_EXT), ("Të gjitha", "*.*")])
        root.destroy()
        return path or ""
    except Exception:
        return None


def analyze(path: str) -> dict:
    import librosa
    import numpy as np

    y, sr = librosa.load(path, sr=22050, mono=True)
    duration = float(len(y) / sr)
    hop = 512
    onset = librosa.onset.onset_strength(y=y, sr=sr, hop_length=hop)
    tempo, beat_frames = librosa.beat.beat_track(onset_envelope=onset, sr=sr, hop_length=hop)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr, hop_length=hop)
    bpm = float(np.atleast_1d(tempo)[0])

    # Strength of each beat (for "strong beats only") and the bar phase (downbeats every 4).
    strength = onset[np.clip(beat_frames, 0, len(onset) - 1)] if len(beat_frames) else np.array([])
    phase = 0
    if len(strength) >= 8:
        sums = [float(strength[p::4].mean()) for p in range(4)]
        phase = int(np.argmax(sums))

    # Small waveform for the iPad (RMS, 600 points, 0..1).
    rms = librosa.feature.rms(y=y, hop_length=hop)[0]
    pts = 600
    if len(rms) > pts:
        idx = np.linspace(0, len(rms), pts + 1).astype(int)
        rms = np.array([rms[a:b].max() if b > a else 0 for a, b in zip(idx[:-1], idx[1:])])
    peak = float(rms.max()) or 1.0
    wave = [round(float(v) / peak, 3) for v in rms]

    smax = float(strength.max()) if len(strength) else 1.0
    beats = [{"t": round(float(t), 3), "s": round(float(s) / (smax or 1), 3), "bar": (i - phase) % 4 == 0}
             for i, (t, s) in enumerate(zip(beat_times, strength))]
    return {"path": path, "name": os.path.basename(path), "bpm": round(bpm, 1), "duration": round(duration, 2),
            "beats": beats, "wave": wave}


def select_beats(beats: list[dict], mode: str, offset: float = 0.0) -> list[float]:
    if mode == "bar":
        chosen = [b for b in beats if b["bar"]]
    elif mode == "half":
        chosen = beats[::2]
    elif mode == "strong":
        chosen = [b for b in beats if b["s"] >= 0.6]
    else:
        chosen = beats
    return [round(max(0.0, b["t"] + offset), 3) for b in chosen]


# --------------------------------------------------------------------------- #
# Exports
# --------------------------------------------------------------------------- #

def _tc(frames: int, fps: int) -> str:
    h, rem = divmod(frames, 3600 * fps)
    m, rem = divmod(rem, 60 * fps)
    s, f = divmod(rem, fps)
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def premiere_xml(audio_path: str, times: list[float], duration: float, fps: int, out_path: Path) -> Path:
    """FCP7 XML: a new sequence with the song on A1 and a marker on every chosen beat."""
    name = Path(audio_path).stem
    dur = max(1, int(round(duration * fps)))
    url = "file://localhost/" + quote(audio_path.replace("\\", "/"), safe="/")
    markers = "\n".join(
        f"""      <marker><comment></comment><name>Beat {i + 1}</name><in>{int(round(t * fps))}</in><out>-1</out></marker>"""
        for i, t in enumerate(times))
    rate = f"<rate><timebase>{fps}</timebase><ntsc>FALSE</ntsc></rate>"
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xmeml>
<xmeml version="4">
  <sequence id="seq-usbdeck">
    <name>{_esc(name)} - Beat Markers</name>
    <duration>{dur}</duration>
    {rate}
    <timecode>{rate}<string>00:00:00:00</string><frame>0</frame><displayformat>NDF</displayformat></timecode>
{markers}
    <media>
      <video><format><samplecharacteristics>{rate}<width>1920</width><height>1080</height></samplecharacteristics></format></video>
      <audio>
        <numOutputChannels>2</numOutputChannels>
        <track>
          <clipitem id="clip-1">
            <name>{_esc(Path(audio_path).name)}</name>
            <duration>{dur}</duration>
            {rate}
            <start>0</start><end>{dur}</end><in>0</in><out>{dur}</out>
            <file id="file-1">
              <name>{_esc(Path(audio_path).name)}</name>
              <pathurl>{url}</pathurl>
              {rate}
              <duration>{dur}</duration>
              <media><audio><samplecharacteristics><depth>16</depth><samplerate>48000</samplerate></samplecharacteristics><channelcount>2</channelcount></audio></media>
            </file>
            <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>
          </clipitem>
        </track>
      </audio>
    </media>
  </sequence>
</xmeml>
"""
    out_path.write_text(xml, encoding="utf-8")
    return out_path


def resolve_edl(times: list[float], fps: int, start_hours: int, out_path: Path) -> Path:
    """EDL with markers - DaVinci Resolve: Timeline > Import > Timeline Markers from EDL."""
    lines = ["TITLE: USB Deck Beat Markers", "FCM: NON-DROP FRAME", ""]
    base = start_hours * 3600 * fps
    for i, t in enumerate(times, 1):
        f = base + int(round(t * fps))
        a, b = _tc(f, fps), _tc(f + 1, fps)
        lines.append(f"{i:03d}  001      V     C        {a} {b} {a} {b}  ")
        lines.append(f" |C:ResolveColorBlue |M:Beat {i} |D:1")
        lines.append("")
    out_path.write_text("\r\n".join(lines), encoding="utf-8")
    return out_path


def ae_marker_script(times: list[float], template: Path) -> Path:
    code = template.read_text(encoding="utf-8").replace("__TIMES__", json.dumps(times))
    tmp = Path(tempfile.gettempdir()) / "usbdeck_beats.jsx"
    tmp.write_text(code, encoding="utf-8")
    return tmp
