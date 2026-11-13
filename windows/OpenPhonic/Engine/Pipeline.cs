using System.IO;

namespace OpenPhonic.Engine;

public sealed record AudioStats(double Integrated, double TruePeak, double Lra, double NoiseFloor, double Snr, double Duration);

public sealed record ProductionResult(
    AudioStats Before, AudioStats After, float[] PeaksBefore, float[] PeaksAfter,
    List<string> Notes, List<string> Warnings, List<string> Files,
    string PreviewBefore, string PreviewAfter, string SpectrumBefore, string SpectrumAfter,
    List<Transcriber.Segment> Transcript, double Seconds, bool HasVideo);

public sealed record ProductionInput(string Source, string? Intro, string? Outro, string? Cover, string OutputDir, string WorkDir);

/// <summary>
/// Same processing chain as the Mac and web versions:
/// mono voice → filters → DeepFilterNet → AutoEQ / de-ess → phrase leveler → compressor
/// → transcription → silence / filler cuts → intro + outro → exact loudness → encode.
/// </summary>
public sealed class Pipeline(ProductionSettings s, ProductionInput input, Action<string, double> progress, CancellationToken ct)
{
    const int SR = 48000;
    readonly List<string> notes = [];
    readonly List<string> warnings = [];

    string W(string name) => Path.Combine(input.WorkDir, name);
    static string F(double v, int d = 2) => FF.F(v, d);

    void Step(string name, double p)
    {
        ct.ThrowIfCancellationRequested();
        progress(name, p);
    }

    void Ff(params string[] args) => Tools.FfmpegRun(args, ct);

