import SwiftUI
import AppKit
import Combine

/// Look & sound preferences (theme, pill and text size, sounds), observable by every panel.
final class Appearance: ObservableObject {
    static let shared = Appearance()

    enum ThemeChoice: String, CaseIterable, Identifiable {
        case dark = "Dark", black = "Black"
        var id: String { rawValue }
    }

    @Published var theme: ThemeChoice {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    /// 0.8 … 1.3
    @Published var pillScale: Double {
        didSet { UserDefaults.standard.set(pillScale, forKey: "pillScale") }
    }
    /// 0.9 … 1.25
    @Published var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }
    @Published var soundName: String {
        didSet { UserDefaults.standard.set(soundName, forKey: "soundName") }
    }

    static let sounds = ["Tink", "Pop", "Glass", "Ping", "Purr", "Submarine", "Funk", "Bottle"]

    private init() {
        let d = UserDefaults.standard
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        pillScale = d.object(forKey: "pillScale") as? Double ?? 1
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        soundName = d.string(forKey: "soundName") ?? "Tink"
    }

    /// How much darkening sits on top of the blurred glass.
    var tint: Double { theme == .black ? 0.8 : 0.55 }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * textScale, weight: weight, design: design)
    }
}

/// Blurred, translucent panel background (the "glass" behind every Relay panel).
struct Glass: View {
    var cornerRadius: CGFloat = 18
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow)
            Color.black.opacity(look.tint)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 0.75)
        )
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Small rounded key hint like the ones One shows next to its buttons ("esc", "J", "E").
struct KeyHint: View {
    var key: String
    /// Drawn on a light button (dark text and chip).
    var onLight = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Text(key)
            .font(look.font(9.5, .semibold))
            .foregroundStyle(onLight ? Color.black.opacity(0.5) : Color.white.opacity(0.55))
            .padding(.horizontal, key.count > 1 ? 5 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4.5).fill(onLight ? Color.black.opacity(0.1) : Color.white.opacity(0.1)))
    }
}

/// The Claude mark used for agents (an asterisk-like spark in Claude orange) with a status dot.
struct AgentMark: View {
    var status: AgentStatus
    var size: CGFloat = 18

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "staroflife.fill")
                .font(.system(size: size * 0.78, weight: .bold))
                .foregroundStyle(Color(hex: "#D97757"))
                .frame(width: size, height: size)
            Circle().fill(status.color)
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.2))
                .offset(x: 2, y: 2)
        }
    }
}

/// Spinner arc / dot used for agents in the pill and lists.
struct StatusGlyph: View {
    var status: AgentStatus
    var size: CGFloat = 9
    @ViewState private var spin = false

    var body: some View {
        Group {
            if status == .working {
                Circle()
                    .trim(from: 0, to: 0.62)
                    .stroke(Theme.blue, style: StrokeStyle(lineWidth: max(1.6, size * 0.2), lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: size, height: size)
        .id(status == .working)   // fresh view (and animation) every time work starts again
    }
}

/// Floating label shown to the left of a pill button while hovering it.
struct HoverTip: ViewModifier {
    var text: String
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    func body(content: Content) -> some View {
        content
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .overlay(alignment: .trailing) {
                if hover {
                    Text(text)
                        .font(look.font(11, .medium))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .offset(x: -44)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }
}
