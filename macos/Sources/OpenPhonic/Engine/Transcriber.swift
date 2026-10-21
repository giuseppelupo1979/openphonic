import AVFoundation
import Foundation
import Speech

/// On-device transcription with Apple's SpeechAnalyzer (word timings for subtitles and filler cutting).
enum Transcriber {
    struct Word: Codable, Hashable { var text: String; var start: Double; var end: Double }
    struct Segment: Codable, Hashable { var text: String; var start: Double; var end: Double; var words: [Word] }

    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhm", "hmm", "hm", "mm", "mmm", "er", "erm", "ah", "eh", "ehm", "ehh",
        "mhm", "m", "mh", "mmh", "eeh", "ehhm",
    ]

    static func isFiller(_ w: String) -> Bool {
        fillers.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
    }

    static func transcribe(_ url: URL, locale: Locale) async throws -> [Segment] {
        guard SpeechTranscriber.isAvailable else {
            throw Tools.Failure(message: "Il riconoscimento vocale non è disponibile su questo Mac")
        }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Tools.Failure(message: "Lingua \(locale.identifier) non supportata dal riconoscimento vocale")
        }
        let module = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [],
                                       attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () throws -> [Segment] in
            var segments: [Segment] = []
            for try await result in module.results {
                var words: [Word] = []
                for run in result.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                        .trimmingCharacters(in: .whitespaces)
                    if text.isEmpty { continue }
                    words.append(Word(text: text, start: tr.start.seconds, end: tr.end.seconds))
                }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                segments.append(Segment(text: text, start: result.range.start.seconds,
                                        end: result.range.end.seconds, words: words))
            }
            return segments
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    // MARK: subtitles

    static func timestamp(_ t: Double, sep: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, sep, ms % 1000)
    }

    static func write(_ segs: [Segment], to dir: URL, stem: String) throws -> [URL] {
        let srt = segs.enumerated().map { i, s in
            "\(i + 1)\n\(timestamp(s.start, sep: ",")) --> \(timestamp(s.end, sep: ","))\n\(s.text)\n"
        }.joined(separator: "\n")
        let vtt = "WEBVTT\n\n" + segs.map {
            "\(timestamp($0.start, sep: ".")) --> \(timestamp($0.end, sep: "."))\n\($0.text)\n"
        }.joined(separator: "\n")
        let txt = segs.map(\.text).joined(separator: "\n") + "\n"
        var out: [URL] = []
        for (ext, body) in [("srt", srt), ("vtt", vtt), ("txt", txt)] {
            let u = dir.appendingPathComponent("\(stem).\(ext)")
            try body.write(to: u, atomically: true, encoding: .utf8)
            out.append(u)
        }
        return out
    }
}
