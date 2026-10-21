"""Speech-aware processing done in numpy: voice activity, Voice AutoEQ and the adaptive leveler.

The leveler works like an engineer riding a fader: it measures the loudness of each phrase
(400 ms windows, speech frames only), computes the gain that brings it to the programme's typical
level and smooths that gain over ~0.6 s in both directions (zero phase, no pumping). During pauses
the gain is not re-estimated but interpolated between the surrounding phrases, so background noise
is never pulled up the way a classic AGC or `dynaudnorm` does.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

AN_SR = 16000          # analysis rate
HOP = AN_SR // 100     # 10 ms frames


def _db(x):
    return 10 * np.log10(np.maximum(x, 1e-12))


def _power_frames(x: np.ndarray, win: int) -> np.ndarray:
    """Mean power of `win`-sample windows centred on every 10 ms hop."""
    p = np.concatenate([[0.0], np.cumsum(x.astype(np.float64) ** 2)])
    n = len(x) // HOP
    c = np.arange(n) * HOP + HOP // 2
    a = np.clip(c - win // 2, 0, len(x))
    b = np.clip(c + win // 2, 0, len(x))
    return (p[b] - p[a]) / np.maximum(b - a, 1)


def _runs(mask: np.ndarray):
    m = np.concatenate([[False], mask, [False]])
    e = np.flatnonzero(np.diff(m.astype(np.int8)))
    return zip(e[::2], e[1::2])


def voice_activity(x: np.ndarray) -> np.ndarray:
    """Boolean speech mask per 10 ms frame (energy based - meant for already denoised audio)."""
    e = _db(_power_frames(x, 480))
    if len(e) == 0:
        return np.zeros(0, bool)
    floor, peak = np.percentile(e, 10), np.percentile(e, 99.5)
    thr = max(floor + 12, peak - 42)
    v = e > thr
    for a, b in list(_runs(~v)):           # bridge gaps shorter than 200 ms
        if b - a < 20 and a > 0 and b < len(v):
            v[a:b] = True
    for a, b in list(_runs(v)):            # drop clicks shorter than 60 ms
        if b - a < 6:
            v[a:b] = False
    hang = np.convolve(v.astype(float), np.ones(15), "same") > 0   # 150 ms hangover
    return hang


def _zero_phase_smooth(g: np.ndarray, tau_s: float) -> np.ndarray:
    a = 1 - np.exp(-1 / (tau_s * 100))
    out = g.copy()
    for rng in (range(1, len(out)), range(len(out) - 2, -1, -1)):
        prev = out[rng[0] - 1] if rng.step > 0 else out[rng[0] + 1]
        for i in rng:
            prev = prev + a * (out[i] - prev)
            out[i] = prev
    return out


def leveler_curve(x: np.ndarray, vad: np.ndarray, strength: float) -> tuple[np.ndarray, dict]:
    """Gain in dB per 10 ms frame."""
    n = len(vad)
    if n == 0 or vad.sum() < 50:
        return np.zeros(n), {"leveler_range_db": 0.0}
    p = _power_frames(x, 400 * AN_SR // 1000)[:n]
    # loudness of speech only: weight each 400 ms window by its share of speech frames
    k = 40
    sp = np.convolve(p * vad, np.ones(k), "same")
    cnt = np.convolve(vad.astype(float), np.ones(k), "same")
    valid = vad & (cnt >= k * 0.3)
    loud = np.full(n, np.nan)
    loud[valid] = _db(sp[valid] / cnt[valid])
    target = np.percentile(loud[valid], 60)
    max_boost, max_cut = 3 + 13 * strength, 2 + 8 * strength
    g = np.full(n, np.nan)
    g[valid] = np.clip((target - loud[valid]) * strength, -max_cut, max_boost)
    idx = np.flatnonzero(~np.isnan(g))
    g = np.interp(np.arange(n), idx, g[idx])          # pauses: bridge between phrases
    g = _zero_phase_smooth(g, 0.6)
    lo, hi = np.percentile(g[valid], [5, 95])
    return g, {"leveler_range_db": round(float(hi - lo), 1), "speech_level_db": round(float(target), 1)}


# Long-term average speech spectrum (octave bands, dB re 1 kHz; Byrne et al. 1994, both sexes)
LTASS = {125: 4.0, 250: 7.0, 500: 6.0, 1000: 0.0, 2000: -5.0, 4000: -9.0, 8000: -14.0}


def auto_eq(x: np.ndarray, vad: np.ndarray, amount: float = 0.6, limit: float = 4.0) -> list[tuple[int, float]]:
    """Gentle corrective EQ: move the voice's long-term spectrum part of the way towards LTASS."""
    frames = np.flatnonzero(vad)
    if len(frames) < 100:
        return []
    win = 2048
    pick = frames[:: max(1, len(frames) // 600)]
    spec = np.zeros(win // 2 + 1)
    hann = np.hanning(win)
    used = 0
    for f in pick:
        s = f * HOP
        seg = x[s: s + win]
        if len(seg) == win:
            spec += np.abs(np.fft.rfft(seg * hann)) ** 2
            used += 1
    if not used:
        return []
    fq = np.fft.rfftfreq(win, 1 / AN_SR)
    lvl = {c: _db(spec[(fq >= c / 1.414) & (fq < min(c * 1.414, AN_SR / 2 - 100))].sum())
           for c in LTASS}
    ref = lvl[1000]
    out = []
    for c, t in LTASS.items():
        if c == 1000:
            continue
        diff = (t - (lvl[c] - ref)) * amount
        if c == 125:                       # never pump the low end back up
            diff = min(diff, 0)
        if c == 8000:
            diff = min(diff, 3)
        g = float(np.clip(diff, -limit, limit))
        if abs(g) >= 0.75:
            out.append((c, round(g, 1)))
    return out


def apply_gain(src: Path, dst: Path, gain_db: np.ndarray, sr: int, channels: int) -> None:
    """Stream src through a per-sample gain curve (10 ms resolution, linear interpolation)."""
    rd = subprocess.Popen(["ffmpeg", "-v", "error", "-i", str(src), "-f", "f32le", "-ac", str(channels),
                           "-ar", str(sr), "-"], stdout=subprocess.PIPE)
    wr = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(sr), "-ac",
                           str(channels), "-i", "-", "-c:a", "pcm_f32le", str(dst)],
                          stdin=subprocess.PIPE)
    lin = 10 ** (gain_db / 20)
    t_frames = (np.arange(len(lin)) + 0.5) / 100
    chunk = sr  # one second
    pos = 0
    while True:
        buf = rd.stdout.read(chunk * channels * 4)
        if not buf:
            break
        a = np.frombuffer(buf, np.float32).reshape(-1, channels)
        t = (pos + np.arange(len(a))) / sr
        g = np.interp(t, t_frames, lin).astype(np.float32) if len(lin) else np.ones(len(a), np.float32)
        wr.stdin.write((a * g[:, None]).astype(np.float32).tobytes())
        pos += len(a)
    wr.stdin.close()
    if rd.wait() or wr.wait():
        raise RuntimeError("gain stage failed")
