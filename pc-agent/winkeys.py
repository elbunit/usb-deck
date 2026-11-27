"""Keystrokes for Windows via SendInput (virtual-key codes + correct extended flag).

The `keyboard` library sends arrows/Home/End/PageUp/Delete without the extended-key
flag, so apps like Premiere receive them as numpad digits (4, 6, 7, 1...) - which
opens Premiere's timecode entry instead of moving the playhead. This module sends
real virtual keys instead.

Combo syntax (same as before): "ctrl+shift+s", sequences separated by ", ".
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import time

user32 = ctypes.WinDLL("user32", use_last_error=True)

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
INPUT_KEYBOARD = 1

ULONG_PTR = ctypes.c_size_t


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wt.WORD), ("wScan", wt.WORD), ("dwFlags", wt.DWORD),
                ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wt.LONG), ("dy", wt.LONG), ("mouseData", wt.DWORD),
                ("dwFlags", wt.DWORD), ("time", wt.DWORD), ("dwExtraInfo", ULONG_PTR)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wt.DWORD), ("wParamL", wt.WORD), ("wParamH", wt.WORD)]


class _U(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wt.DWORD), ("u", _U)]


user32.SendInput.argtypes = (wt.UINT, ctypes.POINTER(INPUT), ctypes.c_int)
user32.SendInput.restype = wt.UINT
user32.VkKeyScanExW.argtypes = (wt.WCHAR, wt.HANDLE)
user32.VkKeyScanExW.restype = ctypes.c_short
user32.MapVirtualKeyExW.argtypes = (wt.UINT, wt.UINT, wt.HANDLE)
user32.MapVirtualKeyExW.restype = wt.UINT
user32.GetKeyboardLayout.argtypes = (wt.DWORD,)
user32.GetKeyboardLayout.restype = wt.HANDLE
user32.GetForegroundWindow.restype = wt.HWND
user32.GetWindowThreadProcessId.argtypes = (wt.HWND, ctypes.POINTER(wt.DWORD))
user32.GetWindowThreadProcessId.restype = wt.DWORD

NAMED = {
    "ctrl": 0xA2, "control": 0xA2, "left ctrl": 0xA2, "right ctrl": 0xA3,
    "shift": 0xA0, "left shift": 0xA0, "right shift": 0xA1,
    "alt": 0xA4, "left alt": 0xA4, "right alt": 0xA5, "alt gr": 0xA5,
    "windows": 0x5B, "win": 0x5B, "left windows": 0x5B, "right windows": 0x5C,
    "backspace": 0x08, "tab": 0x09, "enter": 0x0D, "return": 0x0D,
    "esc": 0x1B, "escape": 0x1B, "space": 0x20, "spacebar": 0x20,
    "page up": 0x21, "pageup": 0x21, "page down": 0x22, "pagedown": 0x22,
    "end": 0x23, "home": 0x24, "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28,
    "print screen": 0x2C, "insert": 0x2D, "delete": 0x2E, "del": 0x2E,
    "caps lock": 0x14, "num lock": 0x90, "scroll lock": 0x91, "pause": 0x13,
    "menu": 0x5D, "apps": 0x5D,
    "num 0": 0x60, "num 1": 0x61, "num 2": 0x62, "num 3": 0x63, "num 4": 0x64,
    "num 5": 0x65, "num 6": 0x66, "num 7": 0x67, "num 8": 0x68, "num 9": 0x69,
    "num *": 0x6A, "num +": 0x6B, "num -": 0x6D, "num .": 0x6E, "num /": 0x6F,
    "num enter": 0x0D,
    "volume mute": 0xAD, "volume down": 0xAE, "volume up": 0xAF,
    "next track": 0xB0, "previous track": 0xB1, "stop media": 0xB2,
    "play/pause media": 0xB3, "play/pause": 0xB3,
}
for _i in range(1, 25):
    NAMED[f"f{_i}"] = 0x6F + _i

# Keys that need KEYEVENTF_EXTENDEDKEY (otherwise they arrive as numpad keys).
EXTENDED = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E,
            0xA3, 0xA5, 0x5B, 0x5C, 0x5D, 0x6F, 0x90,
            0xAD, 0xAE, 0xAF, 0xB0, 0xB1, 0xB2, 0xB3}

# US-layout fallbacks for punctuation (used if the active layout has no such key).
US_PUNCT = {";": 0xBA, "=": 0xBB, ",": 0xBC, "-": 0xBD, ".": 0xBE, "/": 0xBF,
            "`": 0xC0, "[": 0xDB, "\\": 0xDC, "]": 0xDD, "'": 0xDE}


def _layout():
    hwnd = user32.GetForegroundWindow()
    tid = user32.GetWindowThreadProcessId(hwnd, None) if hwnd else 0
    return user32.GetKeyboardLayout(tid)


def _resolve(token: str, hkl) -> list[int]:
    """Token -> list of VKs (a symbol that needs Shift returns [shift, vk])."""
    t = token.strip().lower()
    if t in NAMED:
        return [NAMED[t]]
    if t == "plus":
        t = "+"
    if t == "comma":
        t = ","
    if len(t) == 1:
        if "a" <= t <= "z":
            return [ord(t.upper())]
        if "0" <= t <= "9":
            return [ord(t)]
        r = user32.VkKeyScanExW(t, hkl)
        if r != -1 and (r & 0xFF) != 0xFF:
            vk, shift = r & 0xFF, (r >> 8) & 0xFF
            mods = []
            if shift & 1:
                mods.append(0xA0)
            if shift & 2:
                mods.append(0xA2)
            if shift & 4:
                mods.append(0xA4)
            return mods + [vk]
        if t in US_PUNCT:
            return [US_PUNCT[t]]
    raise ValueError(f"tast i panjohur: {token!r}")


def _event(vk: int, up: bool, hkl) -> INPUT:
    scan = user32.MapVirtualKeyExW(vk, 0, hkl) & 0xFF
    flags = KEYEVENTF_KEYUP if up else 0
    if vk in EXTENDED:
        flags |= KEYEVENTF_EXTENDEDKEY
    inp = INPUT(type=INPUT_KEYBOARD)
    inp.u.ki = KEYBDINPUT(vk, scan, flags, 0, 0)
    return inp


def _send(events: list[INPUT]) -> None:
    if not events:
        return
    arr = (INPUT * len(events))(*events)
    user32.SendInput(len(events), arr, ctypes.sizeof(INPUT))


def parse(combo: str) -> list[list[str]]:
    seqs = []
    for part in combo.split(", ") if ", " in combo else [combo]:
        part = part.strip()
        if not part:
            continue
        if part == "+":
            seqs.append(["+"])
            continue
        keys = [k for k in part.split("+")]
        # "ctrl++" -> ['ctrl', '', ''] : the key is '+'
        if part.endswith("++"):
            keys = [k for k in part[:-2].split("+") if k] + ["+"]
        seqs.append([k for k in keys if k != ""] or [part])
    return seqs


def _vks(keys: list[str], hkl) -> list[int]:
    out: list[int] = []
    for k in keys:
        for vk in _resolve(k, hkl):
            if vk not in out:
                out.append(vk)
    return out


def send(combo: str) -> None:
    hkl = _layout()
    for i, keys in enumerate(parse(combo)):
        vks = _vks(keys, hkl)
        mods, main = vks[:-1], vks[-1:]
        downs = [_event(v, False, hkl) for v in mods]
        _send(downs)
        if mods:
            time.sleep(0.008)  # some apps (Premiere) miss the key if it lands with the modifier
        _send([_event(v, False, hkl) for v in main] + [_event(v, True, hkl) for v in main])
        if mods:
            time.sleep(0.008)
        _send([_event(v, True, hkl) for v in reversed(mods)])
        if i:
            time.sleep(0.01)


def press(combo: str) -> None:
    hkl = _layout()
    seqs = parse(combo)
    if seqs:
        _send([_event(v, False, hkl) for v in _vks(seqs[0], hkl)])


def release(combo: str) -> None:
    hkl = _layout()
    seqs = parse(combo)
    if seqs:
        _send([_event(v, True, hkl) for v in reversed(_vks(seqs[0], hkl))])


def write(text: str, delay: float = 0.003) -> None:
    for ch in text:
        if ch == "\n":
            send("enter")
        else:
            code = ord(ch)
            a = INPUT(type=INPUT_KEYBOARD)
            a.u.ki = KEYBDINPUT(0, code, KEYEVENTF_UNICODE, 0, 0)
            b = INPUT(type=INPUT_KEYBOARD)
            b.u.ki = KEYBDINPUT(0, code, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, 0, 0)
            _send([a, b])
        if delay:
            time.sleep(delay)
