"""The audio post-production pipeline.

Stages (same order Auphonic uses):
  decode -> analyse -> per-track: hum/highpass filtering, de-plosive, noise reduction, de-esser,
  adaptive leveler + compressor -> multitrack mix with music ducking -> speech recognition ->
  silence / filler cutting -> intro + outro -> two-pass EBU R128 loudness normalisation with
  true-peak limiting -> encode every requested output format with metadata, cover and chapters.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import numpy as np

from . import analysis, ffmpeg as ff, leveler, transcribe
from .settings import Output, Settings, parse_time

SR = 48000
BASE_DIR = Path(__file__).resolve().parent.parent
MODEL_DIR = BASE_DIR / "models"

Progress = Callable[[str, float], None]


@dataclass
class Inputs:
    tracks: list[Path]
    intro: Path | None = None
    outro: Path | None = None
    cover: Path | None = None


@dataclass
class Context:
    work: Path
    out: Path
    s: Settings
    report: Progress
    warnings: list[str] = field(default_factory=list)
    log: list[str] = field(default_factory=list)

    def step(self, name: str, pct: float) -> None:
        self.log.append(f"[{time.strftime('%H:%M:%S')}] {name}")
        self.report(name, pct)


# --------------------------------------------------------------------------- filters

# DeepFilterNet attenuation limits (dB) per amount
DENOISE_DB = {"low": 10, "medium": 20, "high": 35, "max": 100}
# compressor threshold relative to the levelled speech RMS, ratio
COMPRESSORS = {"soft": (7, 1.8), "medium": (4, 2.5), "hard": (1, 3.5)}


def deepfilter_bin() -> str | None:
    env = os.environ.get("DEEPFILTER_BIN")
    if env and Path(env).exists():
        return env
    found = shutil.which("deep-filter")
    if found:
        return found
    for p in sorted((BASE_DIR / "bin").glob("deep-filter-*")):
        if os.access(p, os.X_OK):
            return str(p)
    return None


def auto_denoise_db(an: dict) -> float:
    """Attenuation limit from the measured SNR: noisy recordings get more, clean ones a touch."""
    if an["noise_floor_db"] < -75:
        return 0
    return float(np.clip(54 - an["snr_db"], 12, 45))


def speech_prefilter(s: Settings, an: dict, notes: list[str]) -> list[str]:
    f: list[str] = []
    flt = s.filtering
    if not flt.enabled:
        return f
    hp = {"auto": 75, "off": 0}.get(flt.highpass, None)
    hp = int(flt.highpass) if hp is None else hp
    if hp:
        f.append(f"highpass=f={hp}:poles=2")
    hum = None
    if flt.hum == "auto" and an["hum"]["detected"]:
        hum = an["hum"]["base_freq"]
        notes.append(f"Ronzio elettrico a {hum} Hz rilevato e rimosso")
    elif flt.hum in ("50", "60"):
        hum = int(flt.hum)
    if hum:
        for k in range(1, 5):
            f.append(f"equalizer=f={hum * k}:t=q:w=30:g=-{24 if k < 3 else 15}")
    if flt.deplosive:
        # threshold is a linear amplitude: trigger on low-frequency bursts that come
        # within 4 dB of the voice's typical peak level
        thr = min(1.0, max(0.001, 10 ** ((an["signal_level_db"] - 4) / 20)))
        f.append(f"adynamicequalizer=threshold={thr:.4f}:dfrequency=110:dqfactor=0.8:tfrequency=110:"
                 "tqfactor=0.8:attack=1:release=80:ratio=4:range=18:mode=cutabove:tftype=lowshelf")
    return f


def process_speech(ctx: "Context", src: Path, an: dict, dst: Path, channels: int,
                   notes: list[str]) -> None:
    """Voice chain: mono -> filters -> denoise -> AutoEQ / de-ess -> leveler -> compressor."""
    s, w = ctx.s, ctx.work
    tag = dst.stem
    # 1. mono voice + corrective filters, headroom for the 16-bit denoiser
    a = w / f"{tag}_a.wav"
    pre = speech_prefilter(s, an, notes)
    ff.run(["-i", str(src), "-af", ",".join(pre + ["pan=mono|c0=0.5*c0+0.5*c1" if channels == 2
                                                    else "anull"]),
            "-ac", "1", "-ar", str(SR), "-c:a", "pcm_f32le", str(a)])
    peak = ff.peak(a)
    if peak > 0.7:
        b = w / f"{tag}_a2.wav"
        ff.run(["-i", str(a), "-af", f"volume={0.7 / peak:.4f}", "-c:a", "pcm_f32le", str(b)])
        b.replace(a)

    # 2. noise reduction
    dn = s.denoise
    cur = a
    if dn.enabled:
        nr = auto_denoise_db(an) if dn.amount == "auto" else DENOISE_DB[dn.amount]
        method = dn.method
        binary = deepfilter_bin()
        if method == "ai" and not binary:
            method = "rnnoise"
            ctx.warnings.append("DeepFilterNet non installato: uso RNNoise")
        if nr:
            out = w / f"{tag}_dn.wav"
            if method == "ai":
                odir = w / f"{tag}_df"
                odir.mkdir(exist_ok=True)
                proc = subprocess.run([binary, "-D", "-a", f"{nr:.0f}", "-o", str(odir), str(cur)],
                                      capture_output=True, text=True)
                if proc.returncode:
                    raise ff.FFmpegError("DeepFilterNet failed: " + proc.stderr[-400:])
                (odir / cur.name).replace(out)
                label = "AI (DeepFilterNet)"
            elif method == "rnnoise":
                mix = min(1.0, 0.4 + nr / 40)
                ff.run(["-i", str(cur), "-af", f"arnndn=m={MODEL_DIR / 'std.rnnn'}:mix={mix:.2f}",
                        "-c:a", "pcm_f32le", str(out)])
                label = "RNNoise"
            else:
                nf = max(-80, min(-20, an["noise_floor_db"]))
                # spectral subtraction gets "underwater" past ~25 dB: its own, gentler scale
                nr = {"low": 6, "medium": 12, "high": 18, "max": 25}.get(dn.amount, min(18, nr * 0.5))
                # learn the noise print from the quietest half second, like a manual noise profile
                rms = analysis.frame_rms(ff.read_mono(cur), 8000, 1600)
                q = float(np.argmin(rms)) * 0.1
                sample = f"asendcmd=c='{q:.2f} afftdn sn start; {q + 0.5:.2f} afftdn sn stop',"
                ff.run(["-i", str(cur), "-af", sample + f"afftdn=nr={nr:.0f}:nf={nf:.0f}:tn=1",
                        "-c:a", "pcm_f32le", str(out)])
                label = "spettrale"
            cur = out
            notes.append(f"Riduzione rumore {label}: fino a {nr:.0f} dB"
                         + (f" (SNR originale {an['snr_db']:.0f} dB)" if dn.amount == "auto" else ""))
        else:
            notes.append("Registrazione già pulita: nessuna riduzione rumore necessaria")

    # analysis on the cleaned voice drives EQ and leveler
    x16 = ff.read_mono(cur, leveler.AN_SR)
    vad = leveler.voice_activity(x16)

    # 3. Voice AutoEQ + de-esser
    tone: list[str] = []
    if s.filtering.enabled and s.filtering.autoeq:
        eq = leveler.auto_eq(x16, vad)
        if analysis.noise_profile(x16)["snr_db"] < 25:
            # still noisy: lifting the highs would lift the hiss with them
            eq = [(c, g) for c, g in eq if not (c >= 2000 and g > 0)]
        tone += [f"equalizer=f={c}:t=o:w=1:g={g}" for c, g in eq]
        if eq:
            notes.append("Voice AutoEQ: " + ", ".join(
                f"{c if c < 1000 else str(c // 1000) + 'k'}Hz {g:+.1f} dB" for c, g in eq))
    if s.filtering.enabled and s.filtering.deesser:
        tone.append("deesser=i=0.4:m=0.5:f=0.5:s=o")
    if tone:
        out = w / f"{tag}_eq.wav"
        ff.run(["-i", str(cur), "-af", ",".join(tone), "-c:a", "pcm_f32le", str(out)])
        cur = out
        if s.leveler.enabled:
            x16 = ff.read_mono(cur, leveler.AN_SR)

    # 4. adaptive leveler + compressor
    lev = s.leveler
    if lev.enabled and lev.strength > 0:
        g, info = leveler.leveler_curve(x16, vad, lev.strength / 100)
        out = w / f"{tag}_lev.wav"
        leveler.apply_gain(cur, out, g, SR, 1)
        cur = out
        notes.append(f"Adaptive Leveler: livelli bilanciati su {info['leveler_range_db']} dB di escursione")
        comp = lev.compressor
        if comp == "auto":
            comp = "medium" if info["leveler_range_db"] > 8 else "soft"
        if comp != "off" and "speech_level_db" in info:
            off, ratio = COMPRESSORS[comp]
            thr = info["speech_level_db"] + off
            out = w / f"{tag}_comp.wav"
            ff.run(["-i", str(cur), "-af",
                    f"acompressor=threshold={thr:.1f}dB:ratio={ratio}:attack=8:release=140:knee=6:"
                    "detection=rms:makeup=1", "-c:a", "pcm_f32le", str(out)])
            cur = out

    ff.run(["-i", str(cur), "-ac", str(channels), "-ar", str(SR), "-c:a", "pcm_f32le", str(dst)])


def music_filters(s: Settings) -> list[str]:
    return ["dynaudnorm=f=1000:g=31:p=0.95:m=4"] if s.leveler.enabled else []


# --------------------------------------------------------------------------- helpers

def intervals_merge(iv: list[tuple[float, float]]) -> list[tuple[float, float]]:
    out: list[list[float]] = []
    for a, b in sorted(iv):
        if b <= a:
            continue
        if out and a <= out[-1][1] + 0.01:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def make_time_map(cuts: list[tuple[float, float]]) -> Callable[[float], float]:
    def fn(t: float) -> float:
        removed = 0.0
        for a, b in cuts:
            if t >= b:
                removed += b - a
            elif t > a:
                return round(a - removed, 3)
            else:
                break
        return round(t - removed, 3)
    return fn


def apply_cuts(src: Path, dst: Path, cuts: list[tuple[float, float]], duration: float) -> None:
    keep, pos = [], 0.0
    for a, b in cuts:
        if a > pos:
            keep.append((pos, a))
        pos = b
    if pos < duration:
        keep.append((pos, duration + 1))
    # 10 ms fade to silence on both sides of every splice, then cut at 1 ms precision:
    # joins land on silence, so no clicks even when cutting inside speech (fillers)
    g = np.zeros(int(duration * 100) + 2)
    for a, b in cuts:
        for t in (a, b):
            i = int(np.floor(t * 100 - 0.5))      # the two 10 ms frame centres around t
            g[max(0, i): max(0, i + 2)] = -90.0
    faded = dst.with_name(dst.stem + "_fade.wav")
    leveler.apply_gain(src, faded, g, SR, ff.probe(src)["channels"])
    expr = "+".join(f"between(t,{a:.3f},{b:.3f})" for a, b in keep)
    ff.run(["-i", str(faded), "-af", f"asetnsamples=n=48,aselect='{expr}',asetpts=N/SR/TB",
            "-c:a", "pcm_f32le", str(dst)])


def ffmeta_escape(v: str) -> str:
    return "".join("\\" + c if c in "=;#\\\n" else c for c in v)


def write_ffmetadata(path: Path, s: Settings, chapters: list[tuple[float, str]], total: float) -> None:
    lines = [";FFMETADATA1"]
    md = s.metadata.model_dump()
    for k, v in md.items():
        if v:
            key = {"artist": "artist", "year": "date"}.get(k, k)
            lines.append(f"{key}={ffmeta_escape(str(v))}")
    for i, (start, title) in enumerate(chapters):
        end = chapters[i + 1][0] if i + 1 < len(chapters) else total
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={int(start * 1000)}",
                  f"END={int(end * 1000)}", f"title={ffmeta_escape(title)}"]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


EXT = {"mp3": "mp3", "aac": "m4a", "opus": "opus", "ogg": "ogg", "flac": "flac", "wav": "wav",
       "video": "mp4"}


def encode(ctx: Context, final: Path, o: Output, channels: int, meta: Path, cover: Path | None,
           stem: str, video: dict | None) -> str:
    name = f"{stem}.{EXT[o.format]}"
    if o.format in ("mp3", "aac") and any(x.format == o.format for x in ctx.s.outputs if x is not o):
        name = f"{stem}-{o.bitrate}k.{EXT[o.format]}"
    dst = ctx.out / name
    ch = {"keep": channels, "mono": 1, "stereo": 2}[o.channels]
    a = ["-ac", str(ch)]
    if o.sample_rate:
        a += ["-ar", str(o.sample_rate)]

    if o.format == "video":
        if not video:
            ctx.warnings.append("Uscita video richiesta ma l'ingresso non contiene video: saltata")
            return ""
        args = ["-i", video["src"], "-i", str(final), "-i", str(meta)]
        if video["filter"]:
            args += ["-vf", video["filter"], "-c:v", "libx264", "-preset", "veryfast",
                     "-crf", "20", "-pix_fmt", "yuv420p"]
        else:
            args += ["-c:v", "copy"] + (["-tag:v", "hvc1"] if video["codec"] == "hevc" else [])
        args += ["-map", "0:v:0", "-map", "1:a", "-map_metadata", "2", "-map_chapters", "2",
                 "-c:a", "aac", "-b:a", f"{max(o.bitrate, 128)}k", *a, "-movflags", "+faststart",
                 "-t", f"{video['duration']:.3f}", str(dst)]
        ff.run(args)
        return name

    args = ["-i", str(final), "-i", str(meta)]
    with_cover = cover is not None and o.format in ("mp3", "aac", "flac")
    if with_cover:
        args += ["-i", str(cover)]
    args += ["-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
    if with_cover:
        args += ["-map", "2:v", "-c:v", "mjpeg" if o.format != "flac" else "copy",
                 "-disposition:v", "attached_pic", "-metadata:s:v", "title=Album cover",
                 "-metadata:s:v", "comment=Cover (front)"]
    codec = {
        "mp3": ["-c:a", "libmp3lame", "-b:a", f"{o.bitrate}k", "-id3v2_version", "3"],
        "aac": ["-c:a", "aac", "-b:a", f"{o.bitrate}k", "-movflags", "+faststart"],
        "opus": ["-c:a", "libopus", "-b:a", f"{o.bitrate}k", "-vbr", "on"],
        "ogg": ["-c:a", "vorbis", "-strict", "experimental", "-b:a", f"{o.bitrate}k",
                "-ac", "2"],
        "flac": ["-c:a", "flac", "-sample_fmt", "s32"],
        "wav": ["-c:a", "pcm_s24le"],
    }[o.format]
    if o.format == "opus" and o.sample_rate:
        a = a[:2]  # opus is always 48 kHz
    ff.run(args + a + codec + [str(dst)])
    return name


def spectrogram(src: Path, dst: Path) -> None:
    ff.run(["-i", str(src), "-lavfi",
            "showspectrumpic=s=1100x240:legend=0:color=intensity:scale=log:fscale=lin:stop=12000",
            "-frames:v", "1", str(dst)])


# --------------------------------------------------------------------------- main entry

def process(job_dir: Path, s: Settings, inp: Inputs, report: Progress) -> dict:
    work, out = job_dir / "work", job_dir / "output"
    work.mkdir(exist_ok=True)
    out.mkdir(exist_ok=True)
    ctx = Context(work, out, s, report)
    t0 = time.time()

    # ---- decode + analyse
    ctx.step("Analyzing input", 3)
    probes = [ff.probe(p) for p in inp.tracks]
    main = probes[0]
    channels = min(2, max(p["channels"] for p in probes))
    roles = [(s.tracks[i] if i < len(s.tracks) else None) for i in range(len(inp.tracks))]
    roles = [r.role if r else "speech" for r in roles]
    if roles and all(r == "music" for r in roles):
        roles[0] = "speech" if len(roles) > 1 else "music"

    decoded, analyses = [], []
    for i, src in enumerate(inp.tracks):
        wav = work / f"track{i}.wav"
        ff.decode_to_wav(src, wav, channels)
        x = ff.read_mono(wav)
        an = analysis.analyze(x)
        an.update(ff.loudness_stats(wav))
        an["lra"] = an["lra_lu"]
        an["peaks"] = analysis.waveform_peaks(x)
        decoded.append(wav)
        analyses.append(an)
        ctx.step(f"Analyzed track {i + 1}/{len(inp.tracks)}", 3 + 7 * (i + 1) / len(inp.tracks))
    spectrogram(decoded[0], out / "spectrum_before.png")

    # ---- per-track processing
    processed, notes = [], []
    for i, wav in enumerate(decoded):
        tnotes: list[str] = []
        dst = work / f"proc{i}.wav"
        if roles[i] == "speech":
            process_speech(ctx, wav, analyses[i], dst, channels, tnotes)
        elif music_filters(s):
            ff.run(["-i", str(wav), "-af", ",".join(music_filters(s)), "-ar", str(SR),
                    "-c:a", "pcm_f32le", str(dst)])
        else:
            shutil.copy(wav, dst)
        processed.append(dst)
        prefix = f"Traccia {i + 1}: " if len(decoded) > 1 else ""
        notes += [prefix + n for n in tnotes]
        ctx.step(f"Processed track {i + 1}/{len(decoded)} ({roles[i]})",
                 10 + 35 * (i + 1) / len(decoded))

    # ---- multitrack mix
    mixed = work / "mixed.wav"
    if len(processed) == 1:
        shutil.copy(processed[0], mixed)
    else:
        ctx.step("Mixing tracks", 47)
        speech = [i for i, r in enumerate(roles) if r == "speech"]
        music = [i for i, r in enumerate(roles) if r == "music"]
        args: list[str] = []
        for p in processed:
            args += ["-i", str(p)]
        graph = []
        sp = "".join(f"[{i}:a]" for i in speech)
        graph.append(f"{sp}amix=inputs={len(speech)}:normalize=0:duration=longest[sp]"
                     if len(speech) > 1 else f"{sp}anull[sp]")
        if music:
            # music sits ~8 LU under the speech, and is ducked further while someone talks
            sp_lufs = max(ff.loudness_stats(processed[i])["integrated_lufs"] for i in speech)
            mu = "".join(
                f"[{i}:a]volume={(sp_lufs - 8) - ff.loudness_stats(processed[i])['integrated_lufs']:.1f}dB[m{i}];"
                for i in music)
            graph.append(mu + "".join(f"[m{i}]" for i in music) +
                         (f"amix=inputs={len(music)}:normalize=0:duration=longest[mu]"
                          if len(music) > 1 else "anull[mu]"))
            if s.ducking:
                amt = abs(s.ducking_amount_db)
                ratio = 2 if amt <= 6 else 4 if amt <= 10 else 8 if amt <= 16 else 20
                graph.append("[sp]asplit=2[sp1][key]")
                graph.append(f"[mu][key]sidechaincompress=threshold=0.015:ratio={ratio}:"
                             "attack=60:release=900:makeup=1[duck]")
                graph.append("[sp1][duck]amix=inputs=2:normalize=0:duration=longest[out]")
            else:
                graph.append("[sp][mu]amix=inputs=2:normalize=0:duration=longest[out]")
        else:
            graph.append("[sp]anull[out]")
        ff.run(args + ["-filter_complex", ";".join(graph), "-map", "[out]",
                       "-c:a", "pcm_f32le", str(mixed)])
        if music:
            notes.append(f"Mixate {len(speech)} tracce voce + {len(music)} musica"
                         + (", musica abbassata sotto il parlato (ducking)" if s.ducking else ""))
    mixed_dur = ff.probe(mixed)["duration"]

    # ---- speech recognition
    transcript = None
    want_asr = s.speech.enabled or s.cutting.fillers
    if want_asr and not transcribe.available():
        ctx.warnings.append("Riconoscimento vocale non installato su questo server: "
                            "trascrizione e taglio riempitivi saltati")
    elif want_asr:
        ctx.step(f"Speech recognition (Whisper {s.speech.model})", 50)
        transcript = transcribe.transcribe(
            mixed, s.speech.model, s.speech.language, keep_fillers=s.cutting.fillers,
            progress=lambda f: ctx.report(f"Speech recognition (Whisper {s.speech.model})",
                                          50 + 20 * f))
        notes.append(f"Trascritti {len(transcript['segments'])} segmenti "
                     f"(lingua: {transcript['language']})")

    # ---- cutting
    cuts: list[tuple[float, float]] = []
    if s.cutting.silence:
        ctx.step("Detecting silence", 71)
        keep = s.cutting.keep_silence
        thr = s.cutting.silence_threshold_db
        xm = ff.read_mono(mixed)
        if thr is None:
            npf = analysis.noise_profile(xm)
            thr = round(min(-25.0, max(npf["noise_floor_db"] + 10, npf["signal_level_db"] - 32)), 1)
        for a, b in analysis.find_silences(xm, thr, s.cutting.min_silence):
            if b - a > keep:
                cuts.append((a + keep / 2, b - keep / 2))
    n_fill = 0
    if s.cutting.fillers and transcript:
        for seg in transcript["segments"]:
            for w in seg["words"]:
                if transcribe.is_filler(w["word"]):
                    cuts.append((max(0, w["start"] - 0.03), w["end"] + 0.05))
                    n_fill += 1
    cuts = intervals_merge(cuts)
    tmap = make_time_map(cuts)
    cut_total = sum(b - a for a, b in cuts)
    body = mixed
    if cuts:
        ctx.step("Cutting silence and fillers", 74)
        body = work / "cut.wav"
        apply_cuts(mixed, body, cuts, mixed_dur)
        notes.append(f"Tagliati {cut_total:.1f} s ({len(cuts)} tagli"
                     + (f", {n_fill} parole riempitive" if n_fill else "") + ")")

    # ---- intro / outro
    intro_dur = 0.0
    assembled = body
    if inp.intro or inp.outro:
        ctx.step("Adding intro / outro", 77)
        parts = []
        for tag, p in (("intro", inp.intro), (None, body), ("outro", inp.outro)):
            if p is None:
                continue
            if tag:
                w = work / f"{tag}.wav"
                ff.decode_to_wav(p, w, channels)
                if tag == "intro":
                    intro_dur = ff.probe(w)["duration"]
                parts.append(w)
            else:
                parts.append(p)
        assembled = work / "assembled.wav"
        args = []
        for p in parts:
            args += ["-i", str(p)]
        graph = "".join(f"[{i}:a]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1[o]"
        ff.run(args + ["-filter_complex", graph, "-map", "[o]", "-c:a", "pcm_f32le", str(assembled)])

    # ---- loudness normalisation
    final = work / "final.wav"
    ln = s.loudness
    gain = 0.0
    if ln.enabled:
        ctx.step(f"Loudness normalization to {ln.target} LUFS", 82)
        dm = ln.dual_mono and channels == 1
        # linear gain to target + oversampled (true-peak) limiter; the limiter shaves a little
        # loudness off, so iterate until we are within 0.2 LU of the target
        ceiling = 10 ** ((ln.true_peak - 0.2) / 20)
        src = assembled
        for it in range(3):
            measured = ff.loudnorm_measure(src, dual_mono=dm)["input_i"]
            delta = ln.target - measured
            if it and abs(delta) < 0.2:
                break
            gain += delta
            dst = work / f"loud{it}.wav"
            ff.run(["-i", str(assembled), "-af",
                    f"volume={gain:.2f}dB,aresample={SR * 4},alimiter=limit={ceiling:.4f}:"
                    f"level=false:attack=2:release=60:asc=1,aresample={SR}",
                    "-c:a", "pcm_f32le", str(dst)])
            src = dst
        src.replace(final)
    else:
        ff.run(["-i", str(assembled), "-af", "alimiter=limit=0.89:level=false", "-c:a", "pcm_f32le",
                str(final)])
    final_dur = ff.probe(final)["duration"]

    # ---- chapters / metadata
    chapters = sorted((tmap(parse_time(c.start)) + intro_dur, c.title) for c in s.chapters)
    meta = work / "meta.ffmeta"
    write_ffmetadata(meta, s, chapters, final_dur)

    # ---- encode outputs
    stem = "".join(c if c.isalnum() or c in "-_ " else "_" for c in
                   (s.metadata.title or inp.tracks[0].stem)).strip().replace(" ", "_")[:80] or "output"
    video = None
    if main["has_video"]:
        vf = []
        if cuts:
            keep, pos = [], 0.0
            for a, b in cuts:
                if a > pos:
                    keep.append((pos, a))
                pos = b
            keep.append((pos, mixed_dur + 1))
            vf.append("select='" + "+".join(f"between(t,{a:.3f},{b:.3f})" for a, b in keep)
                      + "',setpts=N/FRAME_RATE/TB")
        if intro_dur or inp.outro:
            vf.append(f"tpad=start_duration={intro_dur:.3f}:stop_duration=3600:color=black")
        video = {"src": str(inp.tracks[0]), "filter": ",".join(vf) if vf else None,
                 "duration": final_dur, "codec": main["video_codec"]}

    files = []
    for i, o in enumerate(s.outputs):
        ctx.step(f"Encoding {o.format.upper()}", 86 + 8 * i / max(1, len(s.outputs)))
        name = encode(ctx, final, o, channels, meta, inp.cover, stem, video)
        if name:
            files.append({"name": name, "format": o.format,
                          "size": (out / name).stat().st_size})

    if transcript:
        t = transcribe.remap(transcript, lambda x: tmap(x) + intro_dur, s.cutting.fillers)
        for n in transcribe.write_files(t, out, stem):
            files.append({"name": n, "format": n.rsplit(".", 1)[1], "size": (out / n).stat().st_size})

    # ---- after stats
    ctx.step("Measuring result", 96)
    xf = ff.read_mono(final)
    # pauses removed by cutting would make the noise estimate meaningless: measure noise on the
    # uncut programme brought to the same output gain
    noise = analysis.noise_profile(ff.read_mono(mixed) * 10 ** (gain / 20) if cuts else xf)
    after = {**noise, **ff.loudness_stats(final),
             "duration": round(final_dur, 2), "peaks": analysis.waveform_peaks(xf)}
    spectrogram(final, out / "spectrum_after.png")
    ff.run(["-i", str(final), "-ac", str(channels), "-c:a", "libmp3lame", "-b:a", "128k",
            str(out / "_preview_after.mp3")])
    ff.run(["-i", str(decoded[0]), "-ac", str(channels), "-c:a", "libmp3lame", "-b:a", "128k",
            str(out / "_preview_before.mp3")])

    before = analyses[0]
    result = {
        "files": files,
        "notes": notes,
        "warnings": ctx.warnings,
        "input": {**main, "tracks": len(inp.tracks), "roles": roles},
        "before": {k: v for k, v in before.items() if k != "lra"},
        "after": after,
        "tracks_analysis": [{k: v for k, v in a.items() if k not in ("peaks", "lra")}
                            for a in analyses],
        "cuts": {"count": len(cuts), "seconds": round(cut_total, 2), "fillers": n_fill},
        "chapters": [{"start": round(t, 3), "title": n} for t, n in chapters],
        "processing_seconds": round(time.time() - t0, 1),
        "log": ctx.log,
    }
    (job_dir / "result.json").write_text(json.dumps(result, indent=1))
    shutil.rmtree(work, ignore_errors=True)
    ctx.step("Done", 100)
    return result
