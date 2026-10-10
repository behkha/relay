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
    @ObservedObject var notch: NotchGeometry

    @Namespace private var glass
    /// The column is on screen (rather than the sliver).
    @ViewState private var columnShown = false
    /// The column's pieces have pulled apart; before that they sit as one piece of glass.
    @ViewState private var split = false
    @ViewState private var nextStep: DispatchWorkItem?

    private var isExpanded: Bool { ui.pillExpanded || ui.cardOpen || ui.panelOpen || ui.talking }

    /// With Liquid Glass, opening grows the sliver into one piece of glass that then divides
    /// into the column's sections, and closing runs that backwards. Without it the column
    /// scales out of the edge.
    private var morphs: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        if look.dock == .notch {
            NotchIsland(store: store, ui: ui, geo: notch,
                        onInbox: onInbox, onAgents: onAgents, onVoice: onVoice,
                        onScreenshotVoice: onScreenshotVoice, onHome: onHome, onMore: onMore)
        } else {
            edgePill
        }
    }

    /// On the left edge everything is mirrored: the column hugs the left and grows rightward.
    private var onLeft: Bool { look.dock == .left }
    private var edge: UnitPoint { onLeft ? .leading : .trailing }

    private var edgePill: some View {
        Group {
            if columnShown {
                // Sized by layout rather than scaled: Liquid Glass draws at a view's laid-out size,
                // so a scaleEffect leaves the glass behind its scaled contents.
                expanded
                    .padding(onLeft ? .leading : .trailing, 7 * k)
                    .transition(morphs
                        ? .asymmetric(insertion: .identity,
                                      removal: .scale(scale: 0.3, anchor: edge).combined(with: .opacity))
                        : .asymmetric(
                        insertion: .scale(scale: 0.55, anchor: edge).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: edge).combined(with: .opacity)))
            } else {
                collapsed
                    .transition(morphs ? .identity : .opacity)
            }
        }
        .glassGroup(spacing: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: onLeft ? .leading : .trailing)
        .onAppear { columnShown = isExpanded; split = isExpanded }
        .onChange(of: isExpanded) { open in morph(open) }
    }

    private func morph(_ open: Bool) {
        nextStep?.cancel()
        guard morphs else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { columnShown = open; split = open }
            return
        }
        // Each step waits for the one before it to mostly land.
        func then(_ delay: Double, _ step: @escaping () -> Void) {
            let work = DispatchWorkItem(block: step)
            nextStep = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        if open {
            // The sliver swells into one piece of glass, which then divides into sections.
            let wasShown = columnShown
            withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { columnShown = true }
            then(wasShown ? 0 : 0.16) {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.66)) { split = true }
            }
        } else {
            // The sections flow back into one piece, which shrinks into the sliver.
            let wasSplit = split
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { split = false }
            then(wasSplit ? 0.22 : 0) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { columnShown = false }
            }
        }
    }

    private var sessions: [AgentSession] { Array(store.visibleSessions.prefix(10)) }

    /// The pill size setting; every measurement below is multiplied by it.
    private var k: CGFloat { CGFloat(look.pillScale) }

    /// Amber while the agent has a question waiting in the inbox, whatever its hook status says.
    private func shown(_ s: AgentSession) -> AgentStatus {
        store.items.contains { $0.sessionId == s.id && $0.isActionable } ? .waiting : s.shownStatus
    }

    // MARK: Collapsed

    private var collapsed: some View {
        VStack(spacing: 5 * k) {
            if sessions.isEmpty {
                Circle().fill(Color.white.opacity(0.35)).frame(width: 4 * k, height: 4 * k)
            }
            ForEach(sessions) { s in
                StatusGlyph(status: shown(s), size: 5.5 * k, heat: heat.heat[s.id]?.level ?? .none, pop: 1.9)
            }
        }
        .padding(.vertical, (7 + Self.flare) * k)
        .frame(width: 10 * k)
        .modifier(CollapsedChrome(shape: EdgeTab(radius: 5 * k, flare: Self.flare * k, mirrored: onLeft), id: "column", namespace: glass))
    }

    static let flare: CGFloat = 6

    // MARK: Expanded

    /// The column's sections, top to bottom, with their heights (OverlayController.talkAnchor
    /// mirrors these numbers).
    private enum Section: CaseIterable { case inbox, agents, talk, more }
    private static let gap: CGFloat = 7

    private func height(_ section: Section) -> CGFloat {
        switch section {
        case .inbox, .more: return 32 * k
        case .agents:
            let n = CGFloat(sessions.count)
            return n == 0 ? 0 : (n * 9 + (n - 1) * 7 + 20) * k
        case .talk: return 91 * k
        }
    }

    /// Before the column divides, every section sits at its middle, so together they read as a
    /// single piece of glass; dividing slides each one out to its place.
    private func gathered(_ section: Section) -> CGFloat {
        guard !split else { return 0 }
        let present = Section.allCases.filter { height($0) > 0 }
        let total = present.map(height).reduce(0, +) + Self.gap * k * CGFloat(present.count - 1)
        var top: CGFloat = 0
        for s in present {
            if s == section { return total / 2 - (top + height(s) / 2) }
            top += height(s) + Self.gap * k
        }
        return 0
    }

    /// The glyphs inside a section appear as it divides off, and fade as it flows back.
    private func emerging<V: View>(_ v: V) -> some View {
        v.opacity(split ? 1 : 0)
            .scaleEffect(split ? 1 : 0.6)
            .blur(radius: split ? 0 : 2)
    }

    /// The first section takes over the sliver's glass; the others are pulled out of it.
    private func glassID(_ section: Section) -> String {
        let first: Section = sessions.isEmpty ? .inbox : .agents
        return section == first ? "column" : "\(section)"
    }

    /// Gathered, only the piece that took over the sliver carries the dark smoke.
    private func smokes(_ section: Section) -> Bool { split || glassID(section) == "column" }

    private var expanded: some View {
        VStack(spacing: Self.gap * k) {
            // Inbox
            Button(action: onInbox) {
                emerging(Image(systemName: "tray")
                    .font(.system(size: 13 * k, weight: .medium))
                    .foregroundStyle(.white))
                    .frame(width: 32 * k, height: 32 * k)
                    .pillChrome(Circle(), active: ui.cardOpen, id: glassID(.inbox), in: glass, smoke: smokes(.inbox))
                    .hoverHalo(Circle())
                    .overlay(alignment: onLeft ? .topLeading : .topTrailing) { inboxBadge.opacity(split ? 1 : 0) }
            }
            .buttonStyle(PressScale())
            .focusable(false)
            .hoverTip(Self.inboxTip(waiting: store.waitingCount))
            .offset(y: gathered(.inbox))

            // Agents
            if !sessions.isEmpty {
                Button(action: onAgents) {
                    emerging(VStack(spacing: 7 * k) {
                        ForEach(sessions) { s in
                            StatusGlyph(status: shown(s), size: 9 * k, heat: heat.heat[s.id]?.level ?? .none, pop: 1.8)
                        }
                    })
                    .padding(.vertical, 10 * k)
                    .frame(width: 32 * k)
                    .pillChrome(Capsule(), active: ui.sidePanel == .agents, id: glassID(.agents), in: glass, smoke: smokes(.agents))
                    .hoverHalo(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .focusable(false)
                .hoverTip(agentsSummary)
                .offset(y: gathered(.agents))
            }

            // Talk group
            emerging(VStack(spacing: 1 * k) {
                GroupButton(help: "Workspaces & settings", scale: k, action: onHome) {
                    Mascot(size: 20 * k)
                }
                GroupButton(help: ui.listening ? "Listening · ⌥⌥ sends" : "Talk to an agent · ⌥⌥", scale: k, action: onVoice) {
                    if ui.listening {
                        ListeningBars(height: 13 * k)
                    } else {
                        Image(systemName: "mic").font(.system(size: 13 * k, weight: .medium))
                    }
                }
                GroupButton(help: "Talk with a screenshot", scale: k, action: onScreenshotVoice) {
                    Image(systemName: "camera").font(.system(size: 12.5 * k, weight: .medium))
                }
            })
            .padding(.vertical, 5 * k)
            .frame(width: 32 * k)
            .pillChrome(Capsule(), active: ui.talking, id: glassID(.talk), in: glass, smoke: smokes(.talk))
            .offset(y: gathered(.talk))

            // More
            Button(action: onMore) {
                emerging(Image(systemName: "ellipsis")
                    .font(.system(size: 11 * k, weight: .bold))
                    .foregroundStyle(.white))
                    .frame(width: 32 * k, height: 32 * k)
                    .pillChrome(Circle(), active: ui.panelOpen && ui.sidePanel == .settings, id: glassID(.more), in: glass, smoke: smokes(.more))
                    .hoverHalo(Circle())
            }
            .buttonStyle(PressScale())
            .focusable(false)
            .hoverTip("Settings")
            .offset(y: gathered(.more))
        }
        // Gathered, the sections overlap; let the clicks wait until they have divided.
        .allowsHitTesting(split)
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
        var hot: String?
        if let (id, h) = heat.hottest, let s = store.sessions[id] { hot = "🔥 \(s.displayName) · \(h.cpuLabel)" }
        return Self.agentsTip(hot: hot, working: working, waiting: waiting, running: sessions.count)
    }

    // The hover labels beside the buttons. The window leaves room for them (HoverTip.maxTextWidth).

    static func inboxTip(waiting: Int) -> String {
        waiting > 0 ? "Inbox · \(waiting) waiting · ⌃⌥Space" : "Inbox · ⌃⌥Space"
    }

    static func agentsTip(hot: String?, working: Int, waiting: Int, running: Int) -> String {
        var parts: [String] = []
        if let hot { parts.append(hot) }
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return "Agents · " + (parts.isEmpty ? "\(running) running" : parts.joined(separator: " · "))
    }
}

/// The collapsed sliver: glass that shares its id with a piece of the open column, so opening
/// the pill pulls the column out of it. Darker than the column, since it is only a few points wide.
private struct CollapsedChrome<S: Shape>: ViewModifier {
    var shape: S
    var id: String
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(shape.fill(Color.black.opacity(0.62)))
                .glassEffect(.regular, in: shape)
                .glassEffectID(id, in: namespace)
        } else {
            content
                .background(shape.fill(Color(hex: "#080808")))
                .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        }
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
    var scale: CGFloat = 1
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.9))
                .frame(width: 30 * scale, height: 27 * scale)
                .hoverHalo(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .pointerHover { hover = $0 }
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
