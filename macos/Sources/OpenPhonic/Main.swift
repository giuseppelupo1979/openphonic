import Foundation

/// Entry point: `OpenPhonic --process <file> [--out <dir>] [--transcribe]` runs the engine headless
/// (used for testing); otherwise the SwiftUI app starts.
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
        var s = ProductionSettings()
        s.transcribe = args.contains("--transcribe")
        s.cutSilence = args.contains("--cut")
        s.outputs = [.init(format: .wav), .init(format: .mp3)] + (args.contains("--video") ? [.init(format: .video)] : [])
        let input = ProductionInput(source: src, outputDir: out,
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
