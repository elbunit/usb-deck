#!/usr/bin/env python3
"""
USB Deck - agjenti per Windows
==============================

Lidh iPad-in me PC-ne VETEM me kabllo USB (pa WiFi) dhe kthen butonat e
iPad-it ne shortcut-e, makro, skripte After Effects etj.

Si funksionon lidhja:
  * Apple instalon ne Windows sherbimin "Apple Mobile Device Service"
    (vjen me iTunes ose me aplikacionin "Apple Devices").
  * Ky sherbim (usbmuxd) degjon ne 127.0.0.1:27015 dhe di te hape
    "tunele" TCP neper kabllo drejt nje porte ne iPad.
  * Aplikacioni USB Deck ne iPad degjon ne porten 2345; agjenti hap
    tunelin dhe te dy flasin JSON neper kabllo.

Perdorimi:
  python agent.py              # normal
  python agent.py --no-browser # mos hap editorin automatikisht
  python agent.py --tcp 127.0.0.1:2345   # (testim) lidhje TCP direkte, p.sh. me iproxy
"""

from __future__ import annotations

import argparse
import copy
import glob
import json
import os
import plistlib
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audio import AUDIO_COMMANDS, AudioService  # noqa: E402
from render_watch import RenderWatcher  # noqa: E402
from extras import DEFAULT_TC_START, FileReceiver, read_clipboard, timecode_steps  # noqa: E402
from features import (BrandStore, DEFAULT_TEMPLATE, ProjectIndex, TimeTracker, copy_to_clipboard,  # noqa: E402
                      create_project, hex_to_rgb01, list_logos, logos_dir, open_path, send_document,
                      take_screenshot)
from launcher import AppCatalog, launch, running_exes  # noqa: E402
from screen import ScreenStreamer  # noqa: E402
from media import MediaService  # noqa: E402
from ai import MODELS as AI_MODELS, Assistant  # noqa: E402
import beats as beatmod  # noqa: E402
from ppro import PremiereBridge, install_panel  # noqa: E402
from scopes import ScopesService  # noqa: E402

VERSION = "1.8.0"
IPAD_PORT = 2345
USBMUXD_ADDR = ("127.0.0.1", 27015)

HERE = Path(__file__).resolve().parent
CONFIG_FILE = HERE / "profiles.json"
DEFAULT_CONFIG_FILE = HERE / "default_profiles.json"
BRANDS_FILE = HERE / "brands.json"
TIMELOG_FILE = HERE / "timelog.json"
EXPRESSIONS_FILE = HERE / "expressions.json"
APPS_CACHE_FILE = HERE / "apps_cache.json"
BACKUP_DIR = HERE / "backups"
AE_SCRIPTS_DIR = HERE / "ae-scripts"
WEB_DIR = HERE / "web"

IS_WINDOWS = os.name == "nt"

if IS_WINDOWS:
    # Real pixel coordinates on scaled (125% / 150%) displays - sharp, full-size screenshots.
    try:
        import ctypes as _ct
        _ct.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        pass

try:
    sys.stdout.reconfigure(errors="replace")  # type: ignore[attr-defined]
except Exception:
    pass


# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #

_log_lock = threading.Lock()
_last_status = None


def log(msg: str) -> None:
    with _log_lock:
        print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def status(msg: str) -> None:
    """Log a status line only when it changes (avoids spamming the console)."""
    global _last_status
    if msg != _last_status:
        _last_status = msg
        log(msg)


# --------------------------------------------------------------------------- #
# Keyboard output
# --------------------------------------------------------------------------- #

try:
    import keyboard as _kb  # type: ignore
except Exception:  # pragma: no cover - missing lib or no permission
    _kb = None


class KeySender:
    """Sends keystrokes to the focused app. Falls back to printing (dry run)."""

    def __init__(self) -> None:
        self.dry = _kb is None
        if self.dry:
            log("KUJDES: libraria 'keyboard' mungon - po punoj ne 'dry-run' (vetem shfaq tastet).")
            log("        Instaloje me:  python -m pip install keyboard")

    def tap(self, combo: str) -> None:
        combo = combo.strip()
        if not combo:
            return
        if self.dry:
            log(f"  [taste] {combo}")
            return
        _kb.send(combo)

    def press(self, combo: str) -> None:
        if self.dry:
            log(f"  [mbaj] {combo}")
            return
        _kb.press(combo)

    def release(self, combo: str) -> None:
        if self.dry:
            log(f"  [lësho] {combo}")
            return
        try:
            _kb.release(combo)
        except Exception:
            pass

    def write(self, text: str) -> None:
        if self.dry:
            log(f"  [tekst] {text!r}")
            return
        _kb.write(text, delay=0.003)


KEYS = KeySender()


# --------------------------------------------------------------------------- #
# Foreground app detection (Windows)
# --------------------------------------------------------------------------- #

def foreground_exe() -> str | None:
    if not IS_WINDOWS:
        return None
    try:
        import ctypes
        import ctypes.wintypes as wt

        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        hwnd = user32.GetForegroundWindow()
        if not hwnd:
            return None
        pid = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        handle = kernel32.OpenProcess(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return None
        try:
            buf = ctypes.create_unicode_buffer(1024)
            size = wt.DWORD(1024)
            if kernel32.QueryFullProcessImageNameW(handle, 0, buf, ctypes.byref(size)):
                return os.path.basename(buf.value).lower()
        finally:
            kernel32.CloseHandle(handle)
    except Exception:
        return None
    return None


def process_running(exe_name: str) -> bool:
    if not IS_WINDOWS:
        return True
    try:
        out = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {exe_name}", "/NH"],
            capture_output=True, text=True, timeout=5,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        ).stdout.lower()
        return exe_name.lower() in out
    except Exception:
        return True


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #

def _new_id(prefix: str = "b") -> str:
    return f"{prefix}_{uuid.uuid4().hex[:8]}"


class ConfigError(ValueError):
    pass


