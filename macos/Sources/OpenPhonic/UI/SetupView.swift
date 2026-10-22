import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        if let p = model.productions.first(where: { $0.id == id }) {
            SetupContent(p: p) { updated in
                model.selected = updated
            } start: {
                model.start(id)
            }
        }
    }
}

private struct SetupContent: View {
    let p: Production
    let update: (Production) -> Void
    let start: () -> Void

    var s: Binding<ProductionSettings> {
        Binding(get: { p.settings }, set: { var c = p; c.settings = $0; update(c) })
    }
    func file(_ kp: WritableKeyPath<Production, URL?>) -> Binding<URL?> {
        Binding(get: { p[keyPath: kp] }, set: { var c = p; c[keyPath: kp] = $0; update(c) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let err = p.error {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text(err).font(.rounded(13)).textSelection(.enabled)
                        }
                        .glassCard(radius: 16, padding: 14)
                    }
                    presets
                    // two independent columns: cards stay top-aligned whatever their height
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) { denoiseCard; filterCard; cutCard }
                        VStack(spacing: 18) { levelerCard; loudnessCard; speechCard }
                    }
                    HStack(alignment: .top, spacing: 18) {
                        outputsCard
                        metadataCard
                    }
                }
                .padding(.horizontal, 34)
                .padding(.top, 40)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.never)
        }
        .overlay(alignment: .bottom) { actionBar }
    }

    // MARK: header

    var header: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06)).frame(width: 64, height: 64)
                Image(systemName: p.info?.hasVideo == true ? "film.fill" : "waveform")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(p.name).font(.rounded(28, .heavy)).lineLimit(1)
                HStack(spacing: 8) {
                    if let i = p.info {
                        InfoChip(symbol: "clock", text: formatDuration(i.duration))
                        InfoChip(symbol: "waveform.path", text: "\(i.codec.uppercased()) · \(i.sampleRate / 1000) kHz")
                        InfoChip(symbol: i.channels > 1 ? "speaker.wave.2" : "speaker.wave.1", text: i.channels > 1 ? "Stereo" : "Mono")
                        if i.hasVideo { InfoChip(symbol: "film", text: "Video \(i.videoCodec?.uppercased() ?? "")") }
                    }
                }
            }
            Spacer()
        }
    }

    var presets: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Preset.all) { pr in
                    Button {
                        var c = pr.settings()
                        c.title = p.settings.title; c.artist = p.settings.artist; c.album = p.settings.album
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { s.wrappedValue = c }
                    } label: {
                        Label(pr.name, systemImage: pr.symbol)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: cards

    var denoiseCard: some View {
        AlgoCard(symbol: "sparkles", title: "Riduzione rumore", subtitle: "Rete neurale che separa la voce da rumore, ventole e riverbero",
                 isOn: s.denoiseOn) {
            Row("Metodo") {
                ChipPicker(options: [(.ai, "AI"), (.rnnoise, "RNNoise"), (.classic, "Classico (leggero)")], selection: s.denoiseMethod)
            }
            Row("Quantità") {
                ChipPicker(options: [(.auto, "Auto"), (.low, "Bassa"), (.medium, "Media"), (.high, "Alta"), (.max, "Max")],
                           selection: s.denoiseAmount)
            }
        }
    }

    var levelerCard: some View {
        AlgoCard(symbol: "slider.vertical.3", title: "Adaptive Leveler", subtitle: "Bilancia frase per frase, senza alzare il rumore nelle pause",
                 isOn: s.levelerOn) {
            Row("Intensità") {
                GlowSlider(value: s.levelerStrength, range: 0...100, step: 10, label: { "\(Int($0))%" })
            }
            Row("Compressore") {
                ChipPicker(options: [(.auto, "Auto"), (.soft, "Leggero"), (.medium, "Medio"), (.hard, "Forte"), (.off, "Off")],
                           selection: s.compressor)
            }
        }
    }

    var filterCard: some View {
        AlgoCard(symbol: "dial.medium", title: "Filtri e Voice AutoEQ", subtitle: "Rombi, ronzio elettrico, timbro, sibilanti e plosive",
                 isOn: s.filterOn) {
            Row("Passa-alto") {
                ChipPicker(options: [(0, "Off"), (60, "60 Hz"), (75, "75 Hz"), (100, "100 Hz"), (120, "120 Hz")], selection: s.highpass)
            }
            Toggle("Ronzio 50/60 Hz automatico", isOn: s.humAuto).toggleStyle(GlowToggleStyle()).font(.rounded(13))
            Toggle("Voice AutoEQ", isOn: s.autoEQ).toggleStyle(GlowToggleStyle()).font(.rounded(13))
            Toggle("De-esser (sibilanti)", isOn: s.deesser).toggleStyle(GlowToggleStyle()).font(.rounded(13))
            Toggle("De-plosive (P e B)", isOn: s.deplosive).toggleStyle(GlowToggleStyle()).font(.rounded(13))
        }
    }

    var loudnessCard: some View {
        AlgoCard(symbol: "gauge.with.dots.needle.67percent", title: "Loudness", subtitle: "EBU R128 con limitatore true peak, precisione 0,2 LU",
                 isOn: s.loudnessOn) {
            Row("Target") {
                ChipPicker(options: [(-23.0, "−23"), (-19.0, "−19"), (-18.0, "−18"), (-16.0, "−16"), (-14.0, "−14")],
                           selection: s.loudnessTarget)
            }
            Text(targetHint).font(.rounded(12)).foregroundStyle(Theme.text3)
            Row("True peak") {
                ChipPicker(options: [(-1.0, "−1 dB"), (-1.5, "−1,5"), (-2.0, "−2"), (-3.0, "−3")], selection: s.truePeak)
            }
        }
    }

    var targetHint: String {
        switch p.settings.loudnessTarget {
        case -23: "Radio e TV europee (EBU R128)"
        case -19: "Podcast mono, audiolibri"
        case -18: "Apple Podcasts"
        case -14: "YouTube, Spotify, piattaforme di streaming"
        default: "Podcast stereo, lo standard più diffuso"
        }
    }

    var cutCard: some View {
        AlgoCard(symbol: "scissors", title: "Taglio pause", subtitle: "Accorcia i silenzi lunghi, con dissolvenze invisibili",
                 isOn: s.cutSilence) {
            Row("Pause oltre") {
                GlowSlider(value: s.minSilence, range: 0.4...4, step: 0.1, label: { String(format: "%.1f s", $0) })
            }
            Row("Lascia") {
                GlowSlider(value: s.keepSilence, range: 0...1.5, step: 0.05, label: { String(format: "%.2f s", $0) })
            }
            Toggle("Taglia anche ehm, uhm, mh", isOn: s.cutFillers).toggleStyle(GlowToggleStyle()).font(.rounded(13))
        }
    }

    var speechCard: some View {
        AlgoCard(symbol: "captions.bubble", title: "Trascrizione", subtitle: "Riconoscimento vocale Apple sul Mac: testo e sottotitoli SRT, VTT",
                 isOn: s.transcribe) {
            Row("Lingua") {
                ChipPicker(options: [("it-IT", "Italiano"), ("en-US", "Inglese"), ("es-ES", "Spagnolo"), ("fr-FR", "Francese"), ("de-DE", "Tedesco")],
                           selection: s.language)
            }
        }
    }

    var outputsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                GlyphBadge(symbol: "square.and.arrow.down.on.square", size: 34)
                Text("File in uscita").font(.rounded(17, .bold))
                Spacer()
                Menu {
                    ForEach(ProductionSettings.Output.Format.allCases, id: \.self) { f in
                        Button(formatName(f)) { s.wrappedValue.outputs.append(.init(format: f)) }
                    }
                } label: { Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            ForEach(Array(p.settings.outputs.enumerated()), id: \.element.id) { i, o in
                HStack(spacing: 10) {
                    Text(o.ext.uppercased()).font(.rounded(11, .heavy)).foregroundStyle(.white)
                        .frame(width: 48).padding(.vertical, 5).background(Theme.accentDiagonal, in: RoundedRectangle(cornerRadius: 7))
                    Text(formatName(o.format)).font(.rounded(13, .medium))
                    Spacer()
                    if !o.isLossless {
                        Menu("\(o.bitrate) kbps") {
                            ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { b in
                                Button("\(b) kbps") { s.wrappedValue.outputs[i].bitrate = b }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.rounded(12))
                    }
                    Menu(o.channels == .keep ? "Originale" : (o.channels == .mono ? "Mono" : "Stereo")) {
                        Button("Canali originali") { s.wrappedValue.outputs[i].channels = .keep }
                        Button("Mono") { s.wrappedValue.outputs[i].channels = .mono }
                        Button("Stereo") { s.wrappedValue.outputs[i].channels = .stereo }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.rounded(12))
                    Button {
                        withAnimation { _ = s.wrappedValue.outputs.remove(at: i) }
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3) }
                        .buttonStyle(.plain)
                        .disabled(p.settings.outputs.count == 1)
                }
                .padding(10)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .glassCard()
    }

    var metadataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                GlyphBadge(symbol: "tag.fill", size: 34)
                Text("Metadati ed extra").font(.rounded(17, .bold))
            }
            GlassField(icon: "textformat", placeholder: "Titolo", text: s.title)
            GlassField(icon: "person.fill", placeholder: "Autore", text: s.artist)
            GlassField(icon: "square.stack.fill", placeholder: "Album o podcast", text: s.album)
            HStack(spacing: 8) {
                FilePill(label: "Intro", symbol: "arrow.right.to.line", url: file(\.intro), types: [.audio])
                FilePill(label: "Outro", symbol: "arrow.left.to.line", url: file(\.outro), types: [.audio])
                FilePill(label: "Copertina", symbol: "photo", url: file(\.cover), types: [.jpeg, .png])
            }
        }
        .glassCard()
    }

    func formatName(_ f: ProductionSettings.Output.Format) -> String {
        switch f {
        case .mp3: "MP3"
        case .aac: "AAC (M4A)"
        case .opus: "Opus"
        case .flac: "FLAC lossless"
        case .wav: "WAV 24 bit"
        case .video: "Video MP4"
        }
    }

    // MARK: action bar

    var actionBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pronto per l'elaborazione").font(.rounded(14, .semibold))
                Text(summary).font(.rounded(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer()
            Button(action: start) {
                Label("Elabora", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(GlowButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(.black.opacity(0.2)), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .padding(.horizontal, 34)
        .padding(.bottom, 22)
    }

    var summary: String {
        let st = p.settings
        var parts: [String] = []
        if st.denoiseOn { parts.append("rumore") }
        if st.levelerOn { parts.append("leveler") }
        if st.filterOn && st.autoEQ { parts.append("AutoEQ") }
        if st.loudnessOn { parts.append("\(Int(st.loudnessTarget)) LUFS") }
        if st.cutSilence { parts.append("tagli") }
        if st.transcribe { parts.append("trascrizione") }
        return parts.joined(separator: " · ") + " → " + st.outputs.map { $0.ext.uppercased() }.joined(separator: ", ")
    }
}

// MARK: - building blocks

struct InfoChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.rounded(12, .medium))
            .foregroundStyle(Theme.text2)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
    }
}

