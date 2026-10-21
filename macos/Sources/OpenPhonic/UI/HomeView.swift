import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("preset") private var presetID = "podcast"
    @Local private var targeted = false
    @Local private var appeared = false

    var preset: Preset { Preset.all.first { $0.id == presetID } ?? Preset.all[0] }

    var body: some View {
        ScrollView {
            VStack(spacing: 34) {
                VStack(spacing: 12) {
                    Text("Il tuo audio,\nsuono da studio.")
                        .font(.rounded(54, .heavy))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(LinearGradient(colors: [.white, .white, Theme.rose.opacity(0.9)],
                                                        startPoint: .top, endPoint: .bottom))
                        .shadow(color: Theme.rose.opacity(0.25), radius: 30)
                    Text("Rumore, livelli, timbro e loudness sistemati da soli. Tutto sul tuo Mac.")
                        .font(.rounded(16)).foregroundStyle(Theme.text2)
                }
                .padding(.top, 54)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)

                DropZone(targeted: targeted) { openFiles(model, preset: preset) }
                    .frame(height: 300)
                    .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                        load(providers)
                        return true
                    }
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.96)

                VStack(alignment: .leading, spacing: 14) {
                    Text("PRESET").font(.rounded(11, .bold)).foregroundStyle(Theme.text3).tracking(1.2)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                        ForEach(Preset.all) { p in
                            PresetCard(preset: p, selected: p.id == presetID)
                                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { presetID = p.id } }
                        }
                    }
                }
                .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.05)) { appeared = true } }
    }

    func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { model.add(urls, preset: preset) }
        }
    }
}

struct DropZone: View {
    let targeted: Bool
    let choose: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(.white.opacity(targeted ? 0.07 : 0.03))
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(targeted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.14)),
                              style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: targeted ? [] : [8, 7]))
            PulseRings(active: targeted)
            VStack(spacing: 18) {
                LiveBars(count: 9, height: 70, intense: targeted)
                Text(targeted ? "Rilascia per iniziare" : "Trascina qui audio o video")
                    .font(.rounded(24, .bold))
                    .contentTransition(.opacity)
                Text("MP3 · WAV · M4A · FLAC · MP4 · MOV · anche più file insieme")
                    .font(.rounded(13)).foregroundStyle(Theme.text2)
                Button("Scegli file…", action: choose).buttonStyle(GlowButtonStyle(big: false))
                    .padding(.top, 4)
            }
        }
        .glassEffect(.regular.tint(.white.opacity(0.01)), in: .rect(cornerRadius: 32))
        .shadow(color: targeted ? Theme.rose.opacity(0.4) : .clear, radius: 40)
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: targeted)
    }
}

/// Concentric rings expanding from the centre.
struct PulseRings: View {
    let active: Bool
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<4 {
                    let phase = (t * (active ? 0.5 : 0.22) + Double(i) / 4).truncatingRemainder(dividingBy: 1)
                    let r = 60 + phase * min(size.width, size.height * 2.2) * 0.55
                    let rect = CGRect(x: c.x - r, y: c.y - r * 0.55, width: r * 2, height: r * 1.1)
                    g.stroke(Ellipse().path(in: rect),
                             with: .linearGradient(Gradient(colors: [Theme.ember, Theme.rose, Theme.violet]),
                                                   startPoint: CGPoint(x: rect.minX, y: c.y), endPoint: CGPoint(x: rect.maxX, y: c.y)),
                             style: StrokeStyle(lineWidth: 1.4))
                }
            }
            .opacity(active ? 0.55 : 0.22)
            .mask(RoundedRectangle(cornerRadius: 32))
            .blur(radius: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Animated equalizer bars (decorative, also used while processing).
struct LiveBars: View {
    var count = 9
    var height: CGFloat = 60
    var intense = false
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: height * 0.09) {
                ForEach(0..<count, id: \.self) { i in
                    let v = 0.25 + 0.75 * abs(sin(t * (intense ? 4.2 : 1.8) + Double(i) * 0.7) * cos(t * 1.3 + Double(i) * 1.7))
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: height * 0.09, height: height * v)
                        .shadow(color: Theme.rose.opacity(0.6), radius: 6)
                }
            }
            .frame(height: height)
        }
    }
}

struct PresetCard: View {
    let preset: Preset
    let selected: Bool
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            GlyphBadge(symbol: preset.symbol, size: 42, active: selected)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name).font(.rounded(15, .bold))
                Text(preset.subtitle).font(.rounded(12)).foregroundStyle(Theme.text2).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(selected ? 0.10 : (hover ? 0.06 : 0.035))))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.08)), lineWidth: selected ? 1.5 : 1))
        .shadow(color: selected ? Theme.rose.opacity(0.3) : .clear, radius: 16)
        .scaleEffect(hover ? 1.02 : 1)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .contentShape(Rectangle())
    }
}
