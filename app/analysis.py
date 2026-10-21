"""Signal analysis used to drive the adaptive ("auto") processing decisions."""
from __future__ import annotations

import numpy as np

SR = 16000


def _db(x: np.ndarray | float) -> np.ndarray | float:
    return 20 * np.log10(np.maximum(x, 1e-9))


def frame_rms(x: np.ndarray, frame: int, hop: int) -> np.ndarray:
    if len(x) < frame:
        return np.array([np.sqrt(np.mean(x ** 2))]) if len(x) else np.array([0.0])
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    return np.sqrt(np.mean(x[idx] ** 2, axis=1))


def noise_profile(x: np.ndarray) -> dict:
    """Estimate noise floor / speech level from 50 ms RMS frames."""
    rms = frame_rms(x, SR // 20, SR // 40)
    active = rms[rms > 1e-6]
    if active.size == 0:
        return {"noise_floor_db": -99.0, "signal_level_db": -99.0, "snr_db": 0.0}
    floor = float(_db(np.percentile(active, 10)))
    level = float(_db(np.percentile(active, 95)))
    return {
        "noise_floor_db": round(floor, 1),
        "signal_level_db": round(level, 1),
        "snr_db": round(level - floor, 1),
    }


def detect_hum(x: np.ndarray) -> dict:
    """Look for mains hum (50/60 Hz + harmonics) in the quietest one-second frames."""
    frame, hop = SR, SR // 2
    if len(x) < frame:
        return {"detected": False, "base_freq": None, "strength_db": 0.0}
    rms = frame_rms(x, frame, hop)
    n_pick = max(3, int(len(rms) * 0.3))
    quiet = np.argsort(rms)[:n_pick]
    win = np.hanning(frame)
    spec = np.zeros(frame // 2 + 1)
    for i in quiet:
        seg = x[i * hop: i * hop + frame]
        spec += np.abs(np.fft.rfft(seg * win)) ** 2
    spec /= len(quiet)

    def score(f0: int) -> float:
        vals = []
        for k in range(1, 5):
            f = f0 * k
            peak = spec[f - 1: f + 2].max()
            neigh = np.concatenate([spec[f - 15: f - 3], spec[f + 4: f + 16]])
            vals.append(10 * np.log10(peak / max(np.median(neigh), 1e-20)))
        return float(np.mean(sorted(vals)[-3:]))  # tolerate one missing harmonic

    s50, s60 = score(50), score(60)
    base, strength = (50, s50) if s50 >= s60 else (60, s60)
    detected = strength > 9.0
    return {"detected": detected, "base_freq": base if detected else None,
            "strength_db": round(strength, 1)}


def waveform_peaks(x: np.ndarray, points: int = 1200) -> list[float]:
    """Max-abs envelope, normalised to the file's own peak range [0..1]."""
    if len(x) == 0:
        return []
    chunk = max(1, len(x) // points)
    n = len(x) // chunk
    env = np.abs(x[: n * chunk]).reshape(n, chunk).max(axis=1)
    return [round(float(v), 4) for v in np.clip(env, 0, 1)]


def analyze(x: np.ndarray) -> dict:
    return {**noise_profile(x), "hum": detect_hum(x), "duration": round(len(x) / SR, 2)}


def find_silences(x: np.ndarray, threshold_db: float, min_dur: float) -> list[tuple[float, float]]:
    """Pauses = runs of 20 ms frames whose RMS stays under the threshold for >= min_dur seconds."""
    hop = SR // 50
    rms = _db(frame_rms(x, hop, hop))
    quiet = np.concatenate([[False], rms < threshold_db, [False]])
    edges = np.flatnonzero(np.diff(quiet.astype(np.int8)))
    out = []
    for a, b in zip(edges[::2], edges[1::2]):
        if (b - a) * hop / SR >= min_dur:
            out.append((a * hop / SR, b * hop / SR))
    return out