    public async Task<ProductionResult> Run()
    {
        var t0 = DateTime.Now;
        Directory.CreateDirectory(input.WorkDir);
        Directory.CreateDirectory(input.OutputDir);

        // ---- analysis
        Step("Analisi del file", 0.03);
        var info = FF.Probe(input.Source);
        int channels = Math.Min(2, info.Channels);
        var track = W("track.wav");
        FF.Decode(input.Source, track, channels);
        var x0 = FF.ReadMono(track);
        var np0 = Analysis.Noise(x0);
        var hum = Analysis.DetectHum(x0);
        var ln0 = FF.MeasureLoudness(track);
        var before = new AudioStats(ln0.Integrated, ln0.TruePeak, ln0.Lra, np0.NoiseFloor, np0.Snr, info.Duration);
        var peaksBefore = Analysis.Peaks(x0);
        FF.Spectrogram(track, W("spectrum_before.png"));
        Step("Analisi completata", 0.1);

        // ---- per-track processing
        var proc = W("proc.wav");
        if (s.Content == Content.Speech) ProcessSpeech(track, proc, np0, hum, channels);
        else if (s.LevelerOn) Ff("-i", track, "-af", "dynaudnorm=f=1000:g=31:p=0.95:m=4", "-c:a", "pcm_f32le", proc);
        else File.Copy(track, proc, true);

        // ---- transcription
        var transcript = new List<Transcriber.Segment>();
        if (s.Transcribe || s.CutFillers)
        {
            Step("Trascrizione vocale", 0.55);
            try
            {
                transcript = await Transcriber.Transcribe(FF.ReadMono(proc), s.Language, s.WhisperModel, s.CutFillers,
                    st => progress(st, 0.55), f => progress("Trascrizione vocale", 0.55 + 0.1 * f), ct).ConfigureAwait(false);
                notes.Add($"Trascritti {transcript.Count} segmenti");
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception e)
            {
                warnings.Add($"Trascrizione non riuscita: {e.Message}");
            }
        }

        // ---- cuts
        var cuts = new List<(double A, double B)>();
        if (s.CutSilence)
        {
            Step("Ricerca delle pause", 0.66);
            var xm = FF.ReadMono(proc);
            var np = Analysis.Noise(xm);
            double thr = Math.Min(-25, Math.Max(np.NoiseFloor + 10, np.SignalLevel - 32));
            foreach (var (a, b) in Analysis.Silences(xm, thr, s.MinSilence))
                if (b - a > s.KeepSilence) cuts.Add((a + s.KeepSilence / 2, b - s.KeepSilence / 2));
        }
        int fillerCount = 0;
        if (s.CutFillers)
            foreach (var w in transcript.SelectMany(t => t.Words).Where(w => Transcriber.IsFiller(w.Text)))
            {
                cuts.Add((Math.Max(0, w.Start - 0.03), w.End + 0.05));
                fillerCount++;
            }
        cuts = Merge(cuts);
        double cutTotal = cuts.Sum(c => c.B - c.A);
        var body = proc;
        if (cuts.Count > 0)
        {
            Step("Taglio di pause e riempitivi", 0.7);
            body = W("cut.wav");
            ApplyCuts(proc, body, cuts, FF.Duration(proc), channels);
            notes.Add($"Tagliati {F(cutTotal, 1)} s ({cuts.Count} tagli{(fillerCount > 0 ? $", {fillerCount} parole riempitive" : "")})");
        }

        // ---- intro / outro
        double introDur = 0;
        var assembled = body;
        if (input.Intro != null || input.Outro != null)
        {
            Step("Intro e outro", 0.74);
            var parts = new List<string>();
            if (input.Intro != null)
            {
                var u = W("intro.wav"); FF.Decode(input.Intro, u, channels);
                introDur = FF.Duration(u); parts.Add(u);
            }
            parts.Add(body);
            if (input.Outro != null) { var u = W("outro.wav"); FF.Decode(input.Outro, u, channels); parts.Add(u); }
            assembled = W("assembled.wav");
            var args = parts.SelectMany(p => new[] { "-i", p }).ToList();
            var graph = string.Concat(Enumerable.Range(0, parts.Count).Select(i => $"[{i}:a]")) + $"concat=n={parts.Count}:v=0:a=1[o]";
            args.AddRange(["-filter_complex", graph, "-map", "[o]", "-c:a", "pcm_f32le", assembled]);
            Ff([.. args]);
        }

        // ---- loudness: linear gain + oversampled true-peak limiter, iterated to within 0.2 LU
        var final = W("final.wav");
        double gain = 0;
        if (s.LoudnessOn)
        {
            Step($"Loudness a {s.LoudnessTarget:0} LUFS", 0.8);
            double ceiling = Math.Pow(10, (s.TruePeak - 0.2) / 20);
            var src = assembled;
            for (int it = 0; it < 3; it++)
            {
                double delta = s.LoudnessTarget - FF.MeasureLoudness(src).Integrated;
                if (it > 0 && Math.Abs(delta) < 0.2) break;
                gain += delta;
                var dst = W($"loud{it}.wav");
                Ff("-i", assembled, "-af",
                   $"volume={F(gain)}dB,aresample={SR * 4},alimiter=limit={F(ceiling, 4)}:level=false:attack=2:release=60:asc=1,aresample={SR}",
                   "-c:a", "pcm_f32le", dst);
                src = dst;
            }
            File.Move(src, final, true);
        }
        else Ff("-i", assembled, "-af", "alimiter=limit=0.89:level=false", "-c:a", "pcm_f32le", final);
        double finalDur = FF.Duration(final);

        // ---- encode
        var stem = Sanitized(string.IsNullOrWhiteSpace(s.Title) ? Path.GetFileNameWithoutExtension(input.Source) : s.Title);
        var files = new List<string>();
        for (int i = 0; i < s.Outputs.Count; i++)
        {
            var o = s.Outputs[i];
            Step($"Esportazione {o.Format.ToString().ToUpperInvariant()}", 0.85 + 0.08 * i / Math.Max(1, s.Outputs.Count));
            var f = Encode(final, o, stem, channels, info, cuts, introDur, finalDur);
            if (f != null) files.Add(f);
        }
        if (transcript.Count > 0 && s.Transcribe)
        {
            double Shift(double t) => MapTime(t, cuts) + introDur;
            transcript = transcript.Select(seg => new Transcriber.Segment(seg.Text, Shift(seg.Start), Shift(seg.End),
                seg.Words.Where(w => !(s.CutFillers && Transcriber.IsFiller(w.Text)))
                         .Select(w => new Transcriber.Word(w.Text, Shift(w.Start), Shift(w.End))).ToList())).ToList();
            files.AddRange(Transcriber.Write(transcript, input.OutputDir, stem));
        }

        // ---- after
        Step("Misure finali", 0.95);
        var xf = FF.ReadMono(final);
        var npAfter = Analysis.Noise(xf);
        if (cuts.Count > 0)
        {
            // pauses removed by cutting would fool the noise estimate: measure the uncut programme
            float g = (float)Math.Pow(10, gain / 20);
            npAfter = Analysis.Noise(FF.ReadMono(proc).Select(v => v * g).ToArray());
        }
        var ln1 = FF.MeasureLoudness(final);
        var after = new AudioStats(ln1.Integrated, ln1.TruePeak, ln1.Lra, npAfter.NoiseFloor, npAfter.Snr, finalDur);
        FF.Spectrogram(final, W("spectrum_after.png"));
        // WAV previews: Windows' media player opens them without extra codecs
        Ff("-i", track, "-ac", $"{channels}", "-ar", "44100", "-c:a", "pcm_s16le", W("preview_before.wav"));
        Ff("-i", final, "-ac", $"{channels}", "-ar", "44100", "-c:a", "pcm_s16le", W("preview_after.wav"));

        var keep = new HashSet<string> { "preview_before.wav", "preview_after.wav", "spectrum_before.png", "spectrum_after.png" };
        foreach (var f in Directory.EnumerateFileSystemEntries(input.WorkDir))
            if (!keep.Contains(Path.GetFileName(f)))
                try { if (Directory.Exists(f)) Directory.Delete(f, true); else File.Delete(f); } catch { }

        Step("Fatto", 1);
        return new ProductionResult(before, after, peaksBefore, Analysis.Peaks(xf), notes, warnings, files,
            W("preview_before.wav"), W("preview_after.wav"), W("spectrum_before.png"), W("spectrum_after.png"),
            transcript, (DateTime.Now - t0).TotalSeconds, info.HasVideo);
    }

