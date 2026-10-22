import Foundation

/// Measured statistics for one side of the before/after comparison.
struct AudioStats: Codable, Hashable {
    var integrated: Double
    var truePeak: Double
    var lra: Double
    var noiseFloor: Double
    var snr: Double
    var duration: Double
}

struct ProductionResult: Codable, Hashable {
    var before: AudioStats
    var after: AudioStats
    var peaksBefore: [Float]
    var peaksAfter: [Float]
    var notes: [String]
    var warnings: [String]
    var files: [URL]
    var previewBefore: URL
    var previewAfter: URL
    var spectrumBefore: URL
    var spectrumAfter: URL
    var transcript: [Transcriber.Segment]
    var seconds: Double
    var hasVideo: Bool
}

struct ProductionInput {
    var source: URL
    var intro: URL?
    var outro: URL?
    var cover: URL?
    var outputDir: URL
    var workDir: URL
}

/// Same processing chain as the web version:
/// mono voice -> filters -> DeepFilterNet -> AutoEQ / de-ess -> phrase leveler -> compressor
/// -> transcription -> silence / filler cuts -> intro + outro -> exact loudness -> encode.
final class Pipeline {
    typealias Progress = @Sendable (String, Double) -> Void

    let s: ProductionSettings
    let input: ProductionInput
    let progress: Progress
    var notes: [String] = []
    var warnings: [String] = []
    let SR = 48000
    var work: URL { input.workDir }

    init(settings: ProductionSettings, input: ProductionInput, progress: @escaping Progress) {
        self.s = settings
        self.input = input
        self.progress = progress
    }

    private func w(_ name: String) -> URL { work.appendingPathComponent(name) }

    func run() async throws -> ProductionResult {
        let t0 = Date()
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input.outputDir, withIntermediateDirectories: true)

        // ---- analysis
        progress("Analisi del file", 0.03)
        let info = try FF.probe(input.source)
        let channels = min(2, info.channels)
        let track = w("track.wav")
        try FF.decode(input.source, to: track, channels: channels)
        let x0 = try FF.readMono(track)
        let np0 = Analysis.noiseProfile(x0)
        let hum = Analysis.detectHum(x0)
        let ln0 = try FF.loudness(track)
        let before = AudioStats(integrated: ln0.integrated, truePeak: ln0.truePeak, lra: ln0.lra,
                                noiseFloor: np0.noiseFloor, snr: np0.snr, duration: info.duration)
        let peaksBefore = Analysis.peaks(x0)
        try FF.spectrogram(track, w("spectrum_before.png"))
        progress("Analisi completata", 0.1)

        // ---- per-track processing
        let proc = w("proc.wav")
        if s.content == .speech {
            try processSpeech(track, dst: proc, np: np0, hum: hum, channels: channels)
        } else if s.levelerOn {
            try Tools.ffmpeg(["-i", track.path, "-af", "dynaudnorm=f=1000:g=31:p=0.95:m=4", "-c:a", "pcm_f32le", proc.path])
        } else {
            try FileManager.default.copyItem(at: track, to: proc)
        }

