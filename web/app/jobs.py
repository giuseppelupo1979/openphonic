"""File-backed production store + background worker pool."""
from __future__ import annotations

import json
import os
import shutil
import threading
import time
import traceback
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import pipeline
from .settings import Settings

DATA = Path(os.environ.get("DATA_DIR", Path(__file__).resolve().parent.parent / "data"))
JOBS = DATA / "productions"
PRESETS_FILE = DATA / "presets.json"
JOBS.mkdir(parents=True, exist_ok=True)

_pool = ThreadPoolExecutor(max_workers=int(os.environ.get("WORKERS", "2")))
_lock = threading.Lock()


def _path(job_id: str) -> Path:
    if not job_id.isalnum():
        raise KeyError(job_id)
    return JOBS / job_id


def save(job: dict) -> None:
    p = _path(job["id"]) / "job.json"
    tmp = p.with_suffix(".tmp")
    with _lock:
        tmp.write_text(json.dumps(job, indent=1))
        tmp.replace(p)


def load(job_id: str) -> dict:
    p = _path(job_id) / "job.json"
    if not p.exists():
        raise KeyError(job_id)
    job = json.loads(p.read_text())
    r = _path(job_id) / "result.json"
    if job["status"] == "done" and r.exists():
        job["result"] = json.loads(r.read_text())
    return job


def list_jobs() -> list[dict]:
    out = []
    for d in JOBS.iterdir():
        try:
            j = json.loads((d / "job.json").read_text())
            out.append(j)
        except Exception:
            continue
    return sorted(out, key=lambda j: j["created"], reverse=True)


def create(title: str, settings: Settings) -> dict:
    purge_old()
    job_id = uuid.uuid4().hex[:12]
    d = _path(job_id)
    (d / "input").mkdir(parents=True)
    job = {"id": job_id, "title": title, "status": "uploading", "step": "Uploading",
           "progress": 0, "created": time.time(), "settings": settings.model_dump(),
           "inputs": {"tracks": [], "intro": None, "outro": None, "cover": None}, "error": None}
    save(job)
    return job


def input_dir(job_id: str) -> Path:
    return _path(job_id) / "input"


def output_dir(job_id: str) -> Path:
    return _path(job_id) / "output"


def start(job: dict) -> None:
    job["status"] = "queued"
    job["step"] = "Waiting in queue"
    save(job)
    _pool.submit(_run, job["id"])


def _run(job_id: str) -> None:
    job = load(job_id)
    job.pop("result", None)
    job["status"] = "processing"
    job["started"] = time.time()
    save(job)
    d = input_dir(job_id)
    i = job["inputs"]
    if i.get("url") and not i["tracks"]:
        job["step"] = "Downloading input from URL"
        save(job)
        try:
            i["tracks"] = [_download(i["url"], d)]
            save(job)
        except Exception as e:  # noqa: BLE001
            job.update(status="error", error=f"Download failed: {e}", finished=time.time())
            save(job)
            return
    inputs = pipeline.Inputs(
        tracks=[d / t for t in i["tracks"]],
        intro=d / i["intro"] if i["intro"] else None,
        outro=d / i["outro"] if i["outro"] else None,
        cover=d / i["cover"] if i["cover"] else None,
    )
    last = [0.0]

    def report(step: str, pct: float) -> None:
        job["step"], job["progress"] = step, round(pct, 1)
        if time.time() - last[0] > 0.5 or pct >= 100:
            last[0] = time.time()
            save(job)

    try:
        pipeline.process(_path(job_id), Settings(**job["settings"]), inputs, report)
        job["status"] = "done"
    except Exception as e:  # noqa: BLE001
        job["status"] = "error"
        job["error"] = str(e)
        job["traceback"] = traceback.format_exc()[-4000:]
    job["finished"] = time.time()
    save(job)


MAX_BYTES = int(os.environ.get("MAX_UPLOAD_MB", "2000")) * 1024 * 1024


def _download(url: str, d: Path) -> str:
    import urllib.parse
    import urllib.request

    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("only http(s) URLs are supported")
    if not os.environ.get("ALLOW_PRIVATE_URLS"):
        # a public server must not be usable to reach its own internal network
        import ipaddress
        import socket
        for info in socket.getaddrinfo(parsed.hostname, parsed.port or 443):
            ip = ipaddress.ip_address(info[4][0])
            if not ip.is_global:
                raise ValueError("URLs pointing to private or local addresses are not allowed")
    name = Path(urllib.parse.urlparse(url).path).name or "input"
    name = "".join(c for c in name if c.isalnum() or c in "._-")[:100] or "input"
    req = urllib.request.Request(url, headers={"User-Agent": "OpenPhonic/1.0"})
    total = 0
    with urllib.request.urlopen(req, timeout=60) as r, open(d / name, "wb") as f:
        while chunk := r.read(1 << 20):
            total += len(chunk)
            if total > MAX_BYTES:
                raise ValueError("file too large")
            f.write(chunk)
    return name


def delete(job_id: str) -> None:
    shutil.rmtree(_path(job_id), ignore_errors=True)


RETENTION_DAYS = float(os.environ.get("RETENTION_DAYS", "0"))  # 0 = keep forever


def purge_old() -> None:
    """Delete finished productions older than RETENTION_DAYS (keeps small servers from filling up)."""
    if RETENTION_DAYS <= 0:
        return
    limit = time.time() - RETENTION_DAYS * 86400
    for j in list_jobs():
        if j["status"] in ("done", "error") and j.get("finished", j["created"]) < limit:
            delete(j["id"])


def resume_pending() -> None:
    """Re-queue productions interrupted by a server restart."""
    for j in list_jobs():
        if j["status"] in ("queued", "processing"):
            start(j)


# ---- presets

def load_presets() -> dict:
    user = json.loads(PRESETS_FILE.read_text()) if PRESETS_FILE.exists() else {}
    return {"builtin": pipeline_presets(), "user": user}


def pipeline_presets() -> dict:
    from .settings import PRESETS
    return PRESETS


def save_preset(name: str, settings: dict) -> None:
    with _lock:
        user = json.loads(PRESETS_FILE.read_text()) if PRESETS_FILE.exists() else {}
        user[name] = settings
        PRESETS_FILE.write_text(json.dumps(user, indent=1))


def delete_preset(name: str) -> None:
    with _lock:
        user = json.loads(PRESETS_FILE.read_text()) if PRESETS_FILE.exists() else {}
        user.pop(name, None)
        PRESETS_FILE.write_text(json.dumps(user, indent=1))