    // ---------------------------------------------------------------- voice chain

    void ProcessSpeech(string src, string dst, Analysis.NoiseProfile np, Analysis.Hum hum, int channels)
    {
        // 1. mono voice + corrective filters, headroom for the 16-bit denoiser
        Step("Filtri e voce in mono", 0.14);
        var pre = new List<string>();
        if (s.FilterOn)
        {
            if (s.Highpass > 0) pre.Add($"highpass=f={s.Highpass}:poles=2");
            if (s.HumAuto && hum.Detected && hum.BaseFreq is int f0)
            {
                for (int k = 1; k <= 4; k++) pre.Add($"equalizer=f={f0 * k}:t=q:w=30:g=-{(k < 3 ? 24 : 15)}");
                notes.Add($"Ronzio elettrico a {f0} Hz rilevato e rimosso");
            }
            if (s.Deplosive)
            {
                // threshold is a linear amplitude: trigger on low-frequency bursts that come
                // within 4 dB of the voice's typical peak level
                double thr = Math.Clamp(Math.Pow(10, (np.SignalLevel - 4) / 20), 0.001, 1);
                pre.Add($"adynamicequalizer=threshold={F(thr, 4)}:dfrequency=110:dqfactor=0.8:tfrequency=110:tqfactor=0.8:attack=1:release=80:ratio=4:range=18:mode=cutabove:tftype=lowshelf");
            }
        }
        pre.Add(channels == 2 ? "pan=mono|c0=0.5*c0+0.5*c1" : "anull");
        var a = W("a.wav");
        Ff("-i", src, "-af", string.Join(",", pre), "-ac", "1", "-ar", $"{SR}", "-c:a", "pcm_f32le", a);
        var cur = a;
        double pk = FF.Peak(a);
        if (pk > 0.7)
        {
            var b = W("a2.wav");
            Ff("-i", a, "-af", $"volume={F(0.7 / pk, 4)}", "-c:a", "pcm_f32le", b);
            cur = b;
        }

        // 2. noise reduction
        if (s.DenoiseOn)
        {
            double nr = s.DenoiseAmount switch
            {
                Amount.Auto => np.NoiseFloor < -75 ? 0 : Math.Clamp(54 - np.Snr, 12, 45),
                Amount.Low => 10, Amount.Medium => 20, Amount.High => 35, _ => 100,
            };
            if (nr > 0)
            {
                Step("Riduzione rumore AI", 0.2);
                var outp = W("dn.wav");
                var method = s.DenoiseMethod;
                if (method == DenoiseMethod.Ai && Tools.DeepFilter == null)
                {
                    method = DenoiseMethod.Rnnoise;
                    warnings.Add("DeepFilterNet non trovato: uso RNNoise");
                }
                if (method == DenoiseMethod.Rnnoise && Tools.RnnoiseModel == null) method = DenoiseMethod.Classic;
                string label;
                switch (method)
                {
                    case DenoiseMethod.Ai:
                        var odir = W("df");
                        Directory.CreateDirectory(odir);
                        Tools.Run(Tools.DeepFilter!, ["-D", "-a", F(nr, 0), "-o", odir, cur], ct);
                        File.Move(Path.Combine(odir, Path.GetFileName(cur)), outp, true);
                        label = "AI (DeepFilterNet)";
                        break;
                    case DenoiseMethod.Rnnoise:
                        // ffmpeg filter options: escape the drive colon of the Windows path
                        var model = Tools.RnnoiseModel!.Replace("\\", "/").Replace(":", "\\:");
                        Ff("-i", cur, "-af", $"arnndn=m='{model}':mix={F(Math.Min(1, 0.4 + nr / 40))}", "-c:a", "pcm_f32le", outp);
                        label = "RNNoise";
                        break;
                    default:
                        // spectral subtraction gets "underwater" past ~25 dB: its own, gentler scale
                        nr = s.DenoiseAmount switch
                        {
                            Amount.Low => 6, Amount.Medium => 12, Amount.High => 18, Amount.Max => 25,
                            _ => Math.Min(18, nr * 0.5),
                        };
                        // learn the noise print from the quietest half second, like a manual noise profile
                        var rms = Analysis.FrameRms(FF.ReadMono(cur), 8000, 1600);
                        double q = Array.IndexOf(rms, rms.Min()) * 0.1;
                        Ff("-i", cur, "-af",
                           $"asendcmd=c='{F(q)} afftdn sn start; {F(q + 0.5)} afftdn sn stop',afftdn=nr={F(nr, 0)}:nf={F(Math.Clamp(np.NoiseFloor, -80, -20), 0)}:tn=1",
                           "-c:a", "pcm_f32le", outp);
                        label = "spettrale";
                        break;
                }
                cur = outp;
                notes.Add($"Riduzione rumore {label} fino a {F(nr, 0)} dB (SNR originale {F(np.Snr, 0)} dB)");
            }
            else notes.Add("Registrazione già pulita: nessuna riduzione rumore necessaria");
        }

        // analysis on the cleaned voice drives EQ and leveler
        Step("Analisi della voce", 0.32);
        var x16 = FF.ReadMono(cur);
        var vad = Leveler.VoiceActivity(x16);

        // 3. AutoEQ + de-esser
        var tone = new List<string>();
        if (s.FilterOn && s.AutoEQ)
        {
            var eq = Leveler.AutoEQ(x16, vad);
            if (Analysis.Noise(x16).Snr < 25)
                eq = eq.Where(e => !(e.F >= 2000 && e.Gain > 0)).ToList();   // still noisy: don't lift the hiss
            tone.AddRange(eq.Select(e => $"equalizer=f={e.F}:t=o:w=1:g={F(e.Gain, 1)}"));
            if (eq.Count > 0)
                notes.Add("Voice AutoEQ: " + string.Join(", ", eq.Select(e =>
                    $"{(e.F < 1000 ? e.F.ToString() : e.F / 1000 + "k")} Hz {(e.Gain > 0 ? "+" : "")}{F(e.Gain, 1)} dB")));
        }
        if (s.FilterOn && s.Deesser) tone.Add("deesser=i=0.4:m=0.5:f=0.5:s=o");
        if (tone.Count > 0)
        {
            Step("Voice AutoEQ", 0.38);
            var outp = W("eq.wav");
            Ff("-i", cur, "-af", string.Join(",", tone), "-c:a", "pcm_f32le", outp);
            cur = outp;
            if (s.LevelerOn) x16 = FF.ReadMono(cur);
        }

        // 4. leveler + compressor
        if (s.LevelerOn && s.LevelerStrength > 0)
        {
            Step("Adaptive Leveler", 0.44);
            var (g, info) = Leveler.Curve(x16, vad, s.LevelerStrength / 100);
            var outp = W("lev.wav");
            Leveler.ApplyGain(cur, outp, g, SR, 1);
            cur = outp;
            notes.Add($"Adaptive Leveler: livelli bilanciati su {F(info.Range, 1)} dB di escursione");
            var comp = s.Compressor == Compressor.Auto ? (info.Range > 8 ? Compressor.Medium : Compressor.Soft) : s.Compressor;
            if (comp != Compressor.Off && info.SpeechLevel is double level)
            {
                var (off, ratio) = comp switch { Compressor.Soft => (7.0, 1.8), Compressor.Medium => (4.0, 2.5), _ => (1.0, 3.5) };
                var c = W("comp.wav");
                Ff("-i", cur, "-af", $"acompressor=threshold={F(level + off, 1)}dB:ratio={F(ratio, 1)}:attack=8:release=140:knee=6:detection=rms:makeup=1",
                   "-c:a", "pcm_f32le", c);
                cur = c;
            }
        }
        Ff("-i", cur, "-ac", $"{channels}", "-ar", $"{SR}", "-c:a", "pcm_f32le", dst);
    }

