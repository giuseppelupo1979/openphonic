"""OpenPhonic - self-hosted audio post-production web app (Auphonic-style)."""
from __future__ import annotations

import base64
import json
import os
import secrets
from pathlib import Path
from typing import Optional

from fastapi import Body, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError

from . import jobs, transcribe
from .settings import Settings

PASSWORD = os.environ.get("APP_PASSWORD", "")
STATIC = Path(__file__).resolve().parent / "static"

# ROOT_PATH: public prefix when served under a sub-path by a proxy that strips it (e.g. /openphonic)
app = FastAPI(title="OpenPhonic", version="1.0", root_path=os.environ.get("ROOT_PATH", ""))


@app.middleware("http")
async def auth(request: Request, call_next):
    if not PASSWORD or request.url.path == "/healthz":
        return await call_next(request)
    h = request.headers.get("authorization", "")
    ok = False
    if h.startswith("Bearer "):
        ok = secrets.compare_digest(h[7:], PASSWORD)
    elif h.startswith("Basic "):
        try:
            _, _, pw = base64.b64decode(h[6:]).decode().partition(":")
            ok = secrets.compare_digest(pw, PASSWORD)
        except Exception:
            ok = False
    if not ok:
        return Response(status_code=401, headers={"WWW-Authenticate": 'Basic realm="OpenPhonic"'})
    return await call_next(request)


@app.on_event("startup")
def _startup() -> None:
    jobs.purge_old()
    jobs.resume_pending()


@app.get("/healthz")
def health():
    return {"ok": True}


@app.get("/api/capabilities")
def capabilities():
    return {"speech_recognition": transcribe.available(),
            "max_upload_mb": jobs.MAX_BYTES // (1024 * 1024),
            "defaults": Settings().model_dump()}


# ---------------------------------------------------------------- presets

@app.get("/api/presets")
def presets():
    return jobs.load_presets()


@app.post("/api/presets")
def save_preset(name: str = Body(...), settings: dict = Body(...)):
    try:
        Settings(**settings)
    except ValidationError as e:
        raise HTTPException(422, e.errors())
    jobs.save_preset(name.strip()[:80], settings)
    return {"ok": True}


@app.delete("/api/presets/{name}")
def delete_preset(name: str):
    jobs.delete_preset(name)
    return {"ok": True}


# ---------------------------------------------------------------- productions

def _parse_settings(raw: str) -> Settings:
    try:
        return Settings(**json.loads(raw or "{}"))
    except (ValidationError, json.JSONDecodeError) as e:
        raise HTTPException(422, f"Invalid settings: {e}")


async def _store(upload: UploadFile, d: Path, prefix: str) -> str:
    base = "".join(c for c in (upload.filename or "file") if c.isalnum() or c in "._-")[-100:]
    name = f"{prefix}_{base or 'file'}"
    total = 0
    with open(d / name, "wb") as f:
        while chunk := await upload.read(1 << 20):
            total += len(chunk)
            if total > jobs.MAX_BYTES:
                raise HTTPException(413, "File too large")
            f.write(chunk)
    return name


@app.post("/api/productions")
async def create_production(
    settings: str = Form("{}"),
    title: str = Form(""),
    url: str = Form(""),
    tracks: list[UploadFile] = File(default=[]),
    intro: Optional[UploadFile] = File(None),
    outro: Optional[UploadFile] = File(None),
    cover: Optional[UploadFile] = File(None),
):
    s = _parse_settings(settings)
    tracks = [t for t in tracks if t.filename]
    if not tracks and not url:
        raise HTTPException(400, "Upload at least one audio/video file or give a URL")
    job = jobs.create(title or s.metadata.title or (tracks[0].filename if tracks else url), s)
    d = jobs.input_dir(job["id"])
    try:
        for i, t in enumerate(tracks):
            job["inputs"]["tracks"].append(await _store(t, d, f"track{i}"))
        for key, up in (("intro", intro), ("outro", outro), ("cover", cover)):
            if up is not None and up.filename:
                job["inputs"][key] = await _store(up, d, key)
    except HTTPException:
        jobs.delete(job["id"])
        raise
    if url and not tracks:
        job["inputs"]["url"] = url
    jobs.start(job)
    return job


@app.get("/api/productions")
def list_productions():
    return [{k: j[k] for k in ("id", "title", "status", "step", "progress", "created", "error")}
            for j in jobs.list_jobs()]


def _get(job_id: str) -> dict:
    try:
        return jobs.load(job_id)
    except KeyError:
        raise HTTPException(404, "Production not found")


@app.get("/api/productions/{job_id}")
def get_production(job_id: str):
    job = _get(job_id)
    job.pop("traceback", None)
    return job


@app.post("/api/productions/{job_id}/reprocess")
def reprocess(job_id: str, settings: dict = Body(..., embed=True)):
    job = _get(job_id)
    if job["status"] in ("queued", "processing"):
        raise HTTPException(409, "Production is still running")
    try:
        job["settings"] = Settings(**settings).model_dump()
    except ValidationError as e:
        raise HTTPException(422, e.errors())
    job.pop("result", None)
    job.update(error=None, progress=0)
    out = jobs.output_dir(job_id)
    if out.exists():
        for f in out.iterdir():
            f.unlink()
    jobs.start(job)
    return job


@app.delete("/api/productions/{job_id}")
def delete_production(job_id: str):
    job = _get(job_id)
    if job["status"] == "processing":
        raise HTTPException(409, "Production is still running")
    jobs.delete(job_id)
    return {"ok": True}


@app.get("/api/productions/{job_id}/files/{name}")
def download(job_id: str, name: str, inline: bool = False):
    _get(job_id)
    p = (jobs.output_dir(job_id) / name).resolve()
    if p.parent != jobs.output_dir(job_id).resolve() or not p.is_file():
        raise HTTPException(404, "File not found")
    return FileResponse(p, filename=None if inline else name)


@app.exception_handler(Exception)
async def _err(request: Request, exc: Exception):
    return JSONResponse({"detail": str(exc)}, status_code=500)


app.mount("/", StaticFiles(directory=STATIC, html=True), name="static")
