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
    /// Where the pill lives: the right or left edge of the screen, or around the notch.
    @Published var dock: PillDock {
        didSet { UserDefaults.standard.set(dock.rawValue, forKey: "pillDock") }
    }
    /// At the notch, the card and side panels are at least as wide as the island's button bar,
    /// so the two read as one piece. Set by the overlay from the screen's notch.
    @Published var notchPanelMinWidth: CGFloat = 0
    /// Labels that say what each of the pill's buttons does, on hover.
    @Published var showTooltips: Bool {
        didSet { UserDefaults.standard.set(showTooltips, forKey: "showTooltips") }
    }

    static let sounds = ["Tink", "Pop", "Glass", "Ping", "Purr", "Submarine", "Funk", "Bottle"]

    private init() {
        let d = UserDefaults.standard
        theme = ThemeChoice(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        pillScale = d.object(forKey: "pillScale") as? Double ?? 1
        textScale = d.object(forKey: "textScale") as? Double ?? 1
        soundName = d.string(forKey: "soundName") ?? "Tink"
        dock = PillDock(rawValue: d.string(forKey: "pillDock") ?? "") ?? .right
        showTooltips = d.object(forKey: "showTooltips") as? Bool ?? true
    }

    /// Width of a panel that hangs from the pill (card, agents list, settings menu).
    func panelWidth(_ base: CGFloat) -> CGFloat {
        dock == .notch ? max(base * textScale, notchPanelMinWidth) : base * textScale
    }

    /// How much darkening sits on top of the blurred glass.
    var tint: Double { theme == .black ? 0.8 : 0.55 }

    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * textScale, weight: weight, design: design)
    }
}

/// The panel behind the card, the agents list and the menus: solid near-black with a faint rim
/// (One's look). "Black" goes all the way to black.
struct Glass: View {
    var cornerRadius: CGFloat = 18
    @ObservedObject private var look = Appearance.shared
    @Environment(\.hangsFromPill) private var hangsFromPill

    var body: some View {
        if look.dock == .notch && hangsFromPill {
            // Hanging from the notch island: pure black with a flat top, so the two read as one piece.
            IslandBody(radius: cornerRadius + 4).fill(Color.black)
        } else {
            rounded
        }
    }

    private var rounded: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(look.theme == .black ? Color(hex: "#090909") : Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75)
            )
    }
}

extension View {
    /// The soft shadow under every floating panel, with room around it so the window never clips it.
    func floatingPanelShadow() -> some View {
        shadow(color: .black.opacity(0.32), radius: 14, y: 7)
            .padding(16)
            .padding(.bottom, 8)
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
            .foregroundStyle(onLight ? Color.black.opacity(0.5) : Color.white.opacity(0.6))
            .padding(.horizontal, key.count > 1 ? 5 : 0)
            .frame(minWidth: 17, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onLight ? Color.black.opacity(0.09) : Color.white.opacity(0.11)))
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

/// Spinner arc / dot used for agents in the pill and lists. Pops when the agent stops working.
struct StatusGlyph: View {
    var status: AgentStatus
    var size: CGFloat = 9
    var heat: HeatLevel = .none
    /// How far it swells when it changes (0 turns the pop off).
    var pop: CGFloat = 1.6

    var body: some View {
        GlyphFace(status: status, size: size, heat: heat)
            .id("\(status == .working)-\(heat == .hot)")   // fresh view (and animation) every time work starts again
            .popOnChange(of: status, strength: pop) { $0 != .working && pop > 0 }
    }
}

private struct GlyphFace: View {
    var status: AgentStatus
    var size: CGFloat
    var heat: HeatLevel
    @ViewState private var spin = false

    var body: some View {
        Group {
            if heat == .hot {
                // A flickering ember: the agent heating the Mac.
                TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let flicker = 0.85 + 0.15 * sin(t * 13) * sin(t * 7 + 1)
                    Circle()
                        .fill(RadialGradient(colors: [Fire.core, Fire.yellow, Fire.orange, Fire.red],
                                             center: UnitPoint(x: 0.5, y: 0.7), startRadius: 0, endRadius: size * 0.6))
                        .scaleEffect(flicker)
                        .shadow(color: Fire.orange.opacity(0.9), radius: size * 0.5 * flicker)
                }
            } else if status == .working {
                Circle()
                    .trim(from: 0, to: 0.66)
                    .stroke(Theme.blue, style: StrokeStyle(lineWidth: max(1.6, size * 0.24), lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Floating label shown beside a pill button while hovering it: toward the middle of the screen
/// (left of the button on the right edge, right of it on the left edge, below it at the notch).
struct HoverTip: ViewModifier {
    var text: String
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    private var alignment: Alignment {
        switch look.dock {
        case .right: return .trailing
        case .left: return .leading
        case .notch: return .bottom
        }
    }

    private var offset: CGSize {
        switch look.dock {
        case .right: return CGSize(width: -44 * look.pillScale, height: 0)
        case .left: return CGSize(width: 44 * look.pillScale, height: 0)
        case .notch: return CGSize(width: 0, height: 28)
        }
    }

    func body(content: Content) -> some View {
        content
            .pointerHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .overlay(alignment: alignment) {
                if hover && look.showTooltips {
                    Text(text)
                        .font(look.font(11, .medium))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                        .offset(offset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(hover ? 1 : 0)
    }
}

extension View {
    func hoverTip(_ text: String) -> some View { modifier(HoverTip(text: text)) }

    /// A soft white halo around a pill button while the pointer is on it.
    func hoverHalo<S: Shape>(_ shape: S) -> some View { modifier(HoverHalo(shape: shape)) }
}

/// The pill's hover state: a faint white wash over the button and a low glow around it.
struct HoverHalo<S: Shape>: ViewModifier {
    var shape: S
    @ViewState private var hover = false

    func body(content: Content) -> some View {
        content
            .background(
                shape.fill(Color.white.opacity(hover ? 0.2 : 0))
                    .blur(radius: 7)
                    .scaleEffect(hover ? 1.18 : 0.9)
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.fill(Color.white.opacity(hover ? 0.11 : 0))
                    .overlay(shape.stroke(Color.white.opacity(hover ? 0.18 : 0), lineWidth: 0.75))
                    .allowsHitTesting(false)
            )
            .pointerHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
    }
}
