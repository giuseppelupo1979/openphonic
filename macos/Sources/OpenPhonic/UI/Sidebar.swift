import SwiftUI

struct AppLogo: View {
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.accentDiagonal)
            .frame(width: size, height: size)
            .overlay(
                HStack(spacing: size * 0.06) {
                    ForEach([0.35, 0.7, 1.0, 0.55, 0.8, 0.4], id: \.self) { h in
                        Capsule().fill(.white).frame(width: size * 0.07, height: size * 0.6 * h)
                    }
                })
            .shadow(color: Theme.rose.opacity(0.55), radius: size * 0.3)
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppLogo()
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenPhonic").font(.rounded(19, .bold))
                    Text("Studio audio automatico").font(.rounded(11)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.top, 26)

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    model.selection = nil
                    model.showingHome = true
                }
            } label: {
                Label("Nuova produzione", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlowButtonStyle(big: false))

            HStack {
                Text("PRODUZIONI").font(.rounded(11, .bold)).foregroundStyle(Theme.text3).tracking(1.2)
                Spacer()
                if model.productions.contains(where: { $0.status == .setup }) {
                    Button("Elabora tutte") { model.startAll() }
                        .buttonStyle(.plain).font(.rounded(11, .semibold)).foregroundStyle(Theme.ember)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.productions) { p in
                        ProductionRow(p: p, selected: model.selection == p.id && !model.showingHome)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                                    model.selection = p.id
                                    model.showingHome = false
                                }
                            }
                            .contextMenu {
                                if let f = p.result?.files.first {
                                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                                }
                                Button("Mostra originale") { NSWorkspace.shared.activateFileViewerSelecting([p.source]) }
                                Divider()
                                Button("Rimuovi dall'elenco", role: .destructive) { model.remove(p.id) }
                            }
                    }
                }
            }
            .scrollIndicators(.never)
            .overlay {
                if model.productions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.badge.plus").font(.system(size: 28)).foregroundStyle(Theme.text3)
                        Text("Le tue produzioni\nappariranno qui").font(.rounded(12)).foregroundStyle(Theme.text3)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            EngineStatus()
        }
        .padding(18)
        .glassEffect(.regular.tint(.black.opacity(0.15)), in: .rect(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.07)))
    }
}

struct ProductionRow: View {
    let p: Production
    let selected: Bool
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            StatusGlyph(p: p).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.rounded(13, .semibold)).lineLimit(1)
                Text(subtitle).font(.rounded(11)).foregroundStyle(Theme.text2).lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.accent.opacity(0.22)) : AnyShapeStyle(.white.opacity(hover ? 0.06 : 0)))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }

    var subtitle: String {
        switch p.status {
        case .setup: return [p.info.map { formatDuration($0.duration) }, p.info?.hasVideo == true ? "video" : nil, "da elaborare"]
            .compactMap { $0 }.joined(separator: " · ")
        case .queued: return "In coda"
        case .processing: return "\(Int(p.progress * 100))% · \(p.step)"
        case .done:
            if let r = p.result { return String(format: "Pronta · %.0f LUFS · %@", r.after.integrated, formatDuration(r.after.duration)) }
            return "Pronta"
        case .failed: return "Errore"
        }
    }
}

struct StatusGlyph: View {
    let p: Production
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.07))
            switch p.status {
            case .processing, .queued:
                Circle().trim(from: 0, to: max(0.03, p.progress))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.rose.opacity(0.6), radius: 4)
                    .animation(.easeOut(duration: 0.4), value: p.progress)
                Image(systemName: "waveform").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, isActive: p.status == .processing)
            case .done:
                Circle().fill(Theme.accentDiagonal)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            case .setup:
                Image(systemName: p.info?.hasVideo == true ? "film" : "waveform")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
        }
    }
}

struct EngineStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = model.update {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Nuova versione \(r.version)", systemImage: "arrow.down.circle.fill")
                        .font(.rounded(13, .bold))
                        .foregroundStyle(.white)
                    if !r.notes.isEmpty {
                        Text(r.notes).font(.rounded(11)).foregroundStyle(Theme.text2).lineLimit(4)
                    }
                    Button { Task { await model.applyUpdate() } } label: {
                        Text("Aggiorna e riavvia").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlowButtonStyle(big: false))
                    .disabled(model.updateBusy)
                }
                .padding(14)
                .background(Theme.rose.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent, lineWidth: 1))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if !model.updateStatus.isEmpty {
                Text(model.updateStatus).font(.rounded(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Versione \(Updater.current)").font(.rounded(11)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Controlla aggiornamenti") {
                    model.updateStatus = "Controllo in corso…"
                    Task { await model.checkForUpdate(userAsked: true) }
                }
                .buttonStyle(.plain).font(.rounded(11, .semibold)).foregroundStyle(Theme.ember)
            }
            dot(model.ffmpegAvailable, "ffmpeg", model.ffmpegAvailable ? "pronto" : "manca: brew install ffmpeg")
            dot(model.deepFilterAvailable, "Riduzione rumore AI", model.deepFilterAvailable ? "DeepFilterNet" : "non trovata")
            Button {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Usa questa cartella"
                if panel.runModal() == .OK, let u = panel.url { model.outputFolder = u }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.ember)
                    Text(model.outputFolder.lastPathComponent).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3)
                }
                .font(.rounded(11, .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .help("Cartella dove vengono salvati i file elaborati: \(model.outputFolder.path)")
        }
    }

    func dot(_ ok: Bool, _ name: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Theme.mint : .yellow).frame(width: 7, height: 7)
                .shadow(color: (ok ? Theme.mint : .yellow).opacity(0.8), radius: 4)
            Text(name).font(.rounded(11, .semibold))
            Text(detail).font(.rounded(11)).foregroundStyle(Theme.text3).lineLimit(1)
        }
    }
}
