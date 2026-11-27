"""
USB Deck - asistent AI lokal (Ollama).

Ollama (falas, https://ollama.com) e ekzekuton modelin AI ne PC-ne tende:
pa abonim, pa internet pasi shkarkohet modeli, dhe teksti nuk del nga PC-ja.
Ky modul flet me Ollama ne http://127.0.0.1:11434.
"""

from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

OLLAMA = "http://127.0.0.1:11434"
IS_WINDOWS = os.name == "nt"

MODELS = [
    {"id": "gemma3:4b", "name": "Gemma 3 · 4B", "size": "3.3 GB", "note": "I rekomanduar – shqip i mirë, i shpejtë"},
    {"id": "llama3.2:3b", "name": "Llama 3.2 · 3B", "size": "2.0 GB", "note": "Më i lehti – për PC pa kartë grafike"},
    {"id": "gemma3:12b", "name": "Gemma 3 · 12B", "size": "8.1 GB", "note": "Më i zgjuari – kërkon kartë grafike të fortë"},
]

SYSTEM_PROMPT = (
    "Je asistent i një video editori dhe motion designeri profesionist (Premiere Pro, After Effects, "
    "DaVinci Resolve, Photoshop). Përgjigju në shqip, përveç kur të kërkohet gjuhë tjetër. "
    "Ji praktik, i qartë dhe i shkurtër; përdor lista kur ndihmojnë. Për tekste marketingu "
    "(përshkrime, caption, tituj) jep disa variante gati për t'u kopjuar."
)


def _get(path: str, timeout: float = 3.0) -> dict:
    with urllib.request.urlopen(OLLAMA + path, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _stream(path: str, body: dict, timeout: float = 600.0):
    req = urllib.request.Request(OLLAMA + path, data=json.dumps(body).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    resp = urllib.request.urlopen(req, timeout=timeout)
    try:
        for line in resp:
            line = line.strip()
            if line:
                yield json.loads(line.decode("utf-8"))
    finally:
        resp.close()


def ollama_exe() -> Path | None:
    if not IS_WINDOWS:
        return None
    for p in (Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\Ollama\ollama app.exe")),
              Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\Ollama\ollama.exe"))):
        if p.exists():
            return p
    return None


class Assistant:
    def __init__(self, send: Callable[[dict], bool], get_settings: Callable[[], dict],
                 log: Callable[[str], None]) -> None:
        self.send = send
        self.get_settings = get_settings
        self.log = log
        self.cancel = threading.Event()
        self.busy = False
        self.pulling: dict | None = None

    # ------------------------------------------------------------------ status
    def status(self) -> dict:
        model = self.get_settings().get("ai_model", MODELS[0]["id"])
        st = {"type": "ai_status", "model": model, "models": MODELS, "installed_models": [],
              "running": False, "installed": False, "pulling": self.pulling, "busy": self.busy}
        try:
            tags = _get("/api/tags")
            st["running"] = st["installed"] = True
            st["installed_models"] = [m.get("name", "") for m in tags.get("models", [])]
        except Exception:
            st["installed"] = ollama_exe() is not None
        st["ready"] = st["running"] and any(n in (model, model + ":latest") for n in st["installed_models"])
        return st

    def push_status(self) -> None:
        self.send(self.status())

    def start_ollama(self) -> str:
        exe = ollama_exe()
        if not exe:
            import webbrowser
            webbrowser.open("https://ollama.com/download")
            return "Hapa faqen e Ollama në PC – shkarko dhe instaloje, pastaj kthehu këtu."
        try:
            os.startfile(str(exe))  # type: ignore[attr-defined]
            return "Po nis Ollama…"
        except OSError as e:
            return f"Ollama nuk u nis: {e}"

    # ------------------------------------------------------------------ model download
    def pull(self, model: str) -> None:
        if self.pulling:
            return

        def go() -> None:
            self.pulling = {"model": model, "percent": 0, "status": "duke filluar"}
            self.push_status()
            last = -1
            try:
                for ev in _stream("/api/pull", {"model": model, "name": model, "stream": True}, timeout=3600):
                    total, done = ev.get("total"), ev.get("completed")
                    pct = int(done * 100 / total) if total and done else self.pulling["percent"]
                    self.pulling = {"model": model, "percent": pct, "status": ev.get("status", "")}
                    if pct != last:
                        last = pct
                        self.push_status()
                    if ev.get("error"):
                        raise RuntimeError(ev["error"])
                self.log(f"AI: modeli {model} u shkarkua.")
            except Exception as e:
                self.log(f"AI: shkarkimi dështoi ({e})")
                self.send({"type": "toast", "text": f"Shkarkimi dështoi: {e}"})
            finally:
                self.pulling = None
                self.push_status()

        threading.Thread(target=go, daemon=True, name="ai-pull").start()

    # ------------------------------------------------------------------ chat
    def chat(self, rid: str, messages: list[dict]) -> None:
        if self.busy:
            self.send({"type": "ai_error", "id": rid, "error": "Asistenti po shkruan ende – prit ose ndale."})
            return
        model = self.get_settings().get("ai_model", MODELS[0]["id"])
        clean = [{"role": "system", "content": SYSTEM_PROMPT}]
        for m in messages[-20:]:
            role = m.get("role")
            if role in ("user", "assistant") and str(m.get("content", "")).strip():
                clean.append({"role": role, "content": str(m["content"])[:8000]})
        self.cancel.clear()

        def go() -> None:
            self.busy = True
            try:
                for ev in _stream("/api/chat", {"model": model, "messages": clean, "stream": True}):
                    if self.cancel.is_set():
                        break
                    if ev.get("error"):
                        raise RuntimeError(ev["error"])
                    piece = (ev.get("message") or {}).get("content", "")
                    if piece:
                        self.send({"type": "ai_delta", "id": rid, "text": piece})
                    if ev.get("done"):
                        break
                self.send({"type": "ai_done", "id": rid})
            except urllib.error.URLError:
                self.send({"type": "ai_error", "id": rid, "error": "Ollama nuk po përgjigjet. Hape në PC (ose instaloje)."})
            except Exception as e:
                self.send({"type": "ai_error", "id": rid, "error": str(e)})
            finally:
                self.busy = False

        threading.Thread(target=go, daemon=True, name="ai-chat").start()

    def stop(self) -> None:
        self.cancel.set()
