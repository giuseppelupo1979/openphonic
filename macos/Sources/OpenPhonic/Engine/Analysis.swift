import Accelerate
import Foundation

/// Signal analysis driving the automatic decisions (port of the web engine's analysis.py).
enum Analysis {
    static let sr = 16000

    struct NoiseProfile: Codable, Hashable {
        var noiseFloor: Double
        var signalLevel: Double
        var snr: Double
    }

    struct Hum: Codable, Hashable {
        var detected: Bool
        var baseFreq: Int?
        var strength: Double
    }

    static func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-9)) }

    /// RMS of `frame`-sample windows every `hop` samples.
    static func frameRMS(_ x: [Float], frame: Int, hop: Int) -> [Double] {
        guard x.count >= frame else {
            guard !x.isEmpty else { return [0] }
            return [Double(vDSP.rootMeanSquare(x))]
        }
        let n = 1 + (x.count - frame) / hop
        return x.withUnsafeBufferPointer { buf in
            (0..<n).map { i in
                Double(vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: buf[(i * hop)..<(i * hop + frame)])))
            }
        }
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let pos = p / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func noiseProfile(_ x: [Float]) -> NoiseProfile {
        let rms = frameRMS(x, frame: sr / 20, hop: sr / 40).filter { $0 > 1e-6 }
        guard !rms.isEmpty else { return NoiseProfile(noiseFloor: -99, signalLevel: -99, snr: 0) }
        let floor = db(percentile(rms, 10)), level = db(percentile(rms, 95))
        return NoiseProfile(noiseFloor: (floor * 10).rounded() / 10, signalLevel: (level * 10).rounded() / 10,
                            snr: ((level - floor) * 10).rounded() / 10)
    }

    /// Power spectrum of a real signal (length must be a power of two).
    static func powerSpectrum(_ seg: [Float], window: [Float]) -> [Double] {
        let n = seg.count
        let log2n = vDSP_Length(log2(Double(n)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let w = vDSP.multiply(seg, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
        var out = [Double](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                fft.forward(input: split, output: &split)
                for i in 0..<(n / 2) {
                    out[i] = Double(rp[i] * rp[i] + ip[i] * ip[i])
                }
            }
        }
        return out
    }

    /// Mains hum (50/60 Hz + harmonics) in the quietest ~1 s frames.
    static func detectHum(_ x: [Float]) -> Hum {
        let frame = 16384, hop = 8000
        guard x.count >= frame else { return Hum(detected: false, baseFreq: nil, strength: 0) }
        let rms = frameRMS(x, frame: frame, hop: hop)
        let pick = Array(rms.indices.sorted { rms[$0] < rms[$1] }.prefix(max(3, Int(Double(rms.count) * 0.3))))
        let win = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
        var spec = [Double](repeating: 0, count: frame / 2)
        for i in pick {
            let s = powerSpectrum(Array(x[(i * hop)..<(i * hop + frame)]), window: win)
            for k in 0..<spec.count { spec[k] += s[k] }
        }
        let binHz = Double(sr) / Double(frame)
        func score(_ f0: Int) -> Double {
            var vals: [Double] = []
            for k in 1...4 {
                let c = Int((Double(f0 * k) / binHz).rounded())
                let peak = spec[(c - 1)...(c + 1)].max() ?? 0
                let neigh = Array(spec[(c - 15)...(c - 3)]) + Array(spec[(c + 4)...(c + 16)])
                let med = max(percentile(neigh, 50), 1e-20)
                vals.append(10 * log10(max(peak, 1e-20) / med))
            }
            return vals.sorted().suffix(3).reduce(0, +) / 3
        }
        let s50 = score(50), s60 = score(60)
        let (base, strength) = s50 >= s60 ? (50, s50) : (60, s60)
        let detected = strength > 9
        return Hum(detected: detected, baseFreq: detected ? base : nil, strength: (strength * 10).rounded() / 10)
    }

    /// Max-abs envelope for drawing (0...1).
    static func peaks(_ x: [Float], points: Int = 1600) -> [Float] {
        guard !x.isEmpty else { return [] }
        let chunk = max(1, x.count / points)
        let n = x.count / chunk
        return x.withUnsafeBufferPointer { buf in
            (0..<n).map { i in
                min(1, vDSP.maximumMagnitude(UnsafeBufferPointer(rebasing: buf[(i * chunk)..<((i + 1) * chunk)])))
            }
        }
    }

    /// Pauses: runs of 20 ms frames under the threshold lasting at least `minDur` seconds.
    static func silences(_ x: [Float], thresholdDb: Double, minDur: Double) -> [(Double, Double)] {
        let hop = sr / 50
        let rms = frameRMS(x, frame: hop, hop: hop).map(db)
        var out: [(Double, Double)] = []
        var start: Int?
        for (i, v) in (rms + [0]).enumerated() {
            if v < thresholdDb && i < rms.count {
                if start == nil { start = i }
            } else if let s = start {
                if Double(i - s) * Double(hop) / Double(sr) >= minDur {
                    out.append((Double(s * hop) / Double(sr), Double(i * hop) / Double(sr)))
                }
                start = nil
            }
        }
        return out
    }
}
