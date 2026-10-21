import AVFoundation
import SwiftUI

@MainActor
@Observable
final class ABPlayer {
    var side: Side = .after
    var playing = false
    var fraction = 0.0
    var current = 0.0
    var duration = 0.0
    enum Side { case before, after }

    private var players: [Side: AVAudioPlayer] = [:]
    private var timer: Timer?

    init(before: URL, after: URL) {
        players[.before] = try? AVAudioPlayer(contentsOf: before)
        players[.after] = try? AVAudioPlayer(contentsOf: after)
        players.values.forEach { $0.prepareToPlay() }
        duration = players[.after]?.duration ?? 0
    }

    var active: AVAudioPlayer? { players[side] }

    func toggle() {
        guard let p = active else { return }
        if p.isPlaying { p.pause(); playing = false; timer?.invalidate() }
        else { p.play(); playing = true; startTimer() }
    }

    func stop() { players.values.forEach { $0.stop() }; timer?.invalidate(); playing = false }

    func switchTo(_ s: Side) {
        guard s != side, let from = active, let to = players[s] else { return }
        let f = from.duration > 0 ? from.currentTime / from.duration : 0
        let wasPlaying = from.isPlaying
        from.pause()
        to.currentTime = f * to.duration
        side = s
        duration = to.duration
        if wasPlaying { to.play() }
        tick()
    }

    func seek(_ f: Double, side s: Side) {
        if s != side { switchTo(s) }
        guard let p = active else { return }
        p.currentTime = f * p.duration
        tick()
    }

    func seekSeconds(_ t: Double) {
        if side != .after { switchTo(.after) }
        guard let p = active else { return }
        p.currentTime = t
        if !p.isPlaying { p.play(); playing = true; startTimer() }
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = active else { return }
        current = p.currentTime
        fraction = p.duration > 0 ? p.currentTime / p.duration : 0
        if !p.isPlaying && playing { playing = false; timer?.invalidate() }
    }
}

struct ResultView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        if let p = model.productions.first(where: { $0.id == id }), let r = p.result {
            ResultContent(p: p, r: r) {
                var c = p
                c.status = .setup
                c.result = nil
                model.selected = c
            }
        }
    }
}

private struct ResultContent: View {
    let p: Production
    let r: ProductionResult
    let reprocess: () -> Void
    @Local private var player: ABPlayer
    @Local private var shown = false

