"""Production settings (mirrors Auphonic's algorithm / output options)."""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class Leveler(BaseModel):
    enabled: bool = True
    strength: int = Field(100, ge=0, le=100)          # % of leveling
    compressor: Literal["auto", "soft", "medium", "hard", "off"] = "auto"


class Filtering(BaseModel):
    enabled: bool = True
    highpass: Literal["auto", "off", "60", "80", "100", "120"] = "auto"
    hum: Literal["auto", "off", "50", "60"] = "auto"
    deesser: bool = False
    deplosive: bool = False
    autoeq: bool = True                               # Voice AutoEQ


class Denoise(BaseModel):
    enabled: bool = True
    method: Literal["ai", "rnnoise", "classic"] = "ai"
    amount: Literal["auto", "low", "medium", "high", "max"] = "auto"


class Loudness(BaseModel):
    enabled: bool = True
    target: float = Field(-16.0, ge=-31, le=-5)       # LUFS
    true_peak: float = Field(-1.0, ge=-6, le=0)       # dBTP
    dual_mono: bool = False


class Cutting(BaseModel):
    silence: bool = False
    silence_threshold_db: Optional[float] = None    # None = adaptive
    min_silence: float = Field(1.0, ge=0.2, le=10)    # pauses longer than this get shortened
    keep_silence: float = Field(0.4, ge=0.0, le=3)    # how much pause to keep
    fillers: bool = False                             # needs speech recognition


class Speech(BaseModel):
    enabled: bool = False
    language: str = "auto"
    model: Literal["tiny", "base", "small", "medium", "large-v3"] = "base"


class Output(BaseModel):
    format: Literal["mp3", "aac", "opus", "ogg", "flac", "wav", "video"] = "mp3"
    bitrate: int = Field(128, ge=32, le=320)          # kbps (lossy only)
    channels: Literal["keep", "mono", "stereo"] = "keep"
    sample_rate: Literal[0, 22050, 44100, 48000] = 0  # 0 = keep 48 kHz pipeline rate


class Chapter(BaseModel):
    start: str        # "HH:MM:SS(.mmm)" or seconds
    title: str


class Metadata(BaseModel):
    title: str = ""
    artist: str = ""
    album: str = ""
    year: str = ""
    genre: str = "Podcast"
    comment: str = ""
    track: str = ""


class TrackRole(BaseModel):
    role: Literal["speech", "music"] = "speech"
    process: bool = True                              # run per-track algorithms


class Settings(BaseModel):
    leveler: Leveler = Leveler()
    filtering: Filtering = Filtering()
    denoise: Denoise = Denoise()
    loudness: Loudness = Loudness()
    cutting: Cutting = Cutting()
    speech: Speech = Speech()
    outputs: list[Output] = [Output()]
    metadata: Metadata = Metadata()
    chapters: list[Chapter] = []
    tracks: list[TrackRole] = []                      # one entry per uploaded track (multitrack)
    ducking: bool = True                              # duck music under speech in multitrack
    ducking_amount_db: float = Field(-12, ge=-30, le=0)


def parse_time(t: str | float) -> float:
    if isinstance(t, (int, float)):
        return float(t)
    t = t.strip()
    parts = [float(p) for p in t.split(":")]
    sec = 0.0
    for p in parts:
        sec = sec * 60 + p
    return sec


PRESETS: dict[str, dict] = {
    "Podcast (−16 LUFS)": {},
    "Broadcast EBU R128 (−23 LUFS)": {"loudness": {"target": -23, "true_peak": -1}},
    "YouTube / Spotify (−14 LUFS)": {"loudness": {"target": -14, "true_peak": -1}},
    "Audiobook ACX (−19 LUFS mono)": {
        "loudness": {"target": -19, "true_peak": -3},
        "outputs": [{"format": "mp3", "bitrate": 192, "channels": "mono", "sample_rate": 44100}],
    },
    "Interview cleanup (strong)": {
        "denoise": {"amount": "high"},
        "filtering": {"deesser": True, "deplosive": True},
        "cutting": {"silence": True},
    },
    "Music (gentle)": {
        "leveler": {"strength": 40, "compressor": "soft"},
        "filtering": {"highpass": "off"},
        "denoise": {"enabled": False},
        "tracks": [{"role": "music"}],
        "outputs": [{"format": "flac"}, {"format": "mp3", "bitrate": 256}],
    },
}