def normalize_config(cfg: dict) -> dict:
    """Validate + fill in defaults. Raises ConfigError with a readable message."""
    if not isinstance(cfg, dict):
        raise ConfigError("Konfigurimi duhet te jete nje objekt JSON.")
    cfg = copy.deepcopy(cfg)
    settings = cfg.setdefault("settings", {})
    grid = settings.setdefault("grid", {"rows": 4, "cols": 5})
    grid["rows"] = max(1, min(int(grid.get("rows", 4)), 8))
    grid["cols"] = max(1, min(int(grid.get("cols", 5)), 10))
    settings.setdefault("editor_port", 8790)
    settings.setdefault("after_effects_path", "")
    settings.setdefault("repeat_delay", 0.35)
    settings.setdefault("repeat_rate", 0.045)
    settings.setdefault("transfer_folder", "%USERPROFILE%\\Desktop\\Nga iPad-i")
    tc = settings.setdefault("timecode_start_hours", dict(DEFAULT_TC_START))
    if not isinstance(tc, dict):
        raise ConfigError("'timecode_start_hours' duhet te jete objekt.")
    settings["timecode_start_hours"] = {str(k).lower(): max(0, min(int(v or 0), 23)) for k, v in tc.items()}
    settings.setdefault("project_folders", ["%USERPROFILE%\\Documents", "%USERPROFILE%\\Desktop"])
    settings.setdefault("projects_root", "%USERPROFILE%\\Desktop\\Projekte")
    settings.setdefault("project_template", list(DEFAULT_TEMPLATE))
    settings.setdefault("project_template_files", [])
    settings.setdefault("backup_enabled", True)
    settings.setdefault("backup_folder", "%USERPROFILE%\\Documents\\USB Deck Backups")
    settings.setdefault("backup_keep", 30)
    settings.setdefault("backup_interval_minutes", 2)
    settings.setdefault("time_tracking", True)
    settings.setdefault("idle_minutes", 5)
    for key in ("project_folders", "project_template", "project_template_files"):
        if not isinstance(settings.get(key), list):
            raise ConfigError(f"'{key}' duhet te jete liste.")
        settings[key] = [str(x).strip() for x in settings[key] if str(x).strip()]
    settings.setdefault("ppro_export_folder", "")
    settings.setdefault("logos_folder", "%USERPROFILE%\\Documents\\USB Deck Logos")
    settings.setdefault("scopes_fps", 10)
    settings.setdefault("ai_model", "gemma3:4b")
    settings.setdefault("beats_fps", 25)
    settings.setdefault("screen_fps", 20)
    settings.setdefault("screen_quality", 70)
    settings.setdefault("screen_max_width", 1600)
    settings.setdefault("screen_touch", True)
    if "launchers" in settings and not isinstance(settings["launchers"], list):
        raise ConfigError("'launchers' duhet te jete liste.")
    settings.setdefault("screenshot_ask", True)
    settings.setdefault("screenshot_folder", "%USERPROFILE%\\Pictures\\USB Deck Screenshots")
    settings.setdefault("render_notify", True)
    settings.setdefault("render_sound", True)
    folders = settings.setdefault("render_folders", ["%USERPROFILE%\\Videos"])
    if not isinstance(folders, list):
        raise ConfigError("'render_folders' duhet te jete liste.")
    settings["render_folders"] = [str(f).strip() for f in folders if str(f).strip()]

    profiles = cfg.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        raise ConfigError("Duhet te pakten nje profil.")

    seen_profiles = set()
    for p in profiles:
        if not isinstance(p, dict):
            raise ConfigError("Cdo profil duhet te jete objekt.")
        pid = str(p.get("id") or "").strip() or _new_id("p")
        if pid in seen_profiles:
            raise ConfigError(f"ID e profilit perseritet: {pid}")
        seen_profiles.add(pid)
        p["id"] = pid
        p["name"] = str(p.get("name") or pid)
        p["apps"] = [str(a).strip().lower() for a in p.get("apps", []) if str(a).strip()]
        if p.get("grid"):
            g = p["grid"]
            p["grid"] = {"rows": max(1, min(int(g.get("rows", grid["rows"])), 8)),
                         "cols": max(1, min(int(g.get("cols", grid["cols"])), 10))}
        pages = p.get("pages") or []
        if not isinstance(pages, list):
            raise ConfigError(f"Profili {p['name']}: 'pages' duhet te jete liste.")
        seen_buttons = set()
        for pg in pages:
            pg["name"] = str(pg.get("name") or "Faqja")
            buttons = pg.get("buttons") or []
            clean = []
            for b in buttons:
                if not b:
                    clean.append(None)
                    continue
                bid = str(b.get("id") or "").strip()
                if not bid or bid in seen_buttons:
                    bid = _new_id()
                seen_buttons.add(bid)
                b["id"] = bid
                b["label"] = str(b.get("label") or "")
                mode = b.get("mode") or "tap"
                b["mode"] = mode if mode in ("tap", "hold", "repeat") else "tap"
                acts = b.get("actions") or []
                if not isinstance(acts, list):
                    raise ConfigError(f"Butoni '{b['label']}': 'actions' duhet te jete liste.")
                b["actions"] = [a for a in acts if isinstance(a, dict)]
                clean.append(b)
            while clean and clean[-1] is None:
                clean.pop()
            pg["buttons"] = clean
        p["pages"] = pages
        jog = p.get("jog")
        if jog:
            jog.setdefault("modes", [])
            jog.setdefault("transport", {})
    return cfg


def ipad_view(cfg: dict) -> dict:
    """What the iPad needs: labels, icons, colors - no key bindings."""
    out = {"grid": cfg["settings"]["grid"], "profiles": [],
           "transfer_folder": os.path.expandvars(str(cfg["settings"].get("transfer_folder", "")))}
    for p in cfg["profiles"]:
        jog = p.get("jog")
        jog_info = None
        if jog:
            modes = [{"id": str(m.get("id")), "label": str(m.get("label") or m.get("id"))}
                     for m in jog.get("modes", []) if m.get("id") and m.get("keys")]
            transport = [n for n in ("reverse", "stop", "forward") if (jog.get("transport") or {}).get(n)]
            if modes or transport:
                jog_info = {"modes": modes, "transport": transport}
        pages = []
        for pg in p.get("pages", []):
            buttons = []
            for b in pg.get("buttons", []):
                if not b:
                    buttons.append(None)
                else:
                    buttons.append({
                        "id": b["id"], "label": b.get("label", ""),
                        "symbol": b.get("symbol") or None, "color": b.get("color") or None,
                        "mode": b.get("mode", "tap"),
                    })
            pages.append({"name": pg.get("name", "Faqja"), "buttons": buttons})
        out["profiles"].append({
            "id": p["id"], "name": p["name"], "color": p.get("color") or None,
            "symbol": p.get("symbol") or None, "grid": p.get("grid") or None,
            "pages": pages, "jog": jog_info, "ease": bool(p.get("ease")),
        })
    return out


class ConfigStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.RLock()
        self.mtime = 0.0
        self.cfg: dict = {}
        if not path.exists():
            if DEFAULT_CONFIG_FILE.exists():
                shutil.copyfile(DEFAULT_CONFIG_FILE, path)
            else:
                raise SystemExit("Mungon profiles.json dhe default_profiles.json")
        self.reload(force=True)

    def reload(self, force: bool = False) -> bool:
        with self.lock:
            try:
                m = self.path.stat().st_mtime
            except OSError:
                return False
            if not force and m == self.mtime:
                return False
            self.mtime = m
            try:
                raw = json.loads(self.path.read_text(encoding="utf-8"))
                self.cfg = normalize_config(raw)
                count = sum(1 for p in self.cfg["profiles"] for pg in p["pages"] for b in pg["buttons"] if b)
                log(f"Profilet u ngarkuan: {len(self.cfg['profiles'])} profile, {count} butona.")
                return True
            except (json.JSONDecodeError, ConfigError, ValueError, TypeError) as e:
                log(f"GABIM ne profiles.json: {e}  (po mbaj versionin e meparshem)")
                if not self.cfg:
                    raise SystemExit(1)
                return False

    def save(self, raw: dict) -> dict:
        cfg = normalize_config(raw)
        with self.lock:
            BACKUP_DIR.mkdir(exist_ok=True)
            if self.path.exists():
                stamp = time.strftime("%Y%m%d-%H%M%S")
                shutil.copyfile(self.path, BACKUP_DIR / f"profiles-{stamp}.json")
                backups = sorted(BACKUP_DIR.glob("profiles-*.json"))
                for old in backups[:-30]:
                    old.unlink(missing_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
            os.replace(tmp, self.path)
            self.mtime = self.path.stat().st_mtime
            self.cfg = cfg
        log("Profilet u ruajten nga editori.")
        return cfg

    def get(self) -> dict:
        with self.lock:
            return self.cfg

    def profile(self, pid: str) -> dict | None:
        for p in self.get()["profiles"]:
            if p["id"] == pid:
                return p
        return None

    def button(self, pid: str, bid: str) -> dict | None:
        p = self.profile(pid)
        if not p:
            return None
        for pg in p["pages"]:
            for b in pg["buttons"]:
                if b and b["id"] == bid:
                    return b
        return None

    def profile_for_exe(self, exe: str | None) -> dict | None:
        if not exe:
            return None
        for p in self.get()["profiles"]:
            if exe in p.get("apps", []):
                return p
        return None


# --------------------------------------------------------------------------- #
# usbmux (Apple Mobile Device Service) client
# --------------------------------------------------------------------------- #

class MuxUnavailable(Exception):
    pass


class MuxRefused(Exception):
    pass


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("lidhja u mbyll")
        buf.extend(chunk)
    return bytes(buf)


class UsbMux:
    RESULT_TEXT = {1: "BadCommand", 2: "BadDevice", 3: "ConnectionRefused", 6: "BadVersion"}

    def __init__(self) -> None:
        self.tag = 0

    def _open(self) -> socket.socket:
        try:
            return socket.create_connection(USBMUXD_ADDR, timeout=3)
        except OSError as e:
            raise MuxUnavailable(str(e)) from e

    def _send(self, s: socket.socket, payload: dict) -> None:
        self.tag += 1
        payload.setdefault("ClientVersionString", f"usbdeck-{VERSION}")
        payload.setdefault("ProgName", "usbdeck")
        body = plistlib.dumps(payload)
        s.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, self.tag) + body)

    def _recv(self, s: socket.socket) -> dict:
        length, _version, _msg, _tag = struct.unpack("<IIII", _recv_exact(s, 16))
        return plistlib.loads(_recv_exact(s, length - 16))

    def usb_devices(self) -> list[dict]:
        s = self._open()
        try:
            self._send(s, {"MessageType": "ListDevices"})
            reply = self._recv(s)
        finally:
            s.close()
        devices = []
        for d in reply.get("DeviceList", []):
            props = d.get("Properties", {})
            if props.get("ConnectionType", "USB") == "USB":   # cable only - never Wi-Fi
                devices.append({"id": d.get("DeviceID", props.get("DeviceID")),
                                "serial": props.get("SerialNumber", "")})
        return devices

    def connect(self, device_id: int, port: int) -> socket.socket:
        s = self._open()
        try:
            self._send(s, {"MessageType": "Connect", "DeviceID": device_id,
                           "PortNumber": ((port & 0xFF) << 8) | (port >> 8)})
            reply = self._recv(s)
        except Exception:
            s.close()
            raise
        number = reply.get("Number", -1)
        if number != 0:
            s.close()
            raise MuxRefused(self.RESULT_TEXT.get(number, str(number)))
        s.settimeout(None)
        return s


# --------------------------------------------------------------------------- #
# Link to the iPad
# --------------------------------------------------------------------------- #

class IPadLink:
    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self.lock = threading.Lock()
        self.device = ""

    @property
    def connected(self) -> bool:
        return self.sock is not None

    def attach(self, sock: socket.socket, device: str) -> None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        self.device = device

    def close(self) -> None:
        s, self.sock = self.sock, None
        if s:
            try:
                s.close()
            except OSError:
                pass

    def send(self, obj: dict) -> bool:
        s = self.sock
        if not s:
            return False
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        try:
            with self.lock:
                s.sendall(struct.pack(">I", len(data)) + data)
            return True
        except OSError:
            self.close()
            return False

    def send_binary(self, kind: int, payload: bytes) -> bool:
        """Binary frame: body starts with 0x00 (JSON never does), then a kind byte."""
        s = self.sock
        if not s:
            return False
        body = b"\x00" + bytes([kind]) + payload
        try:
            with self.lock:
                s.sendall(struct.pack(">I", len(body)) + body)
            return True
        except OSError:
            self.close()
            return False

    @staticmethod
    def read(sock: socket.socket) -> dict:
        (n,) = struct.unpack(">I", _recv_exact(sock, 4))
        if n > 4_000_000:
            raise ConnectionError("mesazh shume i madh")
        return json.loads(_recv_exact(sock, n).decode("utf-8"))


# --------------------------------------------------------------------------- #
# After Effects bridge
# --------------------------------------------------------------------------- #

