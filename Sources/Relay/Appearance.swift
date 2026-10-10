import SwiftUI
import AppKit
import Combine
import NimbiKit

/// Look & sound preferences (theme, pill and text size, sounds), observable by every panel.
/// NimbiKit's components read the look from `NimbiAppearance`, which this keeps in step.
final class Appearance: ObservableObject {
    static let shared = Appearance()

    typealias ThemeChoice = NimbiTheme

    @Published var theme: ThemeChoice {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme"); bridge() }
    }
    /// 0.8 … 1.3
    @Published var pillScale: Double {
        didSet { UserDefaults.standard.set(pillScale, forKey: "pillScale"); bridge() }
    }
    /// 0.9 … 1.25
    @Published var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale"); bridge() }
    }
    @Published var soundName: String {
        didSet { UserDefaults.standard.set(soundName, forKey: "soundName") }
    }
    /// Where the pill lives: the right or left edge of the screen, or around the notch.
    @Published var dock: PillDock {
        didSet { UserDefaults.standard.set(dock.rawValue, forKey: "pillDock"); bridge() }
    }
    /// At the notch, the card and side panels are at least as wide as the island's button bar,
    /// so the two read as one piece. Set by the overlay from the screen's notch.
    @Published var notchPanelMinWidth: CGFloat = 0
    /// Labels that say what each of the pill's buttons does, on hover.
    @Published var showTooltips: Bool {
        didSet { UserDefaults.standard.set(showTooltips, forKey: "showTooltips"); bridge() }
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
        bridge()
    }

    /// Hands the look to NimbiKit, so its components match the rest of Relay.
    private func bridge() {
        let kit = NimbiAppearance.shared
        if kit.theme != theme { kit.theme = theme }
        if kit.textScale != textScale { kit.textScale = textScale }
        if kit.pillScale != pillScale { kit.pillScale = pillScale }
        if kit.dock != dock { kit.dock = dock }
        if kit.showTooltips != showTooltips { kit.showTooltips = showTooltips }
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

/// The panel behind the card, the agents list and the menus (NimbiKit's `PanelBackground`).
typealias Glass = PanelBackground

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

extension StatusGlyph where Value == AgentStatus {
    /// Spinner arc / dot used for agents in the pill and lists. Pops when the agent stops working.
    init(status: AgentStatus, size: CGFloat = 9, heat: HeatLevel = .none, pop: CGFloat = 1.6) {
        self.init(status, working: status == .working, color: status.color, hot: heat == .hot, size: size, pop: pop)
    }
}
