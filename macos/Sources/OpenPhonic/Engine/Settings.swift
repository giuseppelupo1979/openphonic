import Foundation

/// Production settings (same options as the web version).
struct ProductionSettings: Codable, Hashable {
    enum Compressor: String, Codable, CaseIterable { case auto, soft, medium, hard, off }
    enum DenoiseMethod: String, Codable, CaseIterable { case ai, rnnoise, classic }
    enum Amount: String, Codable, CaseIterable { case auto, low, medium, high, max }
    enum Content: String, Codable, CaseIterable { case speech, music }

    struct Output: Codable, Hashable, Identifiable {
        enum Format: String, Codable, CaseIterable { case mp3, aac, opus, flac, wav, video }
        enum Channels: String, Codable, CaseIterable { case keep, mono, stereo }
        var id = UUID()
        var format: Format = .mp3
        var bitrate = 160
        var channels: Channels = .keep

        var ext: String {
            switch format {
            case .mp3: "mp3"
            case .aac: "m4a"
            case .opus: "opus"
            case .flac: "flac"
            case .wav: "wav"
            case .video: "mp4"
            }
        }
        var isLossless: Bool { format == .flac || format == .wav }
    }

    var content: Content = .speech

    var levelerOn = true
    var levelerStrength = 100.0
    var compressor: Compressor = .auto

    var filterOn = true
    var highpass = 75
    var humAuto = true
    var autoEQ = true
    var deesser = false
    var deplosive = false

    var denoiseOn = true
    var denoiseMethod: DenoiseMethod = .ai
    var denoiseAmount: Amount = .auto

    var loudnessOn = true
    var loudnessTarget = -16.0
    var truePeak = -1.0

    var cutSilence = false
    var minSilence = 1.0
    var keepSilence = 0.4
    var cutFillers = false

    var transcribe = false
    var language = "it-IT"

    var outputs: [Output] = [Output()]

    var title = ""
    var artist = ""
    var album = ""
}

struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    let apply: (inout ProductionSettings) -> Void

    static func == (a: Preset, b: Preset) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let all: [Preset] = [
        Preset(id: "podcast", name: "Podcast", subtitle: "−16 LUFS · voce pulita e presente", symbol: "mic.fill") { _ in },
        Preset(id: "youtube", name: "YouTube & Spotify", subtitle: "−14 LUFS · più forte", symbol: "play.rectangle.fill") {
            $0.loudnessTarget = -14
        },
        Preset(id: "broadcast", name: "Broadcast EBU", subtitle: "−23 LUFS · radio e TV", symbol: "antenna.radiowaves.left.and.right") {
            $0.loudnessTarget = -23
        },
        Preset(id: "audiobook", name: "Audiolibro ACX", subtitle: "−19 LUFS · mono 192 kbps", symbol: "book.fill") {
            $0.loudnessTarget = -19; $0.truePeak = -3
            $0.outputs = [.init(format: .mp3, bitrate: 192, channels: .mono)]
        },
        Preset(id: "rescue", name: "Salvataggio", subtitle: "Registrazioni difficili e rumorose", symbol: "lifepreserver.fill") {
            $0.denoiseAmount = .high; $0.deesser = true; $0.deplosive = true; $0.cutSilence = true
        },
        Preset(id: "music", name: "Musica", subtitle: "Solo loudness, nessun trattamento voce", symbol: "music.note") {
            $0.content = .music; $0.denoiseOn = false; $0.filterOn = false
            $0.outputs = [.init(format: .flac), .init(format: .mp3, bitrate: 256)]
        },
    ]

    func settings() -> ProductionSettings {
        var s = ProductionSettings()
        apply(&s)
        return s
    }
}
