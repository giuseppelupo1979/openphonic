import CryptoKit
import Foundation

/// Self-update from GitHub Releases: the latest release must carry OpenPhonic-macos.zip and
/// OpenPhonic-macos.zip.sha256. The download is verified (hash and code signature) before anything
/// is replaced. OPENPHONIC_UPDATE_URL overrides the release endpoint (used to test with a fake release).
enum Updater {
    static let repo = "giuseppelupo1979/openphonic"
    static let assetName = "OpenPhonic-macos.zip"

    struct Release: Equatable {
        var version: String
        var tag: String
        var notes: String
        var url: String
        var assetURL: URL
        var shaURL: URL
    }

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static var endpoint: URL {
        if let s = ProcessInfo.processInfo.environment["OPENPHONIC_UPDATE_URL"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 600)
        r.setValue("OpenPhonic/\(current)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return r
    }

    /// The latest release if it is newer than this build and has a verified Mac package.
    static func check() async throws -> Release? {
        let (data, _) = try await URLSession.shared.data(for: request(endpoint))
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { return nil }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard isNewer(version, than: current) else { return nil }
        let assets = j["assets"] as? [[String: Any]] ?? []
        func url(_ name: String) -> URL? {
            (assets.first { $0["name"] as? String == name }?["browser_download_url"] as? String).flatMap(URL.init(string:))
        }
        guard let a = url(assetName), let s = url(assetName + ".sha256") else { return nil }
        return Release(version: version, tag: tag, notes: j["body"] as? String ?? "",
                       url: j["html_url"] as? String ?? "", assetURL: a, shaURL: s)
    }

    /// Downloads, verifies and stages the new app, then starts a helper that swaps it in once this
    /// process has quit and reopens it. The caller must terminate the app right after.
    static func prepare(_ r: Release, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("openphonic-update")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let (shaData, _) = try await URLSession.shared.data(for: request(r.shaURL))
        let expected = String(decoding: shaData, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map { $0.lowercased() } ?? ""

        let zip = dir.appendingPathComponent(assetName)
        progress(0.05)
        let (tmp, _) = try await URLSession.shared.download(for: request(r.assetURL))
        try fm.moveItem(at: tmp, to: zip)
        progress(0.9)
        var hasher = SHA256()
        let fh = try FileHandle(forReadingFrom: zip)
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        try fh.close()
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard expected.count == 64, actual == expected else {
            throw Tools.Failure(message: "Il pacchetto scaricato non corrisponde all'impronta pubblicata: aggiornamento annullato")
        }

        let staged = dir.appendingPathComponent("new")
        try Tools.run("/usr/bin/ditto", ["-x", "-k", zip.path, staged.path])
        let newApp = staged.appendingPathComponent("OpenPhonic.app")
        guard fm.fileExists(atPath: newApp.path) else { throw Tools.Failure(message: "Il pacchetto non contiene OpenPhonic.app") }
        do { try Tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) }
        catch { throw Tools.Failure(message: "La firma della nuova versione non è valida: aggiornamento annullato") }

        // swap the bundles once we have quit, then reopen
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(target.path).old"
        mv "\(target.path)" "\(target.path).old" && mv "\(newApp.path)" "\(target.path)" && rm -rf "\(target.path).old"
        open "\(target.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
    }
}
