"""Thin wrappers around ffmpeg / ffprobe."""
from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import numpy as np


class FFmpegError(RuntimeError):
    pass


def run(args: list[str], capture: bool = True) -> subprocess.CompletedProcess:
    cmd = ["ffmpeg", "-hide_banner", "-nostdin", "-y", *args]
    proc = subprocess.run(cmd, capture_output=capture, text=True)
    if proc.returncode != 0:
        tail = "\n".join((proc.stderr or "").strip().splitlines()[-15:])
        raise FFmpegError(f"ffmpeg failed ({proc.returncode}):\n{tail}")
    return proc


def probe(path: Path) -> dict:
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise FFmpegError(f"Cannot read {path.name}: not a valid audio/video file")
    data = json.loads(proc.stdout)
    streams = data.get("streams", [])
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    video = next(
        (s for s in streams if s.get("codec_type") == "video"
         and not s.get("disposition", {}).get("attached_pic")),
        None,
    )
    if audio is None:
        raise FFmpegError("No audio stream found in input file")
    return {
        "duration": float(data.get("format", {}).get("duration") or audio.get("duration") or 0),
        "channels": int(audio.get("channels") or 1),
        "sample_rate": int(audio.get("sample_rate") or 48000),
        "codec": audio.get("codec_name"),
        "bit_rate": int(data.get("format", {}).get("bit_rate") or 0),
        "has_video": video is not None,
        "video_codec": video.get("codec_name") if video else None,
        "format": data.get("format", {}).get("format_name"),
    }


def decode_to_wav(src: Path, dst: Path, channels: int, sr: int = 48000) -> None:
    run(["-i", str(src), "-vn", "-map", "0:a:0", "-ac", str(channels), "-ar", str(sr),
         "-c:a", "pcm_f32le", str(dst)])


def read_mono(path: Path, sr: int = 16000) -> np.ndarray:
    """Decode to mono float32 numpy array (for analysis)."""
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostdin", "-i", str(path), "-vn", "-ac", "1", "-ar", str(sr),
         "-f", "f32le", "-"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise FFmpegError(proc.stderr.decode(errors="ignore")[-800:])
    return np.frombuffer(proc.stdout, dtype=np.float32)


_JSON_RE = re.compile(r"\{[^{}]*\"input_i\"[^{}]*\}", re.S)


def loudnorm_measure(path: Path, pre_filter: str | None = None, target: float = -16.0,
                     tp: float = -1.0, dual_mono: bool = False) -> dict:
    """Analysis pass of EBU R128 loudnorm: returns measured stats."""
    af = f"loudnorm=I={target}:TP={tp}:LRA=11:print_format=json"
    if dual_mono:
        af += ":dual_mono=true"
    if pre_filter:
        af = f"{pre_filter},{af}"
    proc = run(["-i", str(path), "-vn", "-af", af, "-f", "null", "-"])
    m = _JSON_RE.search(proc.stderr)
    if not m:
        raise FFmpegError("Could not parse loudnorm output")
    return {k: float(v) if v not in ("-inf", "inf") else (-99.0 if v == "-inf" else 99.0)
            for k, v in json.loads(m.group(0)).items() if k != "normalization_type"}


def loudness_stats(path: Path) -> dict:
    m = loudnorm_measure(path)
    return {
        "integrated_lufs": round(m["input_i"], 1),
        "true_peak_dbtp": round(m["input_tp"], 1),
        "lra_lu": round(m["input_lra"], 1),
    }


def peak(path: Path) -> float:
    """Sample peak (linear) without loading the file into memory."""
    proc = run(["-i", str(path), "-af", "volumedetect", "-f", "null", "-"])
    m = re.search(r"max_volume: (-?[\d.]+) dB", proc.stderr)
    return 10 ** (float(m.group(1)) / 20) if m else 1.0
