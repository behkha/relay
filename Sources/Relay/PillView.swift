import SwiftUI

/// The strip on the right edge of the screen. Collapsed it is a sliver of status glyphs;
/// hovering opens the control column: inbox, agents, talk, screenshot and settings.
struct PillView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject private var look = Appearance.shared
    @ObservedObject private var heat = HeatMonitor.shared
    var onInbox: () -> Void
    var onAgents: () -> Void
    var onVoice: () -> Void
    var onScreenshotVoice: () -> Void
    var onHome: () -> Void
    var onMore: () -> Void

    private var isExpanded: Bool { ui.pillExpanded || ui.cardOpen || ui.panelOpen || ui.talking }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if isExpanded {
                expanded
                    .scaleEffect(look.pillScale, anchor: .trailing)
                    .padding(.trailing, 7)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.55, anchor: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)))
            } else {
                collapsed.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
    }

    private var sessions: [AgentSession] { Array(store.visibleSessions.prefix(10)) }

    /// Amber while the agent has a question waiting in the inbox, whatever its hook status says.
    private func shown(_ s: AgentSession) -> AgentStatus {
        store.items.contains { $0.sessionId == s.id && $0.isActionable } ? .waiting : s.shownStatus
    }

    // MARK: Collapsed

    private var collapsed: some View {
        VStack(spacing: 5) {
            if sessions.isEmpty {
                Circle().fill(Color.white.opacity(0.35)).frame(width: 4, height: 4)
            }
            ForEach(sessions) { s in
                StatusGlyph(status: shown(s), size: 5.5, heat: heat.heat[s.id]?.level ?? .none, pop: 1.9)
            }
        }
        .padding(.vertical, 7 + Self.flare)
        .frame(width: 10)
        .background(EdgeTab(radius: 5, flare: Self.flare).fill(Color(hex: "#080808")))
        .overlay(EdgeTab(radius: 5, flare: Self.flare).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    static let flare: CGFloat = 6

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 7) {
            // Inbox
            Button(action: onInbox) {
                Image(systemName: "tray")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .pillChrome(Circle(), active: ui.cardOpen)
                    .overlay(alignment: .topTrailing) { inboxBadge }
            }
            .buttonStyle(PressScale())
            .focusable(false)
            .hoverTip(store.waitingCount > 0 ? "\(store.waitingCount) waiting · ⌃⌥Space" : "Inbox · ⌃⌥Space")

            // Agents
            if !sessions.isEmpty {
                Button(action: onAgents) {
                    VStack(spacing: 7) {
                        ForEach(sessions) { s in
                            StatusGlyph(status: shown(s), size: 9, heat: heat.heat[s.id]?.level ?? .none, pop: 1.8)
                        }
                    }
                    .padding(.vertical, 10)
                    .frame(width: 32)
                    .pillChrome(Capsule(), active: ui.sidePanel == .agents)
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .focusable(false)
                .hoverTip(agentsSummary)
            }

            // Talk group
            VStack(spacing: 1) {
                GroupButton(help: "Workspaces", action: onHome) {
                    Mascot(style: .outline, size: 15, blinks: false)
                }
                GroupButton(help: ui.listening ? "Listening · ⌥⌥ sends" : "Talk · ⌥⌥", action: onVoice) {
                    if ui.listening {
                        ListeningBars(height: 13)
                    } else {
                        Image(systemName: "mic").font(.system(size: 13, weight: .medium))
                    }
                }
                GroupButton(help: "Talk with a screenshot", action: onScreenshotVoice) {
                    Image(systemName: "camera").font(.system(size: 12.5, weight: .medium))
                }
            }
            .padding(.vertical, 5)
            .frame(width: 32)
            .pillChrome(Capsule(), active: ui.talking)

            // More
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .pillChrome(Circle(), active: ui.panelOpen && ui.sidePanel == .settings)
            }
            .buttonStyle(PressScale())
            .focusable(false)
            .hoverTip("Settings")
        }
    }

    @ViewBuilder private var inboxBadge: some View {
        let items = store.visibleItems
        if items.contains(where: { $0.isActionable }) {
            Badge(color: Color(hex: "#FFD426"))
        } else if !items.isEmpty {
            Badge(color: Theme.green)
        }
    }

    private var agentsSummary: String {
        let waiting = sessions.filter { $0.shownStatus == .waiting || $0.shownStatus == .idle }.count
        let working = sessions.filter { $0.shownStatus == .working }.count
        var parts: [String] = []
        if let (id, h) = heat.hottest, let s = store.sessions[id] { parts.append("🔥 \(s.displayName) · \(h.cpuLabel)") }
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? "\(sessions.count) agents" : parts.joined(separator: " · ")
    }
}

/// The inbox's dot: it pops in when something lands.
private struct Badge: View {
    var color: Color
    @ViewState private var shown = false

    var body: some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1.2))
            .scaleEffect(shown ? 1 : 0.2)
            .offset(x: 2, y: -2)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { shown = true } }
    }
}

/// Buttons in the pill sink a little while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private struct GroupButton<Icon: View>: View {
    var help: String
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.9))
                .frame(width: 30, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .onHover { hover = $0 }
        .hoverTip(help)
    }
}

// Kept for the main window's agent rows.
struct StatusRing: View {
    var status: AgentStatus
    var workspaceColor: Color?

    var body: some View {
        ZStack {
            StatusGlyph(status: status, size: 11)
            if let workspaceColor {
                Circle().fill(workspaceColor).frame(width: 5, height: 5).offset(x: 7, y: 7)
            }
        }
        .frame(width: 18, height: 18)
    }
}
