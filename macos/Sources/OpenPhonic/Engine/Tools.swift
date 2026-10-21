import Foundation

/// Locates and runs the external command line tools the engine relies on.
enum Tools {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in searchPaths + env {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var ffmpeg: String? { find("ffmpeg") }
    static var ffprobe: String? { find("ffprobe") }

    /// DeepFilterNet ships inside the app bundle; in development it is taken from the repo's bin/.
    static var deepFilter: String? {
        if let p = Bundle.main.path(forResource: "deep-filter", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../web/bin").standardized
        if let items = try? FileManager.default.contentsOfDirectory(atPath: dev.path),
           let f = items.first(where: { $0.hasPrefix("deep-filter") }) {
            return dev.appendingPathComponent(f).path
        }
        return find("deep-filter")
    }

    static var rnnoiseModel: String? {
        if let p = Bundle.main.path(forResource: "std", ofType: "rnnn") { return p }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../web/models/std.rnnn").standardized.path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// Runs a tool to completion; returns stdout and stderr.
    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> (out: Data, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // drain both pipes concurrently so a chatty process never blocks on a full buffer
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        let errText = String(decoding: errData, as: UTF8.self)
        if p.terminationStatus != 0 {
            let tail = errText.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw Failure(message: "\((exe as NSString).lastPathComponent) non riuscito:\n\(tail)")
        }
        return (outData, errText)
    }

    @discardableResult
    static func ffmpeg(_ args: [String]) throws -> String {
        guard let exe = ffmpeg else { throw Failure(message: "ffmpeg non trovato. Installalo con: brew install ffmpeg") }
        return try run(exe, ["-hide_banner", "-nostdin", "-y"] + args).err
    }
}
