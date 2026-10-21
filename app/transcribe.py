"""Optional speech recognition (faster-whisper) for transcripts, subtitles and filler cutting."""
from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Callable

_models: dict = {}
_lock = threading.Lock()

FILLERS = {
    "um", "umm", "uh", "uhh", "uhm", "hmm", "hm", "mm", "mmm", "er", "erm", "ah", "eh", "ehm",
    "ehh", "mhm", "uhmm", "ehmm", "m", "mh", "mmh", "eeh", "ehhm",
}
# Whisper tends to drop disfluencies; a prompt that contains them makes it keep them.
_FILLER_PROMPT = "Umm, let me think like, hmm... Okay, uh, here's what I'm, ehm, like, thinking."


def available() -> bool:
    try:
        import faster_whisper  # noqa: F401
        return True
    except Exception:
        return False


def _model(name: str):
    with _lock:
        if name not in _models:
            from faster_whisper import WhisperModel
            _models[name] = WhisperModel(name, device="cpu", compute_type="int8")
        return _models[name]


def transcribe(path: Path, model: str, language: str, keep_fillers: bool,
               progress: Callable[[float], None] | None = None) -> dict:
    from .ffmpeg import read_mono

    m = _model(model)
    segments, info = m.transcribe(
        read_mono(path, 16000),
        language=None if language in ("", "auto") else language,
        word_timestamps=True,
        vad_filter=True,
        initial_prompt=_FILLER_PROMPT if keep_fillers else None,
    )
    out = []
    for seg in segments:
        words = [{"start": w.start, "end": w.end, "word": w.word} for w in (seg.words or [])]
        out.append({"start": seg.start, "end": seg.end, "text": seg.text.strip(), "words": words})
        if progress and info.duration:
            progress(min(1.0, seg.end / info.duration))
    return {"language": info.language, "segments": out}


def is_filler(word: str) -> bool:
    w = word.strip().lower().strip(".,!?…;:-\"'")
    return w in FILLERS


def remap(transcript: dict, fn: Callable[[float], float], drop_fillers: bool) -> dict:
    segs = []
    for s in transcript["segments"]:
        words = [w for w in s["words"] if not (drop_fillers and is_filler(w["word"]))]
        if drop_fillers and s["words"] and not words:
            continue
        text = "".join(w["word"] for w in words).strip() if drop_fillers and s["words"] else s["text"]
        segs.append({
            "start": fn(s["start"]), "end": fn(s["end"]), "text": text,
            "words": [{**w, "start": fn(w["start"]), "end": fn(w["end"])} for w in words],
        })
    return {"language": transcript["language"], "segments": segs}


def _ts(t: float, sep: str) -> str:
    ms = int(round(t * 1000))
    h, ms = divmod(ms, 3600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"


def write_files(transcript: dict, out_dir: Path, stem: str) -> list[str]:
    segs = transcript["segments"]
    files = {
        f"{stem}.txt": "\n".join(s["text"] for s in segs) + "\n",
        f"{stem}.srt": "".join(
            f"{i}\n{_ts(s['start'], ',')} --> {_ts(s['end'], ',')}\n{s['text']}\n\n"
            for i, s in enumerate(segs, 1)),
        f"{stem}.vtt": "WEBVTT\n\n" + "".join(
            f"{_ts(s['start'], '.')} --> {_ts(s['end'], '.')}\n{s['text']}\n\n" for s in segs),
        f"{stem}.json": json.dumps(transcript, ensure_ascii=False, indent=1),
    }
    for name, content in files.items():
        (out_dir / name).write_text(content, encoding="utf-8")
    return list(files)