    init(p: Production, r: ProductionResult, reprocess: @escaping () -> Void) {
        self.p = p
        self.r = r
        self.reprocess = reprocess
        _player = Local(initialValue: ABPlayer(before: r.previewBefore, after: r.previewAfter))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                playerCard
                stats
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        spectrumCard
                        if !r.transcript.isEmpty { transcriptCard }
                    }
                    VStack(spacing: 18) {
                        filesCard
                        notesCard
                    }
                    .frame(width: 360)
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 40)
        }
        .scrollIndicators(.never)
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.1)) { shown = true } }
        .onDisappear { player.stop() }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().fill(Theme.accentDiagonal).frame(width: 56, height: 56)
                    .shadow(color: Theme.rose.opacity(0.6), radius: 16)
                Image(systemName: "checkmark").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white)
            }
            .scaleEffect(shown ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.rounded(30, .heavy)).lineLimit(1)
                Text(String(format: "Pronta in %.0f secondi · %@ · %d file", r.seconds, formatDuration(r.after.duration), r.files.count))
                    .font(.rounded(13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            Button { reprocess() } label: { Label("Modifica e rielabora", systemImage: "slider.horizontal.3") }
                .buttonStyle(GhostButtonStyle())
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(r.files)
            } label: { Label("Mostra nel Finder", systemImage: "folder.fill") }
                .buttonStyle(GlowButtonStyle(big: false))
        }
    }

    // MARK: player

    var playerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            WaveRow(label: "PRIMA", color: .white.opacity(0.55), peaks: r.peaksBefore,
                    fraction: player.side == .before ? player.fraction : nil, glow: false) { player.seek($0, side: .before) }
                .opacity(player.side == .before ? 1 : 0.55)
            WaveRow(label: "DOPO", color: Theme.rose, peaks: r.peaksAfter,
                    fraction: player.side == .after ? player.fraction : nil, glow: true) { player.seek($0, side: .after) }
                .opacity(player.side == .after ? 1 : 0.55)
            HStack(spacing: 18) {
                Button { player.toggle() } label: {
                    ZStack {
                        Circle().fill(Theme.accentDiagonal).frame(width: 58, height: 58)
                            .shadow(color: Theme.rose.opacity(0.7), radius: player.playing ? 22 : 12)
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .offset(x: player.playing ? 0 : 2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                ChipPicker(options: [(ABPlayer.Side.before, "Prima"), (.after, "Dopo")],
                           selection: Binding(get: { player.side }, set: { player.switchTo($0) }))
                    .scaleEffect(1.15)

                Text("\(formatDuration(player.current)) / \(formatDuration(player.duration))")
                    .font(.rounded(14, .medium)).monospacedDigit().foregroundStyle(Theme.text2)
                Spacer()
                Text("Spazio per play/pausa · clic sulle onde per saltare").font(.rounded(11)).foregroundStyle(Theme.text3)
            }
        }
        .glassCard(radius: 26, padding: 22)
    }

    // MARK: stats

    var stats: some View {
        HStack(spacing: 14) {
            StatTile(title: "Loudness", unit: "LUFS", before: r.before.integrated, after: r.after.integrated,
                     symbol: "speaker.wave.3.fill", shown: shown, note: "target \(Int(p.settings.loudnessTarget))")
            StatTile(title: "Segnale/rumore", unit: "dB", before: r.before.snr, after: r.after.snr,
                     symbol: "sparkles", shown: shown, better: .higher)
            StatTile(title: "Rumore di fondo", unit: "dBFS", before: r.before.noiseFloor, after: r.after.noiseFloor,
                     symbol: "wind", shown: shown, better: .lower)
            StatTile(title: "Picco reale", unit: "dBTP", before: r.before.truePeak, after: r.after.truePeak,
                     symbol: "waveform.path.ecg", shown: shown, note: "max \(String(format: "%.1f", p.settings.truePeak))")
            StatTile(title: "Escursione", unit: "LU", before: r.before.lra, after: r.after.lra,
                     symbol: "arrow.up.and.down", shown: shown, note: "loudness range")
        }
    }

    // MARK: cards

    var spectrumCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spettrogramma").font(.rounded(17, .bold))
                Spacer()
                Text("trascina per confrontare").font(.rounded(11)).foregroundStyle(Theme.text3)
            }
            SpectrumCompare(before: r.spectrumBefore, after: r.spectrumAfter)
        }
        .glassCard()
    }

    var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File pronti").font(.rounded(17, .bold))
            ForEach(r.files, id: \.self) { f in
                FileRow(url: f)
            }
            Text("Trascina un file direttamente in un'altra app").font(.rounded(11)).foregroundStyle(Theme.text3)
        }
        .glassCard()
    }

    var notesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cosa è stato fatto").font(.rounded(17, .bold))
            ForEach(r.warnings, id: \.self) { w in
                NoteRow(symbol: "exclamationmark.triangle.fill", color: .yellow, text: w)
            }
            ForEach(r.notes, id: \.self) { n in
                NoteRow(symbol: icon(for: n), color: Theme.ember, text: n)
            }
        }
        .glassCard()
    }

    func icon(for note: String) -> String {
        if note.contains("rumore") { return "sparkles" }
        if note.contains("AutoEQ") { return "dial.medium" }
        if note.contains("Leveler") { return "slider.vertical.3" }
        if note.contains("Ronzio") { return "bolt.slash.fill" }
        if note.contains("Tagliat") { return "scissors" }
        if note.contains("Trascritt") { return "captions.bubble.fill" }
        return "checkmark.circle.fill"
    }

    var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trascrizione").font(.rounded(17, .bold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(r.transcript.enumerated()), id: \.offset) { _, seg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Button(formatDuration(seg.start)) { player.seekSeconds(seg.start) }
                                .buttonStyle(.plain)
                                .font(.rounded(12, .bold)).monospacedDigit()
                                .foregroundStyle(Theme.ember)
                            Text(seg.text).font(.rounded(14)).textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .glassCard()
    }
}

// MARK: - pieces