        // ---- transcription
        var transcript: [Transcriber.Segment] = []
        if s.transcribe || s.cutFillers {
            progress("Trascrizione vocale", 0.55)
            let asr = w("asr.wav")
            try Tools.ffmpeg(["-i", proc.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", asr.path])
            do {
                transcript = try await Transcriber.transcribe(asr, locale: Locale(identifier: s.language))
                notes.append("Trascritti \(transcript.count) segmenti")
            } catch {
                warnings.append("Trascrizione non riuscita: \(error.localizedDescription)")
            }
        }

        // ---- cuts
        var cuts: [(Double, Double)] = []
        if s.cutSilence {
            progress("Ricerca delle pause", 0.66)
            let xm = try FF.readMono(proc)
            let np = Analysis.noiseProfile(xm)
            let thr = min(-25, max(np.noiseFloor + 10, np.signalLevel - 32))
            for (a, b) in Analysis.silences(xm, thresholdDb: thr, minDur: s.minSilence) where b - a > s.keepSilence {
                cuts.append((a + s.keepSilence / 2, b - s.keepSilence / 2))
            }
        }
        var fillerCount = 0
        if s.cutFillers {
            for w in transcript.flatMap(\.words) where Transcriber.isFiller(w.text) {
                cuts.append((max(0, w.start - 0.03), w.end + 0.05))
                fillerCount += 1
            }
        }
        cuts = merge(cuts)
        let cutTotal = cuts.reduce(0) { $0 + $1.1 - $1.0 }
        var body = proc
        if !cuts.isEmpty {
            progress("Taglio di pause e riempitivi", 0.7)
            body = w("cut.wav")
            try applyCuts(proc, body, cuts: cuts, duration: FF.duration(proc), channels: channels)
            notes.append(String(format: "Tagliati %.1f s (%d tagli%@)", cutTotal, cuts.count,
                                fillerCount > 0 ? ", \(fillerCount) parole riempitive" : ""))
        }

        // ---- intro / outro
        var introDur = 0.0
        var assembled = body
        if input.intro != nil || input.outro != nil {
            progress("Intro e outro", 0.74)
            var parts: [URL] = []
            if let i = input.intro {
                let u = w("intro.wav"); try FF.decode(i, to: u, channels: channels)
                introDur = FF.duration(u); parts.append(u)
            }
            parts.append(body)
            if let o = input.outro {
                let u = w("outro.wav"); try FF.decode(o, to: u, channels: channels); parts.append(u)
            }
            assembled = w("assembled.wav")
            let ins = parts.flatMap { ["-i", $0.path] }
            let graph = (0..<parts.count).map { "[\($0):a]" }.joined() + "concat=n=\(parts.count):v=0:a=1[o]"
            try Tools.ffmpeg(ins + ["-filter_complex", graph, "-map", "[o]", "-c:a", "pcm_f32le", assembled.path])
        }

        // ---- loudness
        let final = w("final.wav")
        var gain = 0.0
        if s.loudnessOn {
            progress("Loudness a \(Int(s.loudnessTarget)) LUFS", 0.8)
            let ceiling = pow(10, (s.truePeak - 0.2) / 20)
            var src = assembled
            for it in 0..<3 {
                let measured = try FF.loudness(src).integrated
                let delta = s.loudnessTarget - measured
                if it > 0 && abs(delta) < 0.2 { break }
                gain += delta
                let dst = w("loud\(it).wav")
                try Tools.ffmpeg(["-i", assembled.path, "-af",
                                  String(format: "volume=%.2fdB,aresample=%d,alimiter=limit=%.4f:level=false:attack=2:release=60:asc=1,aresample=%d",
                                         gain, SR * 4, ceiling, SR),
                                  "-c:a", "pcm_f32le", dst.path])
                src = dst
            }
            try FileManager.default.moveItem(at: src, to: final)
        } else {
            try Tools.ffmpeg(["-i", assembled.path, "-af", "alimiter=limit=0.89:level=false", "-c:a", "pcm_f32le", final.path])
        }
        let finalDur = FF.duration(final)

        // ---- encode
        let stem = sanitized(s.title.isEmpty ? input.source.deletingPathExtension().lastPathComponent : s.title)
        var files: [URL] = []
        for (i, o) in s.outputs.enumerated() {
            progress("Esportazione \(o.format.rawValue.uppercased())", 0.85 + 0.08 * Double(i) / Double(max(1, s.outputs.count)))
            if let u = try encode(final, o, stem: stem, channels: channels, info: info, cuts: cuts,
                                  introDur: introDur, duration: finalDur) {
                files.append(u)
            }
        }
        if !transcript.isEmpty && s.transcribe {
            let shift: (Double) -> Double = { [cuts] t in Self.mapTime(t, cuts) + introDur }
            let mapped = transcript.map { seg in
                Transcriber.Segment(text: seg.text, start: shift(seg.start), end: shift(seg.end),
                                    words: seg.words.filter { !(s.cutFillers && Transcriber.isFiller($0.text)) }
                                        .map { .init(text: $0.text, start: shift($0.start), end: shift($0.end)) })
            }
            transcript = mapped
            files += try Transcriber.write(mapped, to: input.outputDir, stem: stem)
        }

        // ---- after
        progress("Misure finali", 0.95)
        let xf = try FF.readMono(final)
        var npAfter = Analysis.noiseProfile(xf)
        if !cuts.isEmpty {
            // pauses removed by cutting would fool the noise estimate: measure the uncut programme
            let xu = try FF.readMono(proc).map { $0 * Float(pow(10, gain / 20)) }
            npAfter = Analysis.noiseProfile(xu)
        }
        let ln1 = try FF.loudness(final)
        let after = AudioStats(integrated: ln1.integrated, truePeak: ln1.truePeak, lra: ln1.lra,
                               noiseFloor: npAfter.noiseFloor, snr: npAfter.snr, duration: finalDur)
        try FF.spectrogram(final, w("spectrum_after.png"))
        try Tools.ffmpeg(["-i", track.path, "-c:a", "aac", "-b:a", "192k", w("preview_before.m4a").path])
        try Tools.ffmpeg(["-i", final.path, "-ac", "\(channels)", "-c:a", "aac", "-b:a", "192k", w("preview_after.m4a").path])

        // keep only what the result view needs
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        where !["preview_before.m4a", "preview_after.m4a", "spectrum_before.png", "spectrum_after.png"].contains(f.lastPathComponent) {
            try? fm.removeItem(at: f)
        }
        progress("Fatto", 1)
        return ProductionResult(
            before: before, after: after, peaksBefore: peaksBefore, peaksAfter: Analysis.peaks(xf),
            notes: notes, warnings: warnings, files: files,
            previewBefore: w("preview_before.m4a"), previewAfter: w("preview_after.m4a"),
            spectrumBefore: w("spectrum_before.png"), spectrumAfter: w("spectrum_after.png"),
            transcript: transcript, seconds: Date().timeIntervalSince(t0), hasVideo: info.hasVideo)
    }

    // MARK: voice chain

    func processSpeech(_ src: URL, dst: URL, np: Analysis.NoiseProfile, hum: Analysis.Hum, channels: Int) throws {
        // 1. mono voice + corrective filters, headroom for the 16-bit denoiser
        progress("Filtri e voce in mono", 0.14)
        var pre: [String] = []
        if s.filterOn {
            if s.highpass > 0 { pre.append("highpass=f=\(s.highpass):poles=2") }
            if s.humAuto, hum.detected, let f0 = hum.baseFreq {
                for k in 1...4 { pre.append("equalizer=f=\(f0 * k):t=q:w=30:g=-\(k < 3 ? 24 : 15)") }
                notes.append("Ronzio elettrico a \(f0) Hz rilevato e rimosso")
            }
            if s.deplosive {
                // threshold is a linear amplitude: trigger on low-frequency bursts that come
                // within 4 dB of the voice's typical peak level
                let thr = min(1, max(0.001, pow(10, (np.signalLevel - 4) / 20)))
                pre.append(String(format: "adynamicequalizer=threshold=%.4f:dfrequency=110:dqfactor=0.8:tfrequency=110:tqfactor=0.8:attack=1:release=80:ratio=4:range=18:mode=cutabove:tftype=lowshelf", thr))
            }
        }
        pre.append(channels == 2 ? "pan=mono|c0=0.5*c0+0.5*c1" : "anull")
        let a = w("a.wav")
        try Tools.ffmpeg(["-i", src.path, "-af", pre.joined(separator: ","), "-ac", "1", "-ar", "\(SR)", "-c:a", "pcm_f32le", a.path])
        let pk = try FF.peak(a)
        var cur = a
        if pk > 0.7 {
            let b = w("a2.wav")
            try Tools.ffmpeg(["-i", a.path, "-af", String(format: "volume=%.4f", 0.7 / pk), "-c:a", "pcm_f32le", b.path])
            cur = b
        }

        // 2. noise reduction
        if s.denoiseOn {
            var nr: Double = {
                switch s.denoiseAmount {
                case .auto: return np.noiseFloor < -75 ? 0 : min(45, max(12, 54 - np.snr))
                case .low: return 10
                case .medium: return 20
                case .high: return 35
                case .max: return 100
                }
            }()
            if nr > 0 {
                progress("Riduzione rumore AI", 0.2)
                let out = w("dn.wav")
                var method = s.denoiseMethod
                if method == .ai && Tools.deepFilter == nil {
                    method = .rnnoise
                    warnings.append("DeepFilterNet non trovato: uso RNNoise")
                }
                if method == .rnnoise && Tools.rnnoiseModel == nil { method = .classic }
                switch method {
                case .ai:
                    let odir = w("df")
                    try FileManager.default.createDirectory(at: odir, withIntermediateDirectories: true)
                    try Tools.run(Tools.deepFilter!, ["-D", "-a", String(format: "%.0f", nr), "-o", odir.path, cur.path])
                    try FileManager.default.moveItem(at: odir.appendingPathComponent(cur.lastPathComponent), to: out)
                case .rnnoise:
                    try Tools.ffmpeg(["-i", cur.path, "-af", String(format: "arnndn=m=%@:mix=%.2f", Tools.rnnoiseModel!, min(1, 0.4 + nr / 40)),
                                      "-c:a", "pcm_f32le", out.path])
                case .classic:
                    // spectral subtraction gets "underwater" past ~25 dB: its own, gentler scale
                    let classicNR: Double = ["low": 6, "medium": 12, "high": 18, "max": 25][s.denoiseAmount.rawValue] ?? min(18, nr * 0.5)
                    nr = classicNR
                    // learn the noise print from the quietest half second, like a manual noise profile
                    let xs = try FF.readMono(cur)
                    let rms = Analysis.frameRMS(xs, frame: 8000, hop: 1600)
                    let q = Double(rms.indices.min { rms[$0] < rms[$1] } ?? 0) * 0.1
                    let sample = String(format: "asendcmd=c='%.2f afftdn sn start; %.2f afftdn sn stop',", q, q + 0.5)
                    try Tools.ffmpeg(["-i", cur.path, "-af", sample + String(format: "afftdn=nr=%.0f:nf=%.0f:tn=1", classicNR, max(-80, min(-20, np.noiseFloor))),
                                      "-c:a", "pcm_f32le", out.path])
                }
                cur = out
                let label = ["ai": "AI (DeepFilterNet)", "rnnoise": "RNNoise", "classic": "spettrale"][method.rawValue]!
                notes.append(String(format: "Riduzione rumore %@ fino a %.0f dB (SNR originale %.0f dB)", label, nr, np.snr))
            } else {
                notes.append("Registrazione già pulita: nessuna riduzione rumore necessaria")
            }
        }

        // analysis on the cleaned voice drives EQ and leveler
        progress("Analisi della voce", 0.32)
        var x16 = try FF.readMono(cur)
        let vad = Leveler.voiceActivity(x16)

        // 3. AutoEQ + de-esser
        var tone: [String] = []
        if s.filterOn && s.autoEQ {
            var eq = Leveler.autoEQ(x16, vad: vad)
            if Analysis.noiseProfile(x16).snr < 25 {
                // still noisy: lifting the highs would lift the hiss with them
                eq = eq.filter { !($0.0 >= 2000 && $0.1 > 0) }
            }
            tone += eq.map { String(format: "equalizer=f=%d:t=o:w=1:g=%.1f", $0.0, $0.1) }
            if !eq.isEmpty {
                notes.append("Voice AutoEQ: " + eq.map { String(format: "%@ Hz %+.1f dB", $0.0 < 1000 ? "\($0.0)" : "\($0.0 / 1000)k", $0.1) }.joined(separator: ", "))
            }
        }
        if s.filterOn && s.deesser { tone.append("deesser=i=0.4:m=0.5:f=0.5:s=o") }
        if !tone.isEmpty {
            progress("Voice AutoEQ", 0.38)
            let out = w("eq.wav")
            try Tools.ffmpeg(["-i", cur.path, "-af", tone.joined(separator: ","), "-c:a", "pcm_f32le", out.path])
            cur = out
            if s.levelerOn { x16 = try FF.readMono(cur) }
        }

        // 4. leveler + compressor
        if s.levelerOn && s.levelerStrength > 0 {
            progress("Adaptive Leveler", 0.44)
            let (g, info) = Leveler.curve(x16, vad: vad, strength: s.levelerStrength / 100)
            let out = w("lev.wav")
            try Leveler.applyGain(cur, out, gainDb: g, sampleRate: SR, channels: 1)
            cur = out
            notes.append(String(format: "Adaptive Leveler: livelli bilanciati su %.1f dB di escursione", info.range))
            var comp = s.compressor
            if comp == .auto { comp = info.range > 8 ? .medium : .soft }
            if comp != .off, let level = info.speechLevel {
                let (off, ratio): (Double, Double) = comp == .soft ? (7, 1.8) : comp == .medium ? (4, 2.5) : (1, 3.5)
                let c = w("comp.wav")
                try Tools.ffmpeg(["-i", cur.path, "-af",
                                  String(format: "acompressor=threshold=%.1fdB:ratio=%.1f:attack=8:release=140:knee=6:detection=rms:makeup=1", level + off, ratio),
                                  "-c:a", "pcm_f32le", c.path])
                cur = c
            }
        }
        try Tools.ffmpeg(["-i", cur.path, "-ac", "\(channels)", "-ar", "\(SR)", "-c:a", "pcm_f32le", dst.path])
    }

    // MARK: cutting

    func merge(_ iv: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (a, b) in iv.sorted(by: { $0.0 < $1.0 }) where b > a {
            if let last = out.last, a <= last.1 + 0.01 { out[out.count - 1].1 = max(last.1, b) }
            else { out.append((a, b)) }
        }
        return out
    }

    static func mapTime(_ t: Double, _ cuts: [(Double, Double)]) -> Double {
        var removed = 0.0
        for (a, b) in cuts {
            if t >= b { removed += b - a }
            else if t > a { return a - removed }
            else { break }
        }
        return t - removed
    }

    func keepSegments(_ cuts: [(Double, Double)], duration: Double) -> String {
        var keep: [(Double, Double)] = []
        var pos = 0.0
        for (a, b) in cuts {
            if a > pos { keep.append((pos, a)) }
            pos = b
        }
        keep.append((pos, duration + 1))
        return keep.map { String(format: "between(t,%.3f,%.3f)", $0.0, $0.1) }.joined(separator: "+")
    }

    /// 10 ms fades to silence on both sides of every splice, then a 1 ms-precise cut: no clicks.
    func applyCuts(_ src: URL, _ dst: URL, cuts: [(Double, Double)], duration: Double, channels: Int) throws {
        var g = [Double](repeating: 0, count: Int(duration * 100) + 2)
        for (a, b) in cuts {
            for t in [a, b] {
                let i = Int((t * 100 - 0.5).rounded(.down))
                for j in max(0, i)..<min(g.count, max(0, i + 2)) { g[j] = -90 }
            }
        }
        let faded = w("faded.wav")
        try Leveler.applyGain(src, faded, gainDb: g, sampleRate: SR, channels: channels)
        try Tools.ffmpeg(["-i", faded.path, "-af", "asetnsamples=n=48,aselect='\(keepSegments(cuts, duration: duration))',asetpts=N/SR/TB",
                          "-c:a", "pcm_f32le", dst.path])
    }

    // MARK: encoding

    func sanitized(_ s: String) -> String {
        let ok = s.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" }
        let r = String(ok).trimmingCharacters(in: .whitespaces)
        return r.isEmpty ? "OpenPhonic" : String(r.prefix(80))
    }

    func encode(_ final: URL, _ o: ProductionSettings.Output, stem: String, channels: Int, info: FF.ProbeInfo,
                cuts: [(Double, Double)], introDur: Double, duration: Double) throws -> URL? {
        let dupe = s.outputs.filter { $0.format == o.format }.count > 1
        let dst = input.outputDir.appendingPathComponent(dupe ? "\(stem)-\(o.bitrate)k.\(o.ext)" : "\(stem).\(o.ext)")
        try? FileManager.default.removeItem(at: dst)
        let ch = o.channels == .keep ? channels : (o.channels == .mono ? 1 : 2)
        var meta: [String] = []
        if !s.title.isEmpty { meta += ["-metadata", "title=\(s.title)"] }
        if !s.artist.isEmpty { meta += ["-metadata", "artist=\(s.artist)"] }
        if !s.album.isEmpty { meta += ["-metadata", "album=\(s.album)"] }

        if o.format == .video {
            guard info.hasVideo else {
                warnings.append("Uscita video richiesta ma il file non contiene video: saltata")
                return nil
            }
            var vf: [String] = []
            if !cuts.isEmpty { vf.append("select='\(keepSegments(cuts, duration: info.duration))',setpts=N/FRAME_RATE/TB") }
            if input.intro != nil || input.outro != nil {
                vf.append(String(format: "tpad=start_duration=%.3f:stop_duration=3600:color=black", introDur))
            }
            var args = ["-i", input.source.path, "-i", final.path]
            if vf.isEmpty {
                args += ["-c:v", "copy"] + (info.videoCodec == "hevc" ? ["-tag:v", "hvc1"] : [])
            } else {
                args += ["-vf", vf.joined(separator: ","), "-c:v", "h264_videotoolbox", "-b:v", "12M", "-pix_fmt", "yuv420p"]
            }
            args += ["-map", "0:v:0", "-map", "1:a", "-c:a", "aac", "-b:a", "\(max(o.bitrate, 160))k", "-ac", "\(ch)"]
                + meta + ["-movflags", "+faststart", "-t", String(format: "%.3f", duration), dst.path]
            try Tools.ffmpeg(args)
            return dst
        }

        var args = ["-i", final.path]
        let withCover = input.cover != nil && [.mp3, .aac, .flac].contains(o.format)
        if withCover { args += ["-i", input.cover!.path] }
        args += ["-map", "0:a"]
        if withCover {
            args += ["-map", "1:v", "-c:v", o.format == .flac ? "copy" : "mjpeg", "-disposition:v", "attached_pic"]
        }
        args += ["-ac", "\(ch)"] + meta
        switch o.format {
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "\(o.bitrate)k", "-id3v2_version", "3"]
        case .aac: args += ["-c:a", "aac", "-b:a", "\(o.bitrate)k", "-movflags", "+faststart"]
        case .opus: args += ["-c:a", "libopus", "-b:a", "\(o.bitrate)k"]
        case .flac: args += ["-c:a", "flac", "-sample_fmt", "s32"]
        case .wav: args += ["-c:a", "pcm_s24le"]
        case .video: break
        }
        try Tools.ffmpeg(args + [dst.path])
        return dst
    }
}
