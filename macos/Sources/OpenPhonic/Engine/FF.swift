import Foundation

/// ffmpeg / ffprobe helpers (same measurements as the web engine).
enum FF {
    struct ProbeInfo: Codable, Hashable {
        var duration: Double
        var channels: Int
        var sampleRate: Int
        var codec: String
        var hasVideo: Bool
        var videoCodec: String?
    }

    static func probe(_ url: URL) throws -> ProbeInfo {
        guard let exe = Tools.ffprobe else { throw Tools.Failure(message: "ffprobe non trovato. Installa ffmpeg con: brew install ffmpeg") }
        let r: (out: Data, err: String)
        do {
            r = try Tools.run(exe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        } catch {
            throw Tools.Failure(message: "Impossibile leggere \(url.lastPathComponent): non è un file audio o video valido")
        }
        let j = (try? JSONSerialization.jsonObject(with: r.out)) as? [String: Any] ?? [:]
        let streams = j["streams"] as? [[String: Any]] ?? []
        guard let a = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw Tools.Failure(message: "\(url.lastPathComponent) non contiene audio")
        }
        let v = streams.first {
            $0["codec_type"] as? String == "video"
                && ((($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) ?? 0) == 0
        }
        let fmt = j["format"] as? [String: Any] ?? [:]
        return ProbeInfo(
            duration: Double(fmt["duration"] as? String ?? a["duration"] as? String ?? "0") ?? 0,
            channels: a["channels"] as? Int ?? 1,
            sampleRate: Int(a["sample_rate"] as? String ?? "48000") ?? 48000,
            codec: a["codec_name"] as? String ?? "?",
            hasVideo: v != nil,
            videoCodec: v?["codec_name"] as? String)
    }

    static func decode(_ src: URL, to dst: URL, channels: Int, sr: Int = 48000) throws {
        try Tools.ffmpeg(["-i", src.path, "-vn", "-map", "0:a:0", "-ac", "\(channels)", "-ar", "\(sr)",
                          "-c:a", "pcm_f32le", dst.path])
    }

    /// Mono float samples (analysis rate, 16 kHz by default).
    static func readMono(_ url: URL, sr: Int = 16000) throws -> [Float] {
        guard let exe = Tools.ffmpeg else { throw Tools.Failure(message: "ffmpeg non trovato") }
        let r = try Tools.run(exe, ["-hide_banner", "-nostdin", "-i", url.path, "-vn", "-ac", "1", "-ar", "\(sr)",
                                    "-f", "f32le", "-"])
        return r.out.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    struct Loudness: Codable, Hashable {
        var integrated: Double
        var truePeak: Double
        var lra: Double
        var threshold: Double
    }

    static func loudness(_ url: URL, dualMono: Bool = false) throws -> Loudness {
        let af = "loudnorm=I=-16:TP=-1:LRA=11:print_format=json" + (dualMono ? ":dual_mono=true" : "")
        let err = try Tools.ffmpeg(["-i", url.path, "-vn", "-af", af, "-f", "null", "-"])
        guard let start = err.range(of: "{", options: .backwards),
              let end = err.range(of: "}", options: .backwards),
              let j = try? JSONSerialization.jsonObject(with: Data(err[start.lowerBound...end.lowerBound].utf8)) as? [String: String]
        else { throw Tools.Failure(message: "Misura della loudness non riuscita") }
        func v(_ k: String) -> Double {
            let s = j[k] ?? "0"
            return s == "-inf" ? -99 : (s == "inf" ? 99 : Double(s) ?? 0)
        }
        return Loudness(integrated: v("input_i"), truePeak: v("input_tp"), lra: v("input_lra"),
                        threshold: v("input_thresh"))
    }

    static func peak(_ url: URL) throws -> Double {
        let err = try Tools.ffmpeg(["-i", url.path, "-af", "volumedetect", "-f", "null", "-"])
        guard let r = err.range(of: #"max_volume: (-?[\d.]+) dB"#, options: .regularExpression) else { return 1 }
        let num = err[r].replacingOccurrences(of: "max_volume: ", with: "").replacingOccurrences(of: " dB", with: "")
        return pow(10, (Double(num) ?? 0) / 20)
    }

    static func spectrogram(_ src: URL, _ dst: URL) throws {
        try Tools.ffmpeg(["-i", src.path, "-lavfi",
                          "showspectrumpic=s=1400x300:legend=0:color=magma:scale=log:fscale=lin:stop=12000",
                          "-frames:v", "1", dst.path])
    }

    static func duration(_ url: URL) -> Double { (try? probe(url).duration) ?? 0 }
}
