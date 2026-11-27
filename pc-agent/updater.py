"""Self-update of the PC agent from the user's GitHub repository.

Downloads the repo as a zip (codeload.github.com), compares VERSION in
pc-agent/agent.py, backs up the current files and copies the new ones over.
User data (profiles, brands, time log, usage...) is never touched.
"""
from __future__ import annotations

import io
import re
import shutil
import ssl
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

# Files/folders inside pc-agent that belong to the user - never overwritten.
USER_DATA = {"profiles.json", "brands.json", "timelog.json", "apps_cache.json", "usage.json", "paths.json",
             "agent.log", "agent.log.1", "backups", "__pycache__"}
# Top-level files of the repo that are updated too (the start scripts, readme).
ROOT_FILES_RE = re.compile(r"^[^/]+\.(bat|md|vbs)$", re.I)

VERSION_RE = re.compile(r'^VERSION\s*=\s*"([0-9.]+)"', re.M)


def vtuple(v: str) -> tuple:
    try:
        return tuple(int(x) for x in v.split("."))
    except ValueError:
        return (0,)


def _get(url: str, token: str = "", timeout: float = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "USBDeck-updater"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return r.read()


def _friendly(e: Exception) -> str:
    if isinstance(e, urllib.error.HTTPError):
        if e.code == 404:
            return ("Repo nuk u gjet. Nëse është 'Private', bëje 'Public' te GitHub › Settings, "
                    "ose vendos një token te Cilësimet.")
        return f"GitHub ktheu gabimin {e.code}"
    if isinstance(e, urllib.error.URLError):
        return "S'ka internet ose GitHub nuk arrihet"
    return str(e)


class Updater:
    def __init__(self, here: Path, current: str, log) -> None:
        self.here = here                 # .../usb-deck/pc-agent
        self.root = here.parent          # .../usb-deck
        self.current = current
        self.log = log
        self.latest: str | None = None
        self.checked_at = 0.0
        self.error = ""
        self._zip: bytes | None = None

    def _urls(self, repo: str, branch: str) -> tuple[str, str]:
        repo = repo.strip().strip("/")
        repo = re.sub(r"^https?://github\.com/", "", repo)
        raw = f"https://raw.githubusercontent.com/{repo}/{branch}/pc-agent/agent.py"
        zipu = f"https://codeload.github.com/{repo}/zip/refs/heads/{branch}"
        return raw, zipu

    def check(self, repo: str, branch: str = "main", token: str = "") -> dict:
        """Returns {"current", "latest", "available", "error"}."""
        self.error = ""
        try:
            if token:
                # raw.githubusercontent doesn't take tokens for private repos reliably: use the zip
                data = self._download(repo, branch, token)
                src = self._read_member(data, "pc-agent/agent.py").decode("utf-8", "replace")
            else:
                raw, _ = self._urls(repo, branch)
                src = _get(f"{raw}?t={int(time.time())}", timeout=15).decode("utf-8", "replace")
            m = VERSION_RE.search(src)
            self.latest = m.group(1) if m else None
            if not self.latest:
                self.error = "Versioni në GitHub nuk u lexua"
        except Exception as e:  # noqa: BLE001
            self.error = _friendly(e)
        self.checked_at = time.time()
        return self.status()

    def status(self) -> dict:
        avail = bool(self.latest and vtuple(self.latest) > vtuple(self.current))
        return {"current": self.current, "latest": self.latest, "available": avail,
                "error": self.error, "checked_at": self.checked_at}

    def _download(self, repo: str, branch: str, token: str = "") -> bytes:
        _, zipu = self._urls(repo, branch)
        if token:
            repo_clean = re.sub(r"^https?://github\.com/", "", repo.strip().strip("/"))
            zipu = f"https://api.github.com/repos/{repo_clean}/zipball/{branch}"
        self._zip = _get(zipu, token, timeout=120)
        return self._zip

    @staticmethod
    def _read_member(data: bytes, rel: str) -> bytes:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for n in z.namelist():
                parts = n.split("/", 1)
                if len(parts) == 2 and parts[1] == rel:
                    return z.read(n)
        raise FileNotFoundError(rel)

    def apply(self, repo: str, branch: str = "main", token: str = "") -> str:
        """Download + install. Returns a message; raises on failure (nothing half-copied)."""
        data = self._download(repo, branch, token)
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            if not names:
                raise RuntimeError("Zip-i nga GitHub është bosh")
            prefix = names[0].split("/", 1)[0] + "/"
            files: dict[str, bytes] = {}
            for n in names:
                if n.endswith("/") or not n.startswith(prefix):
                    continue
                rel = n[len(prefix):]
                if rel.startswith("pc-agent/"):
                    inner = rel[len("pc-agent/"):]
                    if inner.split("/", 1)[0] in USER_DATA or inner.endswith(".pyc"):
                        continue
                    files[rel] = z.read(n)
                elif ROOT_FILES_RE.match(rel):
                    files[rel] = z.read(n)
        if "pc-agent/agent.py" not in files:
            raise RuntimeError("pc-agent/agent.py mungon në GitHub")
        m = VERSION_RE.search(files["pc-agent/agent.py"].decode("utf-8", "replace"))
        new_ver = m.group(1) if m else "?"
        # sanity: the new agent must at least compile
        compile(files["pc-agent/agent.py"].decode("utf-8"), "agent.py", "exec")

        # backup current pc-agent code (not user data)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        bdir = self.here / "backups" / f"agjenti-v{self.current}-{stamp}"
        bdir.mkdir(parents=True, exist_ok=True)
        for p in self.here.iterdir():
            if p.name in USER_DATA:
                continue
            try:
                if p.is_dir():
                    shutil.copytree(p, bdir / p.name, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
                else:
                    shutil.copy2(p, bdir / p.name)
            except OSError:
                pass

        changed = 0
        for rel, blob in files.items():
            dest = self.root / rel
            try:
                if dest.exists() and dest.read_bytes() == blob:
                    continue
            except OSError:
                pass
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_name(dest.name + ".new")
            tmp.write_bytes(blob)
            tmp.replace(dest)
            changed += 1
        self.latest = new_ver
        self.log(f"Përditësimi: v{self.current} → v{new_ver}, {changed} skedarë u ndryshuan (kopja e vjetër: {bdir.name})")
        return f"U përditësua në v{new_ver} ({changed} skedarë). Po rinisem…"