    // ---------------------------------------------------------------- cutting

    static List<(double A, double B)> Merge(List<(double A, double B)> iv)
    {
        var o = new List<(double A, double B)>();
        foreach (var (a, b) in iv.Where(v => v.B > v.A).OrderBy(v => v.A))
        {
            if (o.Count > 0 && a <= o[^1].B + 0.01) o[^1] = (o[^1].A, Math.Max(o[^1].B, b));
            else o.Add((a, b));
        }
        return o;
    }

    static double MapTime(double t, List<(double A, double B)> cuts)
    {
        double removed = 0;
        foreach (var (a, b) in cuts)
        {
            if (t >= b) removed += b - a;
            else if (t > a) return a - removed;
            else break;
        }
        return t - removed;
    }

    static string KeepSegments(List<(double A, double B)> cuts, double duration)
    {
        var keep = new List<(double, double)>();
        double pos = 0;
        foreach (var (a, b) in cuts)
        {
            if (a > pos) keep.Add((pos, a));
            pos = b;
        }
        keep.Add((pos, duration + 1));
        return string.Join("+", keep.Select(k => $"between(t,{F(k.Item1, 3)},{F(k.Item2, 3)})"));
    }

    /// <summary>10 ms fades to silence on both sides of every splice, then a 1 ms-precise cut: no clicks.</summary>
    void ApplyCuts(string src, string dst, List<(double A, double B)> cuts, double duration, int channels)
    {
        var g = new double[(int)(duration * 100) + 2];
        foreach (var (a, b) in cuts)
            foreach (var t in new[] { a, b })
            {
                int i = (int)Math.Floor(t * 100 - 0.5);
                for (int j = Math.Max(0, i); j < Math.Min(g.Length, Math.Max(0, i + 2)); j++) g[j] = -90;
            }
        var faded = W("faded.wav");
        Leveler.ApplyGain(src, faded, g, SR, channels);
        Ff("-i", faded, "-af", $"asetnsamples=n=48,aselect='{KeepSegments(cuts, duration)}',asetpts=N/SR/TB", "-c:a", "pcm_f32le", dst);
    }