struct AlgoCard<Content: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                GlyphBadge(symbol: symbol, size: 38, active: isOn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.rounded(17, .bold))
                    Text(subtitle).font(.rounded(12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(GlowToggleStyle()).labelsHidden().frame(width: 46)
            }
            if isOn {
                VStack(alignment: .leading, spacing: 12) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .opacity(isOn ? 1 : 0.7)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isOn)
    }
}

struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.rounded(13)).foregroundStyle(Theme.text2).frame(width: 92, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

struct GlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let label: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 6)
                    Capsule().fill(Theme.accent).frame(width: max(6, geo.size.width * frac), height: 6)
                        .shadow(color: Theme.rose.opacity(0.6), radius: 6)
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: Theme.rose.opacity(0.7), radius: 8)
                        .offset(x: (geo.size.width - 18) * frac)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(1, max(0, g.location.x / geo.size.width))
                    let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    value = (raw / step).rounded() * step
                })
            }
            .frame(height: 22)
            Text(label(value)).font(.rounded(12, .semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }
}

struct GlassField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.text3).frame(width: 16)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.rounded(14))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

struct FilePill: View {
    let label: String
    let symbol: String
    @Binding var url: URL?
    let types: [UTType]

    var body: some View {
        Button {
            if url != nil { url = nil; return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = types
            if panel.runModal() == .OK { url = panel.url }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: url == nil ? symbol : "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(url == nil ? AnyShapeStyle(Theme.text2) : AnyShapeStyle(Theme.accent))
                Text(label).font(.rounded(12, .semibold))
                Text(url?.lastPathComponent ?? "aggiungi").font(.rounded(10)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.white.opacity(url == nil ? 0.04 : 0.09), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(url == nil ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(Theme.accent.opacity(0.6))))
        }
        .buttonStyle(.plain)
        .help(url == nil ? "Scegli un file" : "Clic per rimuovere")
    }
}