class AfterEffects:
    def __init__(self, store: ConfigStore) -> None:
        self.store = store

    def exe_path(self) -> str | None:
        custom = (self.store.get()["settings"].get("after_effects_path") or "").strip()
        if custom and os.path.isfile(custom):
            return custom
        patterns = [
            r"C:\Program Files\Adobe\Adobe After Effects*\Support Files\AfterFX.exe",
            r"D:\Program Files\Adobe\Adobe After Effects*\Support Files\AfterFX.exe",
        ]
        found: list[str] = []
        for pat in patterns:
            found.extend(glob.glob(pat))
        if not found:
            return None
        found.sort(reverse=True)  # "2025" > "2024" > "(Beta)"
        return found[0]

    def scripts(self) -> list[str]:
        if not AE_SCRIPTS_DIR.exists():
            return []
        return sorted(p.stem for p in AE_SCRIPTS_DIR.glob("*.jsx") if not p.stem.startswith("_"))

    def run_file(self, path: Path) -> str:
        exe = self.exe_path()
        if not exe:
            return "Nuk u gjet After Effects (vendose shtegun te Cilësimet)."
        if not process_running(os.path.basename(exe)):
            return "Hap After Effects fillimisht."
        subprocess.Popen([exe, "-r", str(path)],
                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        return ""

    def run_named(self, name: str) -> str:
        path = AE_SCRIPTS_DIR / f"{name}.jsx"
        if not path.exists():
            return f"Skripti '{name}' nuk ekziston."
        return self.run_file(path)

    def run_template(self, template: str, replacements: dict, tmp_name: str) -> str:
        code = (AE_SCRIPTS_DIR / template).read_text(encoding="utf-8")
        for k, v in replacements.items():
            code = code.replace(k, v)
        tmp = Path(tempfile.gettempdir()) / tmp_name
        tmp.write_text(code, encoding="utf-8")
        return self.run_file(tmp)

    def apply_expression(self, expr: str, needs_keys: bool) -> str:
        return self.run_template("_expr_template.jsx", {"__EXPR__": json.dumps(expr),
                                 "__NEEDS_KEYS__": "true" if needs_keys else "false"}, "usbdeck_expr.jsx")

    def apply_color(self, hx: str) -> str:
        return self.run_template("_color_template.jsx", {"__COLOR__": json.dumps(hex_to_rgb01(hx))}, "usbdeck_color.jsx")

    def apply_ease(self, curve: list[float]) -> str:
        template = (AE_SCRIPTS_DIR / "_ease_template.jsx").read_text(encoding="utf-8")
        values = [float(v) for v in curve[:4]]
        code = template.replace("__CURVE__", json.dumps(values))
        tmp = Path(tempfile.gettempdir()) / "usbdeck_ease.jsx"
        tmp.write_text(code, encoding="utf-8")
        return self.run_file(tmp)


# --------------------------------------------------------------------------- #
# Action engine
# --------------------------------------------------------------------------- #

class Engine:
    def __init__(self, store: ConfigStore, link: IPadLink) -> None:
        self.store = store
        self.link = link
        self.ae = AfterEffects(store)
        self.jobs: queue.Queue = queue.Queue()
        self.held: dict[str, str] = {}                   # button key -> combo held down
        self.repeating: dict[str, threading.Event] = {}  # button key -> stop flag
        self.state_lock = threading.Lock()
        self.audio: AudioService | None = None
        threading.Thread(target=self._worker, daemon=True, name="actions").start()

    # -- worker (keeps keystrokes in order) --
    def _worker(self) -> None:
        while True:
            fn = self.jobs.get()
            try:
                fn()
            except Exception as e:  # never let one bad action kill the agent
                log(f"Gabim gjate veprimit: {e}")

    def toast(self, text: str) -> None:
        if text:
            self.link.send({"type": "toast", "text": text})

    # -- steps --
    def run_steps(self, steps: list[dict]) -> None:
        for st in steps:
            if "keys" in st:
                KEYS.tap(str(st["keys"]))
            elif "text" in st:
                KEYS.write(str(st["text"]))
            elif "wait" in st:
                time.sleep(max(0.0, min(float(st["wait"]), 10.0)))
            elif "run" in st:
                subprocess.Popen(str(st["run"]), shell=True)
            elif "open" in st:
                target = os.path.expandvars(str(st["open"]))
                if IS_WINDOWS:
                    os.startfile(target)  # type: ignore[attr-defined]
                else:
                    webbrowser.open(target)
            elif "ae" in st:
                err = self.ae.run_named(str(st["ae"]))
                self.toast(err or "U dërgua te After Effects")
            elif "audio" in st:
                self.audio_command(str(st["audio"]))
            elif "screenshot" in st:
                self.screenshot()

    # -- events from the iPad --
    def button(self, pid: str, bid: str, down: bool) -> None:
        b = self.store.button(pid, bid)
        if not b:
            return
        key = f"{pid}/{bid}"
        mode = b.get("mode", "tap")
        actions = b.get("actions", [])
        if mode == "tap":
            if down:
                self.jobs.put(lambda: self.run_steps(actions))
        elif mode == "hold":
            combo = next((str(a["keys"]) for a in actions if "keys" in a), "")
            if not combo:
                return
            with self.state_lock:
                if down and key not in self.held:
                    self.held[key] = combo
                    self.jobs.put(lambda: KEYS.press(combo))
                elif not down and key in self.held:
                    c = self.held.pop(key)
                    self.jobs.put(lambda: KEYS.release(c))
        elif mode == "repeat":
            with self.state_lock:
                if down and key not in self.repeating:
                    stop = threading.Event()
                    self.repeating[key] = stop
                    threading.Thread(target=self._repeat, args=(actions, stop), daemon=True).start()
                elif not down and key in self.repeating:
                    self.repeating.pop(key).set()

    def _repeat(self, actions: list[dict], stop: threading.Event) -> None:
        s = self.store.get()["settings"]
        delay, rate = float(s.get("repeat_delay", 0.35)), float(s.get("repeat_rate", 0.045))
        self.jobs.put(lambda: self.run_steps(actions))
        if stop.wait(delay):
            return
        while not stop.is_set():
            if self.jobs.qsize() < 3:      # don't pile up if the app is slow
                self.jobs.put(lambda: self.run_steps(actions))
            stop.wait(rate)

    def jog(self, pid: str, mode: str, steps: int) -> None:
        p = self.store.profile(pid)
        if not p or not p.get("jog"):
            return
        m = next((m for m in p["jog"].get("modes", []) if m.get("id") == mode), None)
        if not m or len(m.get("keys", [])) < 2:
            return
        combo = m["keys"][1] if steps > 0 else m["keys"][0]
        count = min(abs(int(steps)), 24)

        def go() -> None:
            for _ in range(count):
                KEYS.tap(combo)
        self.jobs.put(go)

    def transport(self, pid: str, name: str) -> None:
        p = self.store.profile(pid)
        combo = ((p or {}).get("jog") or {}).get("transport", {}).get(name)
        if combo:
            self.jobs.put(lambda: KEYS.tap(str(combo)))

    def ease(self, curve: list) -> None:
        if not isinstance(curve, list) or len(curve) != 4:
            return

        def go() -> None:
            err = self.ae.apply_ease(curve)
            self.toast(err or "Easing u aplikua te keyframe-t e zgjedhura")
        self.jobs.put(go)

    def screenshot(self) -> None:
        # Own thread: the "Save As" dialog may stay open while other buttons keep working.
        def go() -> None:
            s = self.store.get()["settings"]
            ask = bool(s.get("screenshot_ask", True))
            if ask:
                self.toast("📸 Zgjidh ku ta ruash në PC…")
            path, message = take_screenshot(s.get("screenshot_folder", ""), ask)
            if path:
                log(f"Screenshot: {path}")
            self.toast(message)
        threading.Thread(target=go, daemon=True, name="screenshot").start()

    def audio_command(self, cmd: str) -> None:
        if not self.audio:
            return
        if cmd == "mic_toggle":
            self.audio.submit("set_mute", "mic", "", None)
            def after() -> None:
                time.sleep(0.5)
                mic = (self.audio.state or {}).get("mic") or {}
                self.toast("🎙 Mikrofoni: FIKUR" if mic.get("muted") else "🎙 Mikrofoni: NDEZUR")
            threading.Thread(target=after, daemon=True).start()
        elif cmd == "master_mute":
            self.audio.submit("set_mute", "master", "", None)
        elif cmd == "output_next":
            self.audio.submit("next_output", reply=lambda name: self.toast(f"🔊 Zëri tani: {name}" if name else "Vetëm një pajisje zëri"))

    def release_all(self) -> None:
        with self.state_lock:
            for stop in self.repeating.values():
                stop.set()
            self.repeating.clear()
            held = list(self.held.values())
            self.held.clear()
        for combo in held:
            KEYS.release(combo)

    def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "button":
            self.button(str(msg.get("profile")), str(msg.get("button")), msg.get("event") == "down")
        elif t == "jog":
            self.jog(str(msg.get("profile")), str(msg.get("mode")), int(msg.get("steps", 0)))
        elif t == "transport":
            self.transport(str(msg.get("profile")), str(msg.get("name")))
        elif t == "ease":
            self.ease(msg.get("curve"))
        elif t == "volume" and self.audio:
            self.audio.submit("set_volume", str(msg.get("target", "app")), str(msg.get("key", "")),
                              float(msg.get("value", 0)))
        elif t == "mute" and self.audio:
            self.audio.submit("set_mute", str(msg.get("target", "app")), str(msg.get("key", "")), None)
        elif t == "output" and self.audio:
            self.audio.submit("set_output", str(msg.get("id", "")))
        elif t == "screenshot":
            self.screenshot()
        elif t == "reveal":
            path = str(msg.get("path", ""))
            if IS_WINDOWS and os.path.exists(path):
                subprocess.Popen(f'explorer /select,"{path}"')
        elif t == "hello":
            log("iPad-i u prezantua (aplikacioni USB Deck).")


# --------------------------------------------------------------------------- #
# Agent (ties everything together)
# --------------------------------------------------------------------------- #

class Agent:
    def __init__(self, tcp: tuple[str, int] | None) -> None:
        self.tcp = tcp
        self.store = ConfigStore(CONFIG_FILE)
        self.link = IPadLink()
        self.engine = Engine(self.store, self.link)
        self.mux = UsbMux()
        self.foreground: str | None = None
        self.recent_apps: list[str] = []
        self.active_profile: str | None = None
        self.stop = threading.Event()
        self.audio = AudioService(on_change=self.on_audio, log=log)
        self.engine.audio = self.audio
        self.renders: dict[str, dict] = {}   # path -> "started" event, while rendering
        self.render_watch = RenderWatcher(lambda: self.store.get()["settings"], self.on_render, log)
        self.receiver = FileReceiver(lambda: self.store.get()["settings"].get("transfer_folder"))
        self.brands = BrandStore(BRANDS_FILE)
        self.projects = ProjectIndex(lambda: self.store.get()["settings"], log, self.on_backup)
        self.timer = TimeTracker(TIMELOG_FILE, lambda: self.store.get()["settings"], lambda: self.foreground, log)
        try:
            self.expressions = json.loads(EXPRESSIONS_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.expressions = []
        self.screen = ScreenStreamer(self.link, lambda: self.store.get()["settings"], log)
        self.apps = AppCatalog(APPS_CACHE_FILE, log)
        self.ppro = PremiereBridge(self.link.send, lambda: self.store.get()["settings"], log)
        self.scopes = ScopesService(self.link, lambda: self.store.get()["settings"], self.save_scopes_region, log)
        self.ai = Assistant(self.link.send, lambda: self.store.get()["settings"], log)
        self.beat_result: dict | None = None
        self.media = MediaService(lambda st: self.link.send({"type": "media", **st}),
                                  lambda pos: self.link.send(pos), log)

    def launchers(self) -> list[dict]:
        items = self.store.get()["settings"].get("launchers")
        if not isinstance(items, list):
            items = self.apps.defaults()
        return items

    def push_launchers(self) -> None:
        running = running_exes()
        out = []
        for i, it in enumerate(self.launchers()):
            exe = str(it.get("exe") or "").lower()
            path = os.path.expandvars(str(it.get("path") or ""))
            out.append({"index": i, "name": it.get("name") or os.path.basename(path),
                        "icon": self.apps.icon_for(exe) if exe else "",
                        "folder": os.path.isdir(path), "running": bool(exe and exe in running)})
        self.link.send({"type": "launchers", "items": out, "scanning": not self.apps.ready.is_set()})

    def place_logo(self, path: str, timeline: bool) -> None:
        if not os.path.isfile(path):
            self.engine.toast("Logo nuk u gjet")
            return
        fg = self.foreground
        if fg == "afterfx.exe" or (fg != "adobe premiere pro.exe" and not self.ppro.connected
                                    and process_running("AfterFX.exe")):
            def go() -> None:
                err = self.engine.ae.run_template("_import_template.jsx", {"__PATH__": json.dumps(path)},
                                                  "usbdeck_import.jsx")
                self.engine.toast(err or "✓ Logo u vendos në After Effects")
            self.engine.jobs.put(go)
        elif self.ppro.connected:
            self.ppro.queue({"cmd": "import", "path": path, "bin": "Logot", "timeline": timeline})
        else:
            open_path(path, select=True)
            self.engine.toast("Hap Premiere (me panelin USB Deck) ose After Effects – tani u hap dosja")

    def save_scopes_region(self, region: list) -> None:
        cfg = copy.deepcopy(self.store.get())
        cfg["settings"]["scopes_region"] = region
        self.store.save(cfg)

    def beats_status(self, state: str, text: str = "") -> None:
        self.link.send({"type": "beats_status", "state": state, "text": text})

    def handle_beats(self, msg: dict) -> None:
        if msg.get("type") == "beats_pick":
            if not beatmod.librosa_available():
                self.beats_status("installing", "Po instaloj veglën e analizës (vetëm herën e parë, 1–3 min)…")
                if not beatmod.install_librosa(log):
                    self.beats_status("idle", "Instalimi dështoi – shih dritaren e agjentit.")
                    return
            self.beats_status("picking", "Zgjidh këngën në PC…")
            last_dir = os.path.dirname(self.beat_result["path"]) if self.beat_result else ""
            path = beatmod.ask_audio_file(last_dir)
            if path is None:
                self.beats_status("idle", "Dritarja e zgjedhjes s'u hap (mungon tcl/tk në Python).")
                return
            if not path:
                self.beats_status("idle", "")
                return
            self.beats_status("analyzing", f"Duke analizuar {os.path.basename(path)}…")
            try:
                self.beat_result = beatmod.analyze(path)
            except Exception as e:
                self.beats_status("idle", f"Analiza dështoi: {e}")
                return
            log(f"Ritmi: {self.beat_result['name']} · {self.beat_result['bpm']} BPM · {len(self.beat_result['beats'])} beat")
            self.link.send({"type": "beats_result", **self.beat_result})
            self.beats_status("idle", "")
            return

        # export
        r = self.beat_result
        if not r:
            self.engine.toast("Zgjidh fillimisht një këngë")
            return
        s = self.store.get()["settings"]
        fps = int(msg.get("fps") or s.get("beats_fps", 25))
        times = beatmod.select_beats(r["beats"], str(msg.get("mode", "all")), float(msg.get("offset", 0)))
        target = msg.get("target")
        src = Path(r["path"])
        try:
            if target == "premiere":
                out = beatmod.premiere_xml(str(src), times, r["duration"], fps, src.with_name(f"{src.stem} - beats.xml"))
                open_path(out, select=True)
                self.engine.toast(f"✓ {len(times)} markera · në Premiere: File › Import › {out.name}")
            elif target == "resolve":
                hours = int(s.get("timecode_start_hours", {}).get("resolve.exe", 1))
                out = beatmod.resolve_edl(times, fps, hours, src.with_name(f"{src.stem} - beats.edl"))
                open_path(out, select=True)
                self.engine.toast(f"✓ {len(times)} markera · Resolve: Timeline › Import › Timeline Markers from EDL")
            elif target == "ae":
                script = beatmod.ae_marker_script(times, AE_SCRIPTS_DIR / "_beats_template.jsx")
                err = self.engine.ae.run_file(script)
                self.engine.toast(err or f"✓ {len(times)} markera te layer-i i zgjedhur në AE")
        except OSError as e:
            self.engine.toast(f"Eksporti dështoi: {e}")

    def on_backup(self, name: str) -> None:
        self.link.send({"type": "backup", "name": name, "time": time.strftime("%H:%M")})

    def push_projects(self) -> None:
        s = self.store.get()["settings"]
        self.link.send({"type": "projects", "recent": self.projects.recent(),
                        "root": os.path.expandvars(s.get("projects_root", "")),
                        "template": s.get("project_template", []),
                        "backup": bool(s.get("backup_enabled", True))})

    def push_extras(self) -> None:
        self.link.send({"type": "brands", "brands": self.brands.brands})
        self.link.send({"type": "expressions", "items": [
            {k: e.get(k) for k in ("id", "category", "name", "description", "code", "needs_keys")}
            for e in self.expressions]})
        self.push_projects()
        self.push_launchers()
        self.link.send({"type": "media", **self.media.full_state()})
        if self.beat_result:
            self.link.send({"type": "beats_result", **self.beat_result})
        threading.Thread(target=self.ai.push_status, daemon=True).start()
        threading.Thread(target=lambda: self.link.send(self.ppro.status()), daemon=True).start()
        if self.ppro.state:
            self.link.send({"type": "ppro_state", **self.ppro.state})

    # -- messages that need the agent (files, timecode) --
    def handle(self, msg: dict) -> None:
        t = msg.get("type")
        fid = str(msg.get("id", ""))
        try:
            if t == "file_begin":
                self.receiver.begin(fid, str(msg.get("name", "skedar")), int(msg.get("size", 0)))
                return
            if t == "file_chunk":
                self.receiver.chunk(fid, str(msg.get("data", "")))
                return
            if t == "file_end":
                info = self.receiver.end(fid)
                log(f"U mor nga iPad-i: {info['name']} ({info['bytes'] // 1024} KB)")
                self.link.send({"type": "file_saved", "id": fid, **info})
                return
            if t == "file_abort":
                self.receiver.abort(fid)
                return
        except Exception as e:
            self.receiver.abort(fid)
            log(f"Gabim gjate transferimit: {e}")
            self.link.send({"type": "file_error", "id": fid, "error": str(e)})
            return
        if t in ("logos_request", "logos_open"):
            brand = next((b for b in self.brands.brands if b["id"] == msg.get("brand")), None)
            if not brand:
                return
            folder = logos_dir(self.store.get()["settings"], brand["name"])
            if t == "logos_open":
                open_path(folder)
                self.engine.toast("📁 Dosja e logove u hap në PC – shto skedarët aty")
            threading.Thread(target=lambda: self.link.send(
                {"type": "logos", "brand": brand["id"], "folder": str(folder), "items": list_logos(folder)}),
                daemon=True).start()
            return
        if t == "logo_place":
            self.place_logo(str(msg.get("path", "")), bool(msg.get("timeline", False)))
            return
        if t == "ppro_status_request":
            threading.Thread(target=lambda: self.link.send(self.ppro.status()), daemon=True).start()
            return
        if t == "ppro_install":
            res = install_panel(HERE / "premiere-panel")
            self.engine.toast("✓ Paneli u instalua – rinis Premiere-n, pastaj Window › Extensions › USB Deck"
                              if res == "ok" else res)
            self.link.send(self.ppro.status())
            return
        if t == "ppro_goto":
            self.ppro.queue({"cmd": "goto", "seconds": float(msg.get("seconds", 0))})
            return
        if t == "ppro_marker":
            sec = msg.get("seconds")
            self.ppro.queue({"cmd": "add_marker", "name": str(msg.get("name", "")), "comment": str(msg.get("comment", "")),
                             "color": int(msg.get("color", 0)), "seconds": None if sec is None else float(sec)})
            return
        if t == "ppro_organize":
            self.ppro.queue({"cmd": "organize", "deep": bool(msg.get("deep", False))})
            return
        if t == "ppro_delete_marker":
            self.ppro.queue({"cmd": "delete_marker", "guid": str(msg.get("guid", ""))})
            return
        if t == "ppro_open_sequence":
            self.ppro.queue({"cmd": "open_sequence", "id": str(msg.get("id", ""))})
            return
        if t == "ppro_export":
            folder = self.ppro.export(str(msg.get("preset", "")), int(msg.get("range", 0)), bool(msg.get("start", True)))
            if folder and self.ppro.connected:
                self.render_watch.extra.add(folder)
            return
        if t == "scopes_start":
            self.scopes.start_stream(str(msg.get("source", "region")))
            self.link.send({"type": "scopes_sources", "items": self.scopes.sources(), "current": self.scopes.source})
            return
        if t == "scopes_stop":
            self.scopes.stop_stream()
            return
        if t == "scopes_ack":
            self.scopes.ack()
            return
        if t == "scopes_pick_region":
            threading.Thread(target=self.scopes.pick_region, daemon=True).start()
            return
        if t in ("beats_pick", "beats_export"):
            threading.Thread(target=self.handle_beats, args=(msg,), daemon=True, name="beats").start()
            return
        if t == "ai_status_request":
            threading.Thread(target=self.ai.push_status, daemon=True).start()
            return
        if t == "ai_start":
            self.engine.toast(self.ai.start_ollama())
            threading.Timer(4.0, self.ai.push_status).start()
            return
        if t == "ai_pull":
            self.ai.pull(str(msg.get("model") or self.store.get()["settings"].get("ai_model")))
            return
        if t == "ai_set_model":
            model = str(msg.get("model", ""))
            if any(m["id"] == model for m in AI_MODELS):
                cfg = copy.deepcopy(self.store.get())
                cfg["settings"]["ai_model"] = model
                self.store.save(cfg)
            threading.Thread(target=self.ai.push_status, daemon=True).start()
            return
        if t == "ai_chat":
            self.ai.chat(str(msg.get("id", "")), list(msg.get("messages") or []))
            return
        if t == "ai_stop":
            self.ai.stop()
            return
        if t == "pc_copy":
            ok = copy_to_clipboard(str(msg.get("text", "")))
            self.engine.toast("📋 U kopjua në PC (Ctrl+V)" if ok else "Kopjimi në PC dështoi")
            return
        if t == "media_cmd":
            self.media.command(str(msg.get("action", "")), msg.get("value"))
            return
        if t == "screen_ack":
            self.screen.ack()
            return
        if t == "screen_touch":
            self.screen.touch(float(msg.get("x", 0)), float(msg.get("y", 0)), str(msg.get("action", "move")))
            return
        if t == "screen_scroll":
            self.screen.scroll(float(msg.get("x", 0)), float(msg.get("y", 0)), float(msg.get("dy", 0)))
            return
        if t == "screen_start":
            self.screen.start_stream(str(msg.get("source", "m1")))
            self.link.send({"type": "screen_sources", "items": self.screen.sources(), "current": self.screen.source})
            return
        if t == "screen_stop":
            self.screen.stop_stream()
            return
        if t == "screen_sources":
            self.link.send({"type": "screen_sources", "items": self.screen.sources(), "current": self.screen.source})
            return
        if t == "launchers_request":
            self.push_launchers()
            return
        if t == "launch":
            items = self.launchers()
            i = int(msg.get("index", -1))
            if 0 <= i < len(items):
                item = items[i]
                self.engine.jobs.put(lambda: self.engine.toast(launch(item, log)))
                threading.Timer(2.5, self.push_launchers).start()
            return
        if t == "brands_save":
            try:
                self.brands.save(msg.get("brands"))
            except ValueError as e:
                self.engine.toast(f"Brendet nuk u ruajtën: {e}")
            self.link.send({"type": "brands", "brands": self.brands.brands})
            return
        if t == "color":
            hx = str(msg.get("hex", "")).upper()
            action = msg.get("action")
            if action == "copy":
                ok = copy_to_clipboard(hx)
                self.engine.toast(f"{hx} u kopjua në PC" if ok else f"{hx} (clipboard s'u arrit)")
            elif action == "ae":
                self.engine.jobs.put(lambda: self.engine.toast(self.engine.ae.apply_color(hx) or f"Ngjyra {hx} u aplikua në AE"))
            return
        if t == "expr_apply":
            e = next((x for x in self.expressions if x.get("id") == msg.get("id")), None)
            if e:
                self.engine.jobs.put(lambda: self.engine.toast(
                    self.engine.ae.apply_expression(e["code"], bool(e.get("needs_keys"))) or f"“{e['name']}” u aplikua"))
            return
        if t == "projects_request":
            self.projects.wake.set()
            self.push_projects()
            return
        if t == "project_open":
            path = str(msg.get("path", ""))
            if os.path.isfile(path):
                open_path(path)
                self.engine.toast("Duke hapur " + os.path.basename(path))
            return
        if t == "project_reveal":
            path = str(msg.get("path", ""))
            if msg.get("backups"):
                d = self.projects.backup_dir_for(path)
                if d.is_dir():
                    open_path(d)
                else:
                    self.engine.toast("Ende s'ka backup për këtë projekt")
            elif os.path.exists(path):
                open_path(path, select=True)
            return
        if t == "project_new":
            try:
                folder = create_project(self.store.get()["settings"], str(msg.get("client", "")), str(msg.get("name", "")))
                open_path(folder)
                log(f"Projekt i ri: {folder}")
                self.engine.toast(f"📁 U krijua: {folder.name}")
            except OSError as e:
                self.engine.toast(f"Projekti nuk u krijua: {e}")
            return
        if t == "time_request":
            self.link.send(self.timer.summary(str(msg.get("range", "today"))))
            return
        if t == "clipboard_request":
            text = read_clipboard()
            if not text and not IS_WINDOWS:
                text = "0:12 - Hiq logon ne fillim\n0:45 – Muzika me e ulet\n1:02:10 Ndrysho ngjyren e titullit\nKontrollo drejtshkrimin ne fund"
            self.link.send({"type": "clipboard", "text": text[:20000]})
            return
        if t == "goto":
            steps = timecode_steps(self.foreground, float(msg.get("seconds", 0)), int(msg.get("frames", 0)),
                                   self.store.get()["settings"].get("timecode_start_hours", {}))
            if steps is None:
                self.engine.toast("Kliko te Premiere, Resolve ose After Effects dhe provo prapë")
            else:
                self.engine.jobs.put(lambda: self.engine.run_steps(steps))
            return
        self.engine.handle(msg)

    # -- audio / render events --
    def on_audio(self, state: dict) -> None:
        self.link.send({"type": "mixer", "mixer": state})

    def on_render(self, ev: dict) -> None:
        if ev.get("state") == "started":
            self.renders[ev["path"]] = ev
        else:
            self.renders.pop(ev.get("path", ""), None)
        self.link.send(ev)
        if ev.get("state") == "done" and self.store.get()["settings"].get("render_sound", True) and IS_WINDOWS:
            try:
                import winsound
                winsound.MessageBeep(0x40)
            except Exception:
                pass

    # -- iPad messages --
    def push_config(self) -> None:
        self.link.send({"type": "config", "config": ipad_view(self.store.get())})
        self.push_active(force=True)
        self.push_extras()
        if self.audio.state.get("available"):
            self.link.send({"type": "mixer", "mixer": self.audio.state})
        for ev in list(self.renders.values()):
            self.link.send(ev)

    def push_active(self, force: bool = False) -> None:
        p = self.store.profile_for_exe(self.foreground)
        if p and (force or p["id"] != self.active_profile):
            self.active_profile = p["id"]
            self.link.send({"type": "active", "profile": p["id"], "app": p["name"]})

    # -- threads --
    def watch_foreground(self) -> None:
        while not self.stop.is_set():
            exe = foreground_exe()
            if exe and exe != self.foreground:
                self.foreground = exe
                if exe in self.recent_apps:
                    self.recent_apps.remove(exe)
                self.recent_apps.insert(0, exe)
                del self.recent_apps[20:]
                if self.link.connected:
                    self.push_active()
            time.sleep(0.25)

    def watch_config(self) -> None:
        while not self.stop.is_set():
            if self.store.reload():
                self.push_config()
            time.sleep(1.0)

    def heartbeat(self) -> None:
        while not self.stop.is_set():
            if self.link.connected:
                self.link.send({"type": "ping", "t": time.time()})
            time.sleep(2.0)

    def open_socket(self) -> tuple[socket.socket, str]:
        if self.tcp:
            s = socket.create_connection(self.tcp, timeout=3)
            s.settimeout(None)
            return s, f"TCP {self.tcp[0]}:{self.tcp[1]}"
        devices = self.mux.usb_devices()
        if not devices:
            raise LookupError
        d = devices[0]
        return self.mux.connect(d["id"], IPAD_PORT), f"iPad {d['serial'][-6:]}"

    def connect_loop(self) -> None:
        while not self.stop.is_set():
            try:
                sock, name = self.open_socket()
            except MuxUnavailable:
                status("X  Nuk gjej sherbimin 'Apple Mobile Device'. Instalo iTunes (nga apple.com) ose 'Apple Devices', pastaj rinise agjentin.")
                time.sleep(3)
                continue
            except LookupError:
                status("…  Duke pritur iPad-in me kabllo USB (lidhe dhe zgjidh 'Trust / Beso' ne iPad).")
                time.sleep(1.5)
                continue
            except MuxRefused:
                status("…  iPad-i u gjet me USB. Hap aplikacionin 'USB Deck' ne iPad.")
                time.sleep(1.5)
                continue
            except OSError as e:
                status(f"…  Duke provuar perseri ({e})")
                time.sleep(2)
                continue

            self.link.attach(sock, name)
            status(f"OK Lidhur me {name} neper kabllo USB.")
            self.active_profile = None
            self.push_config()
            try:
                while True:
                    msg = IPadLink.read(sock)
                    self.handle(msg)
            except (OSError, ConnectionError, ValueError, struct.error):
                pass
            finally:
                self.link.close()
                self.engine.release_all()
                self.receiver.abort_all()
                self.screen.stop_stream()
                self.scopes.stop_stream()
                status("!  Lidhja me iPad-in u nderpre - po pres rilidhjen…")
            time.sleep(0.5)

    def run(self, open_browser: bool) -> None:
        log(f"USB Deck agjenti v{VERSION}")
        self.audio.start()
        self.render_watch.start()
        self.projects.start()
        self.timer.start()
        self.screen.start()
        self.apps.scan_async()
        self.media.start()
        self.scopes.start()
        threading.Thread(target=self.ppro.watchdog, daemon=True, name="ppro-watch").start()
        for target in (self.watch_foreground, self.watch_config, self.heartbeat, self.connect_loop):
            threading.Thread(target=target, daemon=True, name=target.__name__).start()

        port = int(self.store.get()["settings"].get("editor_port", 8790))
        server = make_server(self, port)
        url = f"http://127.0.0.1:{port}/"
        log(f"Editori i butonave: {url}")
        if open_browser:
            threading.Timer(1.0, lambda: webbrowser.open(url)).start()
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.engine.release_all()
            self.timer.save()
            log("Agjenti u mbyll.")


# --------------------------------------------------------------------------- #
# Web editor (local only: 127.0.0.1)
# --------------------------------------------------------------------------- #

def make_server(agent: Agent, port: int) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        server_version = "USBDeck/" + VERSION

        def log_message(self, *args) -> None:  # keep the console clean
            pass

        def _json(self, code: int, obj, cors: bool = False) -> None:
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            if cors:
                self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 5_000_000:
                raise ValueError("too large")
            return json.loads(self.rfile.read(n).decode("utf-8") or "{}")

        def _same_origin(self) -> bool:
            # Block other websites from posting to the local editor.
            origin = self.headers.get("Origin")
            return origin is None or origin in (f"http://127.0.0.1:{port}", f"http://localhost:{port}")

        def do_GET(self) -> None:
            path = self.path.split("?")[0]
            if path in ("/", "/index.html"):
                data = (WEB_DIR / "editor.html").read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif path == "/favicon.ico":
                self.send_response(204)
                self.end_headers()
            elif path == "/api/config":
                self._json(200, agent.store.get())
            elif path == "/api/defaults":
                self._json(200, json.loads(DEFAULT_CONFIG_FILE.read_text(encoding="utf-8")))
            elif path == "/api/timelog.csv":
                data = ("\ufeff" + agent.timer.csv()).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/csv; charset=utf-8")
                self.send_header("Content-Disposition", 'attachment; filename="usb-deck-koha.csv"')
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif path == "/api/apps":
                self._json(200, {"ready": agent.apps.ready.is_set(),
                                 "scanned": [{k: a[k] for k in ("name", "path", "exe")} for a in agent.apps.apps],
                                 "launchers": agent.launchers()})
            elif path == "/api/status":
                self._json(200, {
                    "version": VERSION,
                    "connected": agent.link.connected,
                    "device": agent.link.device,
                    "foreground": agent.foreground,
                    "recent_apps": agent.recent_apps,
                    "active_profile": agent.active_profile,
                    "ae_path": agent.engine.ae.exe_path(),
                    "ae_scripts": agent.engine.ae.scripts(),
                    "keyboard": not KEYS.dry,
                    "audio": agent.audio.backend_name,
                    "audio_commands": AUDIO_COMMANDS,
                    "rendering": [e["name"] for e in agent.renders.values()],
                    "time_current": agent.timer.current,
                })
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self) -> None:
            path = self.path.split("?")[0]
            if path in ("/api/ppro/state", "/api/ppro/result"):
                # The Premiere panel is a local file:// page (Origin "null"); websites are never allowed.
                if self.headers.get("Origin") not in (None, "null", "file://"):
                    self._json(403, {"error": "origin"}, cors=True)
                    return
                try:
                    body = self._body()
                except Exception:
                    self._json(400, {"error": "json"}, cors=True)
                    return
                if path == "/api/ppro/state":
                    self._json(200, {"commands": agent.ppro.on_panel_state(body)}, cors=True)
                else:
                    agent.ppro.on_result(body)
                    self._json(200, {"ok": True}, cors=True)
                return
            if not self._same_origin():
                self._json(403, {"error": "origin"})
                return
            if path == "/api/send_upload":          # editor: upload a document for the iPad
                from urllib.parse import unquote
                n = int(self.headers.get("Content-Length") or 0)
                if n <= 0 or n > 1_500_000_000:
                    self._json(400, {"error": "Madhësi e pavlefshme"})
                    return
                name = unquote(self.headers.get("X-Filename") or "dokument")
                tmp = Path(tempfile.gettempdir()) / f"usbdeck_up_{uuid.uuid4().hex}"
                with open(tmp, "wb") as fh:
                    left = n
                    while left > 0:
                        chunk = self.rfile.read(min(left, 1 << 20))
                        if not chunk:
                            break
                        fh.write(chunk)
                        left -= len(chunk)
                if not agent.link.connected:
                    tmp.unlink(missing_ok=True)
                    self._json(409, {"error": "iPad-i nuk është i lidhur"})
                    return
                threading.Thread(target=send_document, args=(agent.link, tmp, name, True, log), daemon=True).start()
                self._json(200, {"ok": True})
                return
            if path == "/api/send_file":            # "Send to > USB Deck" from Explorer
                from urllib.parse import parse_qs
                n = int(self.headers.get("Content-Length") or 0)
                form = parse_qs(self.rfile.read(min(n, 100_000)).decode("utf-8", "replace"))
                files = [Path(p) for p in form.get("path", []) if os.path.isfile(p)]
                if not agent.link.connected:
                    self._json(409, {"error": "iPad-i nuk është i lidhur"})
                    return

                def send_all() -> None:
                    for f in files:
                        send_document(agent.link, f, None, False, log)
                threading.Thread(target=send_all, daemon=True).start()
                self._json(200, {"ok": True, "files": len(files)})
                return
            try:
                body = self._body()
            except Exception:
                self._json(400, {"error": "JSON i pavlefshëm"})
                return
            if path == "/api/config":
                try:
                    cfg = agent.store.save(body)
                except (ConfigError, ValueError, TypeError) as e:
                    self._json(400, {"error": str(e)})
                    return
                agent.push_config()
                self._json(200, {"ok": True, "config": cfg, "pushed": agent.link.connected})
            elif path == "/api/ppro_install":
                res = install_panel(HERE / "premiere-panel")
                self._json(200 if res == "ok" else 500, {"ok": res == "ok", "message": res})
            elif path == "/api/apps_rescan":
                agent.apps.ready.clear()
                agent.apps.scan_async(force=True)
                self._json(200, {"ok": True})
            elif path == "/api/render_test":
                agent.on_render({"type": "render", "state": "done", "path": "", "name": "Testi_Final_v3.mp4",
                                 "folder": "", "size": "1.4 GB", "duration": "4m 12s",
                                 "finished": time.strftime("%H:%M"), "test": True})
                self._json(200, {"ok": True, "pushed": agent.link.connected})
            elif path == "/api/test":
                actions = body.get("actions") or []
                delay = max(0.0, min(float(body.get("delay", 3)), 10.0))

                def later() -> None:
                    time.sleep(delay)
                    agent.engine.jobs.put(lambda: agent.engine.run_steps(actions))
                threading.Thread(target=later, daemon=True).start()
                self._json(200, {"ok": True})
            else:
                self._json(404, {"error": "not found"})

    try:
        return ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError:
        raise SystemExit(f"Porta {port} eshte e zene. A eshte agjenti tashme i hapur?")


# --------------------------------------------------------------------------- #

def main() -> None:
    ap = argparse.ArgumentParser(description="USB Deck - agjenti per Windows")
    ap.add_argument("--no-browser", action="store_true", help="mos hap editorin ne browser")
    ap.add_argument("--tcp", metavar="HOST:PORT", help="testim: lidhu me TCP direkt (p.sh. me iproxy)")
    args = ap.parse_args()

    tcp = None
    if args.tcp:
        host, _, port = args.tcp.rpartition(":")
        tcp = (host or "127.0.0.1", int(port))

    Agent(tcp).run(open_browser=not args.no_browser)


if __name__ == "__main__":
    main()
