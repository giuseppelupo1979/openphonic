"""Runs the pipeline over every preset and every option combination; one line per run.

Usage: .venv/bin/python scripts/test_matrix.py <audio-or-video-file> [work-dir]
"""
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import pipeline  # noqa: E402
from app.settings import PRESETS, Settings  # noqa: E402

SAMPLES = Path(__file__).resolve().parent.parent / "samples"


def deep(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        out[k] = deep(out.get(k, {}), v) if isinstance(v, dict) else v
    return out


def main() -> int:
    src = Path(sys.argv[1])
    work = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(tempfile.gettempdir()) / "openphonic-web-matrix"
    shutil.rmtree(work, ignore_errors=True)
    runs: list[tuple[str, dict, dict]] = []
    for name, p in PRESETS.items():
        runs.append((f"preset {name}", p, {}))
    for m in ("ai", "rnnoise", "classic"):
        for a in ("auto", "low", "medium", "high", "max"):
            runs.append((f"denoise {m}-{a}", {"denoise": {"method": m, "amount": a}}, {}))
    for c in ("auto", "soft", "medium", "hard", "off"):
        runs.append((f"compressor {c}", {"leveler": {"compressor": c}}, {}))
    everything = {
        "filtering": {"deesser": True, "deplosive": True, "hum": "50", "highpass": "100"},
        "cutting": {"silence": True, "fillers": True},
        "speech": {"enabled": True, "language": "it", "model": "base"},
        "metadata": {"title": "Prova completa", "artist": "OpenPhonic", "album": "Test"},
        "chapters": [{"start": "0", "title": "Inizio"}, {"start": "20", "title": "Dopo"}],
        "outputs": [{"format": f} for f in ("mp3", "aac", "opus", "ogg", "flac", "wav", "video")],
    }
    extras = {}
    if (SAMPLES / "intro.wav").exists():
        extras = {"intro": SAMPLES / "intro.wav", "outro": SAMPLES / "intro.wav"}
    if (SAMPLES / "cover.png").exists():
        extras["cover"] = SAMPLES / "cover.png"
    runs.append(("all options", everything, extras))
    if (SAMPLES / "music.wav").exists():
        runs.append(("multitrack", {"tracks": [{"role": "speech"}, {"role": "music"}]},
                     {"tracks": [src, SAMPLES / "music.wav"]}))

    failed = 0
    for i, (name, over, extra) in enumerate(runs):
        d = work / f"run{i:02d}"
        d.mkdir(parents=True)
        try:
            s = Settings(**deep(Settings().model_dump(), over))
            inp = pipeline.Inputs(tracks=extra.get("tracks", [src]), intro=extra.get("intro"),
                                  outro=extra.get("outro"), cover=extra.get("cover"))
            r = pipeline.process(d, s, inp, lambda *_: None)
            a = r["after"]
            print(f"ok    {name:28} {a['integrated_lufs']:6.1f} LUFS  TP {a['true_peak_dbtp']:5.1f}  "
                  f"LRA {a['lra_lu']:4.1f}  SNR {a['snr_db']:5.1f}  files {len(r['files'])}  "
                  f"{r['processing_seconds']:5.1f} s  {'WARN ' + '; '.join(r['warnings']) if r['warnings'] else ''}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"FAIL  {name:28} {str(e).splitlines()[-1] if str(e) else type(e).__name__}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
