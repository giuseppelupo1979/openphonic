import Accelerate
import Foundation

/// Voice activity, Voice AutoEQ and the phrase-level Adaptive Leveler (port of leveler.py).
///
/// The leveler measures loudness of speech only (400 ms windows), computes the gain that brings
/// each phrase to the programme's typical level and smooths it in both directions (zero phase).
/// In pauses the gain is interpolated between neighbouring phrases, so noise is never pulled up.
enum Leveler {
    static let sr = 16000
    static let hop = sr / 100   // 10 ms frames

    static func db10(_ x: Double) -> Double { 10 * log10(max(x, 1e-12)) }

    /// Mean power of `win`-sample windows centred on every 10 ms hop.
    static func powerFrames(_ x: [Float], win: Int) -> [Double] {
        var cum = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { cum[i + 1] = cum[i] + Double(x[i]) * Double(x[i]) }
        let n = x.count / hop
        return (0..<n).map { i in
            let c = i * hop + hop / 2
            let a = max(0, c - win / 2), b = min(x.count, c + win / 2)
            return (cum[b] - cum[a]) / Double(max(b - a, 1))
        }
    }

    static func runs(_ m: [Bool], _ value: Bool) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var s: Int?
        for i in 0...m.count {
            let v = i < m.count ? m[i] == value : false
            if v, s == nil { s = i }
            if !v, let st = s { out.append((st, i)); s = nil }
        }
        return out
    }

    static func voiceActivity(_ x: [Float]) -> [Bool] {
        let e = powerFrames(x, win: 480).map(db10)
        guard !e.isEmpty else { return [] }
        let floor = Analysis.percentile(e, 10), peak = Analysis.percentile(e, 99.5)
        let thr = max(floor + 12, peak - 42)
        var v = e.map { $0 > thr }
        for (a, b) in runs(v, false) where b - a < 20 && a > 0 && b < v.count {   // bridge gaps < 200 ms
            for i in a..<b { v[i] = true }
        }
        for (a, b) in runs(v, true) where b - a < 6 {                             // drop clicks < 60 ms
            for i in a..<b { v[i] = false }
        }
        var hang = [Bool](repeating: false, count: v.count)                       // 150 ms hangover
        for i in v.indices where v[i] {
            for j in max(0, i - 7)...min(v.count - 1, i + 7) { hang[j] = true }
        }
        return hang
    }

    static func zeroPhaseSmooth(_ g: [Double], tau: Double) -> [Double] {
        guard g.count > 1 else { return g }
        let a = 1 - exp(-1 / (tau * 100))
        var out = g
        var prev = out[0]
        for i in 1..<out.count { prev += a * (out[i] - prev); out[i] = prev }
        prev = out[out.count - 1]
        for i in stride(from: out.count - 2, through: 0, by: -1) { prev += a * (out[i] - prev); out[i] = prev }
        return out
    }

    struct CurveInfo { var range: Double; var speechLevel: Double? }

    /// Gain in dB per 10 ms frame.
    static func curve(_ x: [Float], vad: [Bool], strength: Double) -> ([Double], CurveInfo) {
        let n = vad.count
        guard n > 0, vad.filter({ $0 }).count >= 50 else { return ([Double](repeating: 0, count: n), CurveInfo(range: 0)) }
        let p = Array(powerFrames(x, win: 400 * sr / 1000).prefix(n))
        let k = 40
        // sliding sums over k frames (centered)
        func centered(_ v: [Double]) -> [Double] {
            var cum = [Double](repeating: 0, count: v.count + 1)
            for i in 0..<v.count { cum[i + 1] = cum[i] + v[i] }
            return (0..<v.count).map { i in
                let a = max(0, i - k / 2), b = min(v.count, i + k / 2)
                return cum[b] - cum[a]
            }
        }
        let sp = centered((0..<n).map { vad[$0] ? p[$0] : 0 })
        let cnt = centered(vad.map { $0 ? 1 : 0 })
        let valid = (0..<n).map { vad[$0] && cnt[$0] >= Double(k) * 0.3 }
        var loud = [Double](repeating: .nan, count: n)
        for i in 0..<n where valid[i] { loud[i] = db10(sp[i] / cnt[i]) }
        let vals = loud.filter { !$0.isNaN }
        let target = Analysis.percentile(vals, 60)
        let maxBoost = 3 + 13 * strength, maxCut = 2 + 8 * strength
        var g = [Double](repeating: .nan, count: n)
        for i in 0..<n where valid[i] { g[i] = min(maxBoost, max(-maxCut, (target - loud[i]) * strength)) }
        // pauses: linear bridge between phrases, edges hold
        let idx = (0..<n).filter { !g[$0].isNaN }
        var filled = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            while j + 1 < idx.count && idx[j + 1] <= i { j += 1 }
            if i <= idx[0] { filled[i] = g[idx[0]] }
            else if i >= idx[idx.count - 1] { filled[i] = g[idx[idx.count - 1]] }
            else {
                let a = idx[j], b = idx[j + 1]
                filled[i] = g[a] + (g[b] - g[a]) * Double(i - a) / Double(b - a)
            }
        }
        let smooth = zeroPhaseSmooth(filled, tau: 0.6)
        let gv = (0..<n).filter { valid[$0] }.map { smooth[$0] }
        let range = Analysis.percentile(gv, 95) - Analysis.percentile(gv, 5)
        return (smooth, CurveInfo(range: (range * 10).rounded() / 10, speechLevel: (target * 10).rounded() / 10))
    }

    /// Long-term average speech spectrum, octave bands, dB re 1 kHz (Byrne et al. 1994).
    static let ltass: [(Int, Double)] = [(125, 4), (250, 7), (500, 6), (1000, 0), (2000, -5), (4000, -9), (8000, -14)]

    static func autoEQ(_ x: [Float], vad: [Bool], amount: Double = 0.6, limit: Double = 4) -> [(Int, Double)] {
        let frames = vad.indices.filter { vad[$0] }
        guard frames.count >= 100 else { return [] }
        let win = 2048
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: win, isHalfWindow: false)
        var spec = [Double](repeating: 0, count: win / 2)
        let step = max(1, frames.count / 600)
        var used = 0
        for f in stride(from: 0, to: frames.count, by: step) {
            let s = frames[f] * hop
            guard s + win <= x.count else { continue }
            let p = Analysis.powerSpectrum(Array(x[s..<(s + win)]), window: window)
            for i in 0..<spec.count { spec[i] += p[i] }
            used += 1
        }
        guard used > 0 else { return [] }
        let binHz = Double(sr) / Double(win)
        func band(_ c: Int) -> Double {
            let lo = Int(Double(c) / 1.414 / binHz), hi = min(Int(min(Double(c) * 1.414, Double(sr) / 2 - 100) / binHz), spec.count)
            return db10(spec[lo..<hi].reduce(0, +))
        }
        let ref = band(1000)
        var out: [(Int, Double)] = []
        for (c, t) in ltass where c != 1000 {
            var diff = (t - (band(c) - ref)) * amount
            if c == 125 { diff = min(diff, 0) }
            if c == 8000 { diff = min(diff, 3) }
            let g = min(limit, max(-limit, diff))
            if abs(g) >= 0.75 { out.append((c, (g * 10).rounded() / 10)) }
        }
        return out
    }

    /// Streams `src` through a per-sample gain curve (10 ms resolution, linear interpolation).
    static func applyGain(_ src: URL, _ dst: URL, gainDb: [Double], sampleRate: Int, channels: Int) throws {
        guard let ff = Tools.ffmpeg else { throw Tools.Failure(message: "ffmpeg non trovato") }
        let rd = Process(), wr = Process()
        rd.executableURL = URL(fileURLWithPath: ff)
        rd.arguments = ["-v", "error", "-i", src.path, "-f", "f32le", "-ac", "\(channels)", "-ar", "\(sampleRate)", "-"]
        wr.executableURL = URL(fileURLWithPath: ff)
        wr.arguments = ["-v", "error", "-y", "-f", "f32le", "-ar", "\(sampleRate)", "-ac", "\(channels)", "-i", "-",
                        "-c:a", "pcm_f32le", dst.path]
        let rp = Pipe(), wp = Pipe()
        rd.standardOutput = rp
        rd.standardError = FileHandle.nullDevice
        wr.standardInput = wp
        wr.standardError = FileHandle.nullDevice
        try rd.run()
        try wr.run()
        let lin = gainDb.map { Float(pow(10, $0 / 20)) }
        let reader = rp.fileHandleForReading, writer = wp.fileHandleForWriting
        var pos = 0
        let frameBytes = channels * 4
        var carry = Data()
        while true {
            let chunk = reader.readData(ofLength: sampleRate * frameBytes)
            if chunk.isEmpty { break }
            var data = carry + chunk
            let usable = data.count / frameBytes * frameBytes
            carry = data.suffix(from: data.startIndex + usable)
            data = data.prefix(usable)
            var samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let frames = samples.count / channels
            for f in 0..<frames {
                let t = Double(pos + f) / Double(sampleRate) * 100 - 0.5   // frame-centre index
                var g: Float = 1
                if !lin.isEmpty {
                    if t <= 0 { g = lin[0] }
                    else if t >= Double(lin.count - 1) { g = lin[lin.count - 1] }
                    else {
                        let i = Int(t), fr = Float(t - Double(i))
                        g = lin[i] + (lin[i + 1] - lin[i]) * fr
                    }
                }
                for c in 0..<channels { samples[f * channels + c] *= g }
            }
            pos += frames
            samples.withUnsafeBytes { writer.write(Data($0)) }
        }
        try writer.close()
        rd.waitUntilExit()
        wr.waitUntilExit()
        if rd.terminationStatus != 0 || wr.terminationStatus != 0 {
            throw Tools.Failure(message: "Applicazione del guadagno non riuscita")
        }
    }
}
