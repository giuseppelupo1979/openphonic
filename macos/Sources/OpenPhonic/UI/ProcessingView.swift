import SwiftUI

struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    static let stages: [(Double, String, String)] = [
        (0.10, "waveform.badge.magnifyingglass", "Analisi"),
        (0.20, "line.3.horizontal.decrease", "Filtri"),
        (0.32, "sparkles", "Riduzione rumore AI"),
        (0.44, "dial.medium", "Voice AutoEQ"),
        (0.66, "slider.vertical.3", "Adaptive Leveler"),
        (0.80, "scissors", "Tagli e trascrizione"),
        (0.85, "gauge.with.dots.needle.67percent", "Loudness"),
        (0.95, "square.and.arrow.down", "Esportazione"),
        (1.00, "checkmark.seal", "Misure finali"),
    ]

    var body: some View {
        let p = model.productions.first { $0.id == id }
        let progress = p?.progress ?? 0
        VStack(spacing: 36) {
            Spacer()
            ZStack {
                ProgressHalo(progress: progress)
                    .frame(width: 280, height: 280)
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(progress * 100))")
                            .font(.rounded(76, .heavy))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: progress))
                            .animation(.spring(response: 0.4), value: Int(progress * 100))
                        Text("%").font(.rounded(30, .bold)).foregroundStyle(Theme.text2)
                    }
                    Text(p?.step ?? "").font(.rounded(14, .medium)).foregroundStyle(Theme.text2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: p?.step)
                }
            }
            VStack(spacing: 6) {
                Text(p?.name ?? "").font(.rounded(24, .bold))
                Text(p?.status == .queued ? "In coda: parte appena finisce la produzione in corso" : "Elaborazione in corso sul tuo Mac")
                    .font(.rounded(13)).foregroundStyle(Theme.text3)
            }
            HStack(spacing: 10) {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, st in
                    let done = progress >= st.0
                    let active = !done && (i == 0 || progress >= Self.stages[i - 1].0)
                    VStack(spacing: 7) {
                        ZStack {
                            Circle().fill(done ? AnyShapeStyle(Theme.accentDiagonal) : AnyShapeStyle(.white.opacity(active ? 0.14 : 0.06)))
                                .frame(width: 40, height: 40)
                                .shadow(color: done ? Theme.rose.opacity(0.5) : .clear, radius: 8)
                            Image(systemName: done ? "checkmark" : st.1)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(done || active ? .white : Theme.text3)
                                .symbolEffect(.pulse, isActive: active)
                        }
                        Text(st.2).font(.rounded(10, .semibold)).foregroundStyle(done || active ? .white : Theme.text3)
                            .multilineTextAlignment(.center).frame(width: 78)
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: done)
                }
            }
            .glassCard(radius: 26, padding: 18)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Glowing progress ring with an orbiting spark and a breathing inner glow.
struct ProgressHalo: View {
    let progress: Double

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(RadialGradient(colors: [Theme.rose.opacity(0.28 + 0.08 * sin(t * 2)), .clear],
                                             center: .center, startRadius: 10, endRadius: 170))
                    .scaleEffect(1.25)
                Circle().stroke(.white.opacity(0.07), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: max(0.005, progress))
                    .stroke(AngularGradient(colors: [Theme.ember, Theme.rose, Theme.violet, Theme.ember], center: .center),
                            style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Theme.rose.opacity(0.8), radius: 16)
                    .animation(.easeOut(duration: 0.6), value: progress)
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(LinearGradient(colors: [.clear, .white.opacity(0.7)], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(t * 120))
                    .padding(-18)
                LiveBars(count: 15, height: 26, intense: true).opacity(0.35).offset(y: 92)
            }
        }
    }
}
