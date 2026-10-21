import SwiftUI

enum Theme {
    static let ember = Color(red: 1.00, green: 0.42, blue: 0.24)     // #FF6B3D
    static let rose = Color(red: 1.00, green: 0.24, blue: 0.55)      // #FF3D8C
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.97)    // #8C5CF7
    static let cyan = Color(red: 0.27, green: 0.85, blue: 0.95)
    static let mint = Color(red: 0.30, green: 0.90, blue: 0.62)
    static let ink = Color(red: 0.035, green: 0.035, blue: 0.07)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.38)

    static let accent = LinearGradient(colors: [ember, rose, violet], startPoint: .leading, endPoint: .trailing)
    static let accentDiagonal = LinearGradient(colors: [ember, rose, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cool = LinearGradient(colors: [cyan, violet], startPoint: .leading, endPoint: .trailing)
}

/// Slowly drifting mesh gradient behind everything.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let s = { (k: Double, a: Double) in Float(0.5 + a * sin(t * k)) }
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [s(0.11, 0.25), 0], [1, 0],
                    [0, s(0.13, 0.2)], [s(0.07, 0.22), s(0.09, 0.22)], [1, s(0.1, 0.25)],
                    [0, 1], [s(0.08, 0.3), 1], [1, 1],
                ],
                colors: [
                    Theme.ink, Color(red: 0.16, green: 0.05, blue: 0.20), Theme.ink,
                    Color(red: 0.09, green: 0.05, blue: 0.20), Color(red: 0.30, green: 0.08, blue: 0.16), Color(red: 0.05, green: 0.06, blue: 0.16),
                    Theme.ink, Color(red: 0.24, green: 0.09, blue: 0.05), Theme.ink,
                ])
        }
        .overlay(Color.black.opacity(0.25))
        .ignoresSafeArea()
    }
}

struct GlassCard: ViewModifier {
    var radius: CGFloat = 22
    var padding: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    func glassCard(radius: CGFloat = 22, padding: CGFloat = 20) -> some View {
        modifier(GlassCard(radius: radius, padding: padding))
    }
}

/// Big gradient call-to-action with glow.
struct GlowButtonStyle: ButtonStyle {
    var big = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 17 : 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, big ? 30 : 18)
            .padding(.vertical, big ? 15 : 9)
            .background(Theme.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Theme.rose.opacity(configuration.isPressed ? 0.2 : 0.55), radius: big ? 22 : 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

/// Pill toggle with gradient fill.
struct GlowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.14)))
                    .frame(width: 42, height: 24)
                    .shadow(color: configuration.isOn ? Theme.rose.opacity(0.5) : .clear, radius: 8)
                Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// Segmented chips with a sliding gradient selection.
struct ChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                Text(label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(selection == value ? .white : Theme.text2)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background {
                        if selection == value {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "sel", in: ns)
                                .shadow(color: Theme.rose.opacity(0.4), radius: 6)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = value } }
            }
        }
        .padding(3)
        .background(.white.opacity(0.06), in: Capsule())
    }
}

/// Icon inside a glowing gradient squircle.
struct GlyphBadge: View {
    let symbol: String
    var size: CGFloat = 38
    var active = true
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(active ? AnyShapeStyle(Theme.accentDiagonal) : AnyShapeStyle(.white.opacity(0.08)))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: active ? Theme.rose.opacity(0.45) : .clear, radius: 10)
    }
}

extension Font {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

func formatDuration(_ t: Double) -> String {
    let s = Int(t.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// `@State` is a macro in this SDK whose plugin ships only with Xcode; the alias picks the
/// classic property wrapper, so the app builds with the Command Line Tools alone.
typealias Local = SwiftUICore.State
