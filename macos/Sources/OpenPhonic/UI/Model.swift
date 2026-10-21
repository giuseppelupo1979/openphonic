import AppKit
import Observation
import SwiftUI

struct Production: Identifiable, Codable, Hashable {
    enum Status: String, Codable { case setup, queued, processing, done, failed }

    var id = UUID()
    var source: URL
    var created = Date()
    var settings = ProductionSettings()
    var intro: URL?
    var outro: URL?
    var cover: URL?
    var info: FF.ProbeInfo?
    var status: Status = .setup
    var step = ""
    var progress = 0.0
    var error: String?
    var result: ProductionResult?

    var name: String { settings.title.isEmpty ? source.deletingPathExtension().lastPathComponent : settings.title }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var productions: [Production] = []
    var selection: UUID?
    var showingHome = true
    var outputFolder: URL {
        didSet { UserDefaults.standard.set(outputFolder.path, forKey: "outputFolder") }
    }
    let ffmpegAvailable = Tools.ffmpeg != nil && Tools.ffprobe != nil
    let deepFilterAvailable = Tools.deepFilter != nil
    private var running = false

    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenPhonic", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private var store: URL { Self.support.appendingPathComponent("productions.json") }

    init() {
        let def = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenPhonic")
        outputFolder = UserDefaults.standard.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) } ?? def
        if let d = try? Data(contentsOf: store), let list = try? JSONDecoder().decode([Production].self, from: d) {
            // anything interrupted by quitting goes back to setup
            productions = list.map { p in
                var p = p
                if p.status == .processing || p.status == .queued { p.status = .setup; p.progress = 0 }
                return p
            }
        }
    }

    var selected: Production? {
        get { productions.first { $0.id == selection } }
        set {
            guard let nv = newValue, let i = productions.firstIndex(where: { $0.id == nv.id }) else { return }
            productions[i] = nv
            save()
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(productions) { try? d.write(to: store, options: .atomic) }
    }

    func add(_ urls: [URL], preset: Preset) {
        var last: UUID?
        for u in urls {
            var p = Production(source: u)
            p.settings = preset.settings()
            p.info = try? FF.probe(u)
            // a video in, a video out: the cleaned audio goes back into the film as well
            if p.info?.hasVideo == true && !p.settings.outputs.contains(where: { $0.format == .video }) {
                p.settings.outputs.append(.init(format: .video))
            }
            productions.insert(p, at: 0)
            last = p.id
        }
        if let last {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                selection = last
                showingHome = false
            }
        }
        save()
    }

    func remove(_ id: UUID) {
        guard let p = productions.first(where: { $0.id == id }), p.status != .processing else { return }
        try? FileManager.default.removeItem(at: Self.support.appendingPathComponent("work/\(id.uuidString)"))
        productions.removeAll { $0.id == id }
        if selection == id { selection = nil; showingHome = true }
        save()
    }

    func start(_ id: UUID) {
        guard let i = productions.firstIndex(where: { $0.id == id }) else { return }
        productions[i].status = .queued
        productions[i].step = "In coda"
        productions[i].progress = 0
        productions[i].error = nil
        save()
        pump()
    }

    func startAll() {
        for p in productions where p.status == .setup { start(p.id) }
    }

    private func update(_ id: UUID, _ f: (inout Production) -> Void) {
        guard let i = productions.firstIndex(where: { $0.id == id }) else { return }
        f(&productions[i])
    }

    /// Processes the queue one production at a time.
    private func pump() {
        guard !running, let next = productions.last(where: { $0.status == .queued }) else { return }
        running = true
        let id = next.id
        update(id) { $0.status = .processing; $0.step = "Preparazione" }
        let folder = outputFolder.appendingPathComponent(sanitize(next.name))
        let input = ProductionInput(source: next.source, intro: next.intro, outro: next.outro, cover: next.cover,
                                    outputDir: folder,
                                    workDir: Self.support.appendingPathComponent("work/\(id.uuidString)"))
        let settings = next.settings
        Task.detached {
            do {
                try? FileManager.default.removeItem(at: input.workDir)
                let r = try await Pipeline(settings: settings, input: input) { step, p in
                    Task { @MainActor in
                        self.update(id) { $0.step = step; $0.progress = p }
                    }
                }.run()
                await MainActor.run {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        self.update(id) { $0.status = .done; $0.result = r; $0.progress = 1 }
                    }
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                await MainActor.run {
                    self.update(id) { $0.status = .failed; $0.error = error.localizedDescription }
                }
            }
            await MainActor.run {
                self.running = false
                self.save()
                self.pump()
            }
        }
    }

    private func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" }).prefix(80).description
    }
}