struct WaveRow: View {
    let label: String
    let color: Color
    let peaks: [Float]
    let fraction: Double?
    let glow: Bool
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(glow ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(color)).frame(width: 7, height: 7)
                Text(label).font(.rounded(11, .heavy)).tracking(1.2).foregroundStyle(Theme.text2)
            }
            GeometryReader { geo in
                Canvas { g, size in
                    guard !peaks.isEmpty else { return }
                    let n = Int(size.width / 3)
                    let mid = size.height / 2
                    var played = Path(), rest = Path()
                    for i in 0..<n {
                        let lo = i * peaks.count / n, hi = max(lo + 1, (i + 1) * peaks.count / n)
                        let v = CGFloat(peaks[lo..<min(hi, peaks.count)].max() ?? 0)
                        let h = max(1.5, v * (mid - 3))
                        let rect = CGRect(x: CGFloat(i) * 3, y: mid - h, width: 2, height: h * 2)
                        if let f = fraction, Double(i) / Double(n) <= f { played.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1)) }
                        else { rest.addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1)) }
                    }
                    let grad = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: [Theme.ember, Theme.rose, Theme.violet]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                    let base: GraphicsContext.Shading = glow ? grad : .color(color)
                    g.opacity = 0.4
                    g.fill(rest, with: base)
                    g.opacity = 1
                    if glow { g.addFilter(.shadow(color: Theme.rose.opacity(0.8), radius: 6)) }
                    g.fill(played, with: glow ? grad : .color(.white))
                }
                .overlay(alignment: .leading) {
                    if let f = fraction {
                        Rectangle().fill(.white).frame(width: 2)
                            .shadow(color: .white, radius: 4)
                            .offset(x: geo.size.width * f - 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { seek(min(1, max(0, $0.location.x / geo.size.width))) })
            }
            .frame(height: 74)
        }
    }
}

struct StatTile: View {
    enum Better { case higher, lower, none }
    let title: String
    let unit: String
    let before: Double
    let after: Double
    let symbol: String
    let shown: Bool
    var better: Better = .none
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                Text(title).font(.rounded(12, .semibold)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", shown ? after : before))
                    .font(.rounded(32, .heavy)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: shown ? after : before))
                Text(unit).font(.rounded(12, .semibold)).foregroundStyle(Theme.text3)
            }
            HStack(spacing: 6) {
                Text(String(format: "prima %.1f", before)).font(.rounded(11)).foregroundStyle(Theme.text3).monospacedDigit()
                if better != .none {
                    let d = after - before
                    let good = better == .higher ? d > 0 : d < 0
                    Text(String(format: "%+.0f", d))
                        .font(.rounded(11, .bold))
                        .foregroundStyle(good ? Theme.mint : .orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((good ? Theme.mint : .orange).opacity(0.15), in: Capsule())
                } else if let note {
                    Text(note).font(.rounded(11)).foregroundStyle(Theme.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 20, padding: 16)
    }
}

struct SpectrumCompare: View {
    let before: URL
    let after: URL
    @Local private var split = 0.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                image(after)
                image(before)
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * split) }
                Rectangle().fill(.white).frame(width: 2).shadow(color: .white, radius: 6)
                    .offset(x: geo.size.width * split - 1)
                Circle().fill(.white).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                    .shadow(radius: 6)
                    .offset(x: geo.size.width * split - 13)
                HStack {
                    tag("PRIMA")
                    Spacer()
                    tag("DOPO")
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / geo.size.width)) })
        }
        .aspectRatio(1400 / 300, contentMode: .fit)
    }

    func image(_ u: URL) -> some View {
        Group {
            if let img = NSImage(contentsOf: u) { Image(nsImage: img).resizable() } else { Color.black }
        }
    }

    func tag(_ t: String) -> some View {
        Text(t).font(.rounded(10, .heavy)).tracking(1).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }
}

struct FileRow: View {
    let url: URL
    @Local private var hover = false

    var size: String {
        let b = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(url.pathExtension.uppercased()).font(.rounded(10, .heavy)).foregroundStyle(.white)
                .frame(width: 44).padding(.vertical, 6)
                .background(Theme.accentDiagonal, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.rounded(13, .medium)).lineLimit(1).truncationMode(.middle)
                Text(size).font(.rounded(11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Image(systemName: "arrow.up.forward.app").foregroundStyle(hover ? .white : Theme.text3)
        }
        .padding(10)
        .background(.white.opacity(hover ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Apri") { NSWorkspace.shared.open(url) }
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

struct NoteRow: View {
    let symbol: String
    let color: Color
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).frame(width: 18)
            Text(text).font(.rounded(13)).foregroundStyle(.white.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
