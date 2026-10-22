import Foundation

/// Entry point. `OpenPhonic --process <file>` runs the engine headless (used for testing), with:
///   --out <dir>  --preset <id>  --cut  --transcribe  --video
///   --denoise ai|rnnoise|classic  --amount auto|low|medium|high|max
///   --compressor auto|soft|medium|hard|off  --intro <f>  --outro <f>  --cover <f>
///   --all  (every option on and every output format)
/// Otherwise the SwiftUI app starts.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--process"), i + 1 < args.count else {
            OpenPhonicApp.main()
            return
        }
        let src = URL(fileURLWithPath: args[i + 1])
        let out = args.firstIndex(of: "--out").map { URL(fileURLWithPath: args[$0 + 1]) }
            ?? src.deletingLastPathComponent().appendingPathComponent("OpenPhonic")
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        var s = value("--preset").flatMap { id in Preset.all.first { $0.id == id } }?.settings() ?? ProductionSettings()
        if value("--preset") == nil {
            s.outputs = [.init(format: .wav), .init(format: .mp3)]
        }
        if args.contains("--transcribe") { s.transcribe = true }
        if args.contains("--cut") { s.cutSilence = true }
        if args.contains("--video") { s.outputs.append(.init(format: .video)) }
        if let m = value("--denoise").flatMap(ProductionSettings.DenoiseMethod.init(rawValue:)) { s.denoiseMethod = m }
        if let a = value("--amount").flatMap(ProductionSettings.Amount.init(rawValue:)) { s.denoiseAmount = a }
        if let c = value("--compressor").flatMap(ProductionSettings.Compressor.init(rawValue:)) { s.compressor = c }
        if args.contains("--all") {
            s.deesser = true; s.deplosive = true; s.cutSilence = true; s.cutFillers = true; s.transcribe = true
            s.title = "Prova completa"; s.artist = "OpenPhonic"; s.album = "Test"
            s.outputs = ProductionSettings.Output.Format.allCases.map { .init(format: $0) }
        }
        let input = ProductionInput(source: src, intro: value("--intro").map(URL.init(fileURLWithPath:)),
                                    outro: value("--outro").map(URL.init(fileURLWithPath:)),
                                    cover: value("--cover").map(URL.init(fileURLWithPath:)), outputDir: out,
                                    workDir: FileManager.default.temporaryDirectory.appendingPathComponent("op-cli-\(UUID().uuidString)"))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let r = try await Pipeline(settings: s, input: input) { step, p in
                    print(String(format: "%5.1f%%  %@", p * 100, step))
                }.run()
                print("NOTE:", r.notes.joined(separator: " | "))
                print("WARN:", r.warnings.joined(separator: " | "))
                print(String(format: "PRIMA  %.1f LUFS  TP %.1f  LRA %.1f  rumore %.1f  SNR %.1f",
                             r.before.integrated, r.before.truePeak, r.before.lra, r.before.noiseFloor, r.before.snr))
                print(String(format: "DOPO   %.1f LUFS  TP %.1f  LRA %.1f  rumore %.1f  SNR %.1f",
                             r.after.integrated, r.after.truePeak, r.after.lra, r.after.noiseFloor, r.after.snr))
                print("FILE:", r.files.map(\.path).joined(separator: "\n      "))
                print(String(format: "TEMPO  %.1f s", r.seconds))
                if !r.transcript.isEmpty { print("TESTO:", r.transcript.map(\.text).joined(separator: " ")) }
            } catch {
                print("ERRORE:", error.localizedDescription)
            }
            done.signal()
        }
        done.wait()
    }
}