    // ---------------------------------------------------------------- encoding

    static string Sanitized(string name)
    {
        var r = new string(name.Select(c => char.IsLetterOrDigit(c) || "-_ ".Contains(c) ? c : '_').ToArray()).Trim();
        return r.Length == 0 ? "OpenPhonic" : r[..Math.Min(80, r.Length)];
    }

    string? Encode(string final, Output o, string stem, int channels, FF.ProbeInfo info,
                   List<(double A, double B)> cuts, double introDur, double duration)
    {
        bool dupe = s.Outputs.Count(x => x.Format == o.Format) > 1;
        var dst = Path.Combine(input.OutputDir, dupe ? $"{stem}-{o.Bitrate}k.{o.Ext}" : $"{stem}.{o.Ext}");
        if (File.Exists(dst)) File.Delete(dst);
        int ch = o.Channels == OutChannels.Keep ? channels : o.Channels == OutChannels.Mono ? 1 : 2;
        var meta = new List<string>();
        if (s.Title.Length > 0) meta.AddRange(["-metadata", $"title={s.Title}"]);
        if (s.Artist.Length > 0) meta.AddRange(["-metadata", $"artist={s.Artist}"]);
        if (s.Album.Length > 0) meta.AddRange(["-metadata", $"album={s.Album}"]);

        if (o.Format == OutFormat.Video)
        {
            if (!info.HasVideo)
            {
                warnings.Add("Uscita video richiesta ma il file non contiene video: saltata");
                return null;
            }
            var vf = new List<string>();
            if (cuts.Count > 0) vf.Add($"select='{KeepSegments(cuts, info.Duration)}',setpts=N/FRAME_RATE/TB");
            if (input.Intro != null || input.Outro != null) vf.Add($"tpad=start_duration={F(introDur, 3)}:stop_duration=3600:color=black");
            var args = new List<string> { "-i", input.Source, "-i", final };
            if (vf.Count == 0)
            {
                args.AddRange(["-c:v", "copy"]);
                if (info.VideoCodec == "hevc") args.AddRange(["-tag:v", "hvc1"]);
            }
            else args.AddRange(["-vf", string.Join(",", vf), "-c:v", "libx264", "-preset", "veryfast", "-crf", "19", "-pix_fmt", "yuv420p"]);
            args.AddRange(["-map", "0:v:0", "-map", "1:a", "-c:a", "aac", "-b:a", $"{Math.Max(o.Bitrate, 160)}k", "-ac", $"{ch}"]);
            args.AddRange(meta);
            args.AddRange(["-movflags", "+faststart", "-t", F(duration, 3), dst]);
            Ff([.. args]);
            return dst;
        }

        var a = new List<string> { "-i", final };
        bool withCover = input.Cover != null && o.Format is OutFormat.Mp3 or OutFormat.Aac or OutFormat.Flac;
        if (withCover) a.AddRange(["-i", input.Cover!]);
        a.AddRange(["-map", "0:a"]);
        if (withCover) a.AddRange(["-map", "1:v", "-c:v", o.Format == OutFormat.Flac ? "copy" : "mjpeg", "-disposition:v", "attached_pic"]);
        a.AddRange(["-ac", $"{ch}"]);
        a.AddRange(meta);
        a.AddRange(o.Format switch
        {
            OutFormat.Mp3 => ["-c:a", "libmp3lame", "-b:a", $"{o.Bitrate}k", "-id3v2_version", "3"],
            OutFormat.Aac => ["-c:a", "aac", "-b:a", $"{o.Bitrate}k", "-movflags", "+faststart"],
            OutFormat.Opus => ["-c:a", "libopus", "-b:a", $"{o.Bitrate}k"],
            OutFormat.Flac => ["-c:a", "flac", "-sample_fmt", "s32"],
            _ => new[] { "-c:a", "pcm_s24le" },
        });
        a.Add(dst);
        Ff([.. a]);
        return dst;
    }
}
