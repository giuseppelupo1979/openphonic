"""Version of this build and a cached check for a newer GitHub release."""
from __future__ import annotations

import json
import os
import threading
import time
import urllib.request
from pathlib import Path

REPO = "giuseppelupo1979/openphonic"
_here = Path(__file__).resolve()


def _read_version() -> str:
    if os.environ.get("OPENPHONIC_VERSION"):
        return os.environ["OPENPHONIC_VERSION"]
    for p in (_here.parents[2] / "VERSION", _here.parents[1] / "VERSION"):
        if p.exists():
            return p.read_text().strip()
    return "dev"


VERSION = _read_version()
_cache: dict = {"at": 0.0, "release": None}
_lock = threading.Lock()


def _newer(a: str, b: str) -> bool:
    def parts(v: str) -> list[int]:
        return [int(x) if x.isdigit() else 0 for x in v.lstrip("vV").split(".")]
    if b == "dev":
        return False
    pa, pb = parts(a), parts(b)
    n = max(len(pa), len(pb))
    return pa + [0] * (n - len(pa)) > pb + [0] * (n - len(pb))


def _fetch() -> dict | None:
    url = os.environ.get("OPENPHONIC_UPDATE_URL") or f"https://api.github.com/repos/{REPO}/releases/latest"
    req = urllib.request.Request(url, headers={"User-Agent": f"OpenPhonic/{VERSION}",
                                               "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        j = json.load(r)
    tag = j.get("tag_name", "")
    if not _newer(tag, VERSION):
        return None
    return {"version": tag.lstrip("vV"), "notes": j.get("body", ""), "url": j.get("html_url", "")}


def latest_release(max_age: float = 6 * 3600) -> dict | None:
    """Newer release info, refreshed in the background at most every max_age seconds."""
    with _lock:
        stale = time.time() - _cache["at"] > max_age
        if stale:
            _cache["at"] = time.time()

    def refresh() -> None:
        try:
            _cache["release"] = _fetch()
        except Exception:  # noqa: BLE001 - offline servers must keep working
            pass

    if stale:
        threading.Thread(target=refresh, daemon=True).start()
    return _cache["release"]
