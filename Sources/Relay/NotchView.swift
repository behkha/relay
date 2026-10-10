import SwiftUI

/// The pill when it lives at the notch: a black island that grows out of the camera housing.
///
/// - Collapsed, it hugs the notch: the mascot on its left, a dot per agent on its right.
/// - Hovered, it drops open into a dashboard: the pill's buttons along the top, either side
///   of the notch, then the mascot with what your agents are doing, and a chip per agent.
/// - With the card, a side panel or the talk bar open, it is just the button bar, and the
///   panel hangs from it as one piece.
///
/// Changing state is two steps, like a real dynamic island: the black shape springs to its
/// new size first (overshooting a little as it opens), and the new content blurs in once
/// there is room for it; going back, the content clears out before the shape pulls in.
struct NotchIsland: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject var geo: NotchGeometry
    @ObservedObject private var look = Appearance.shared
    @ObservedObject private var heat = HeatMonitor.shared
    var onInbox: () -> Void
    var onAgents: () -> Void
    var onVoice: () -> Void
    var onScreenshotVoice: () -> Void
    var onHome: () -> Void
    var onMore: () -> Void

    enum Mode: Equatable { case collapsed, dashboard, attached }

    /// What the state asks for.
    private var mode: Mode {
        if ui.cardOpen || ui.panelOpen || ui.talking { return .attached }
        return ui.pillExpanded ? .dashboard : .collapsed
    }

    /// The size the black shape is at (or springing toward).
    @ViewState private var shape: Mode = .collapsed
    /// The content on show; it follows `shape` a beat behind when opening, ahead when closing.
    @ViewState private var shown: Mode = .collapsed
    @ViewState private var nextStep: DispatchWorkItem?

    static let opening = Animation.spring(response: 0.5, dampingFraction: 0.7)
    static let closing = Animation.spring(response: 0.38, dampingFraction: 0.9)
    static let resizing = Animation.spring(response: 0.42, dampingFraction: 0.8)

    private var s: CGFloat { geo.scale }
    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { look.font(size * s, weight) }

    private var size: CGSize { geo.size(shape, textScale: look.textScale) }

    private var bottomRadius: CGFloat {
        switch shape {
        case .collapsed: return geo.collapsedHeight * 0.42
        case .dashboard: return 24 * s
        case .attached:
            // Square where a panel of the same width continues below; rounded over the talk bar.
            return geo.attachedWidth > 0 && geo.attachedWidth >= geo.barWidth - 0.5 ? 0 : geo.barHeight * 0.42
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            IslandShape(bottomRadius: bottomRadius)
                .fill(Color.black)
                .frame(width: size.width + 2 * NotchGeometry.ear, height: size.height)
                .shadow(color: .black.opacity(shape == .dashboard ? 0.45 : 0), radius: 14, y: 6)
            content
                .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Self.resizing, value: geo.attachedWidth)
        .animation(Self.resizing, value: geo.scale)
        .overlayPreferenceValue(IslandTipKey.self) { tips in
            IslandTipLayer(tip: look.showTooltips ? tips.last : nil)
        }
        .preferredColorScheme(.dark)
        .onAppear { shape = mode; shown = mode }
        .onChange(of: mode) { morph(to: $0) }
    }

    // MARK: Morph

    private static func depth(_ m: Mode) -> Int {
        switch m {
        case .collapsed: return 0
        case .attached: return 1
        case .dashboard: return 2
        }
    }

    private func morph(to target: Mode) {
        nextStep?.cancel()
        func then(_ delay: Double, _ step: @escaping () -> Void) {
            let work = DispatchWorkItem(block: step)
            nextStep = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        if Self.depth(target) >= Self.depth(shape) {
            // Opening: the shape springs open (the collapsed wings leave with it), then the new
            // content arrives once there's room for it.
            withAnimation(Self.opening) { shape = target }
            then(0.09) { withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { shown = target } }
        } else {
            // Closing: the content clears out first, then the shape pulls back in.
            withAnimation(.easeOut(duration: 0.13)) { shown = target }
            then(0.06) { withAnimation(Self.closing) { shape = target } }
        }
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .top) {
            if shown == .collapsed && shape == .collapsed {
                wings.transition(.islandContent)
            }
            if shown != .collapsed && shape != .collapsed {
                bar.transition(.islandContent)
            }
            if shown == .dashboard && shape == .dashboard {
                dashboard
                    .padding(.top, geo.barHeight)
                    .transition(.islandContent)
            }
        }
    }

    private var sessions: [AgentSession] { Array(store.visibleSessions.prefix(10)) }

    /// Amber while the agent has a question waiting in the inbox, whatever its hook status says.
    private func shown(_ s: AgentSession) -> AgentStatus {
        store.items.contains { $0.sessionId == s.id && $0.isActionable } ? .waiting : s.shownStatus
    }

    private func waiting(_ s: AgentSession) -> Int {
        store.items.filter { $0.sessionId == s.id && $0.isActionable }.count
    }

    // MARK: Collapsed

    private var wings: some View {
        HStack(spacing: 0) {
            Mascot(size: min(geo.collapsedHeight - 12, 22 * s))
                .frame(width: geo.wing, height: geo.collapsedHeight)
            Spacer(minLength: 0)
            dots
                .frame(width: geo.wing, height: geo.collapsedHeight)
        }
    }

    /// A dot per agent: two by two like the island in the reference, four abreast once there are more.
    private var dots: some View {
        let list = Array(sessions.prefix(8))
        let perRow = list.count <= 4 ? 2 : 4
        let glyph: CGFloat = (list.count <= 4 ? 7 : 5.5) * s
        let rows = stride(from: 0, to: list.count, by: perRow).map { Array(list[$0..<min($0 + perRow, list.count)]) }
        return Group {
            if list.isEmpty {
                Circle().fill(Color.white.opacity(0.35)).frame(width: 4 * s, height: 4 * s)
            } else {
                VStack(spacing: 3.5 * s) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 3.5 * s) {
                            ForEach(row) { session in
                                StatusGlyph(status: shown(session), size: glyph, heat: heat.heat[session.id]?.level ?? .none, pop: 1.9)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Button bar

    /// The pill's buttons, either side of the notch.
    private var bar: some View {
        HStack(spacing: 3 * s) {
            if shown == .attached {
                // The dashboard's big mascot is the way home; with a panel open, this one is.
                IslandButton(size: geo.buttonSize, tip: "Workspaces · accounts and settings", action: onHome) {
                    Mascot(size: geo.buttonSize - 9 * s)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            IslandButton(size: geo.buttonSize, active: ui.cardOpen,
                         tip: store.waitingCount > 0 ? "Inbox · \(store.waitingCount) waiting · ⌃⌥Space" : "Inbox · ⌃⌥Space",
                         action: onInbox) {
                Image(systemName: "tray").font(.system(size: 12.5 * s, weight: .medium))
            }
            .overlay(alignment: .topTrailing) { inboxBadge }
            agentsButton
            Spacer(minLength: geo.notchWidth + 16)
            IslandButton(size: geo.buttonSize, active: ui.talking,
                         tip: ui.listening ? "Listening · ⌥⌥ sends" : "Talk to an agent · ⌥⌥", action: onVoice) {
                if ui.listening {
                    ListeningBars(height: 12 * s)
                } else {
                    Image(systemName: "mic").font(.system(size: 12.5 * s, weight: .medium))
                }
            }
            IslandButton(size: geo.buttonSize, tip: "Talk with a screenshot", action: onScreenshotVoice) {
                Image(systemName: "camera").font(.system(size: 12 * s, weight: .medium))
            }
            IslandButton(size: geo.buttonSize, active: ui.panelOpen && ui.sidePanel == .settings,
                         tip: "Settings", action: onMore) {
                Image(systemName: "ellipsis").font(.system(size: 11 * s, weight: .bold))
            }
        }
        .padding(.horizontal, 12 * s)
        .frame(height: geo.barHeight)
    }

    /// The agents' dots in a capsule; opens the agents list.
    private var agentsButton: some View {
        Button(action: onAgents) {
            HStack(spacing: 3.5 * s) {
                if sessions.isEmpty {
                    Image(systemName: "square.grid.2x2").font(.system(size: 11.5 * s, weight: .medium))
                } else {
                    ForEach(Array(sessions.prefix(3))) { session in
                        StatusGlyph(status: shown(session), size: 6.5 * s, heat: heat.heat[session.id]?.level ?? .none, pop: 1.8)
                    }
                    if sessions.count > 3 {
                        Text("+\(sessions.count - 3)").font(.system(size: 9.5 * s, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textDim)
                            .fixedSize()
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, sessions.isEmpty ? 0 : 7 * s)
            .frame(minWidth: geo.buttonSize, maxWidth: geo.agentsCapsuleWidth, minHeight: geo.buttonSize)
            .background(Capsule().fill(Color.white.opacity(ui.sidePanel == .agents ? 0.16 : 0.07)))
            .hoverHalo(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .islandTip(agentsSummary)
    }

    @ViewBuilder private var inboxBadge: some View {
        let items = store.visibleItems
        if items.contains(where: { $0.isActionable }) {
            Circle().fill(Color(hex: "#FFD426")).frame(width: 7 * s, height: 7 * s)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
        } else if !items.isEmpty {
            Circle().fill(Theme.green).frame(width: 7 * s, height: 7 * s)
                .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
        }
    }

    private var agentsSummary: String {
        let waiting = sessions.filter { $0.shownStatus == .waiting || $0.shownStatus == .idle }.count
        let working = sessions.filter { $0.shownStatus == .working }.count
        var parts: [String] = []
        if let (id, h) = heat.hottest, let s = store.sessions[id] { parts.append("🔥 \(s.displayName) · \(h.cpuLabel)") }
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if sessions.isEmpty { return "Agents · none running" }
        return "Agents · " + (parts.isEmpty ? "\(sessions.count) running" : parts.joined(separator: " · "))
    }

    // MARK: Dashboard

    private var dashboard: some View {
        HStack(spacing: 10 * s) {
            mascotCard
            if !sessions.isEmpty { agentsCard }
        }
        .padding(.horizontal, 12 * s)
        .padding(.top, 4 * s)
        .frame(height: geo.dashboardContentHeight(look.textScale))
    }

    /// The mascot, big, beside what your agents are up to (who needs you first).
    private var mascotCard: some View {
        HStack(spacing: 14 * s) {
            Button(action: onHome) {
                Mascot(size: 56 * look.textScale * s)
                    .frame(width: 84 * look.textScale * s, height: 84 * look.textScale * s)
                    .hoverHalo(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .focusable(false)
            .islandTip("Workspaces · accounts and settings")

            VStack(alignment: .leading, spacing: 6 * s) {
                if activity.isEmpty {
                    Text("No agents running").font(font(14, .medium)).foregroundStyle(.white)
                    Text("Start Claude Code in any terminal or the Claude app.")
                        .font(font(11.5)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(activity.enumerated()), id: \.element.session.id) { i, line in
                        ActivityLine(session: line.session, waiting: line.waiting, status: shown(line.session),
                                     leading: i == 0, scale: s) { open(line.session) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20 * s, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var activity: [(session: AgentSession, waiting: Int)] {
        func rank(_ s: AgentSession, _ w: Int) -> Int {
            if w > 0 { return 0 }
            switch s.shownStatus {
            case .waiting, .idle: return 1
            case .working: return 2
            case .done: return 3
            default: return 4
            }
        }
        return store.visibleSessions
            .map { ($0, waiting($0)) }
            .sorted { (rank($0.0, $0.1), $1.0.updatedAt) < (rank($1.0, $1.1), $0.0.updatedAt) }
            .prefix(3)
            .map { (session: $0.0, waiting: $0.1) }
    }

    /// A question waiting: open the card on it. Otherwise: open the conversation.
    private func open(_ s: AgentSession) {
        if let item = store.visibleItems.first(where: { $0.sessionId == s.id && $0.isActionable }) {
            NotificationCenter.default.post(name: .relayOpenItem, object: item.id)
        } else {
            NotificationCenter.default.post(name: .relayViewSession, object: s.id)
        }
    }

    /// A chip per agent, tinted by its status; the last one opens the full list when there are more.
    private var agentsCard: some View {
        let all = store.visibleSessions
        let overflow = all.count > 4
        let chips = Array(all.prefix(overflow ? 3 : 4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8 * s), GridItem(.flexible(), spacing: 8 * s)], spacing: 8 * s) {
            ForEach(chips) { session in
                AgentChip(session: session, status: shown(session), heat: heat.heat[session.id]?.level ?? .none, scale: s) { open(session) }
                    .islandTip(session.displayName + " · " + session.statusText(waiting: waiting(session)) + " · " + session.folderName)
            }
            if overflow {
                Button(action: onAgents) {
                    Text("+\(all.count - 3) more")
                        .font(font(12, .medium))
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, minHeight: 34 * s)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                        .hoverHalo(Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScale())
                .focusable(false)
                .islandTip("All agents")
            }
        }
        .padding(.horizontal, 12 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20 * s, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Content transition

private struct BlurFade: ViewModifier {
    var amount: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: 7 * amount)
            .opacity(Double(1 - amount))
            .scaleEffect(1 - 0.06 * amount, anchor: .top)
    }
}

private extension AnyTransition {
    /// Island content blurs in as it grows into place, and blurs out as it leaves.
    static var islandContent: AnyTransition {
        .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
    }
}

// MARK: - Tooltips

/// A hovered element's label and where it is, collected for the island's single tooltip layer
/// (drawn above everything, so a label never ends up behind the dashboard's cards).
struct IslandTip {
    var text: String
    var bounds: Anchor<CGRect>
}

struct IslandTipKey: PreferenceKey {
    static var defaultValue: [IslandTip] = []
    static func reduce(value: inout [IslandTip], nextValue: () -> [IslandTip]) { value.append(contentsOf: nextValue()) }
}

private struct IslandTipSource: ViewModifier {
    var text: String
    @ViewState private var hover = false

    func body(content: Content) -> some View {
        content
            .pointerHover { hover = $0 }
            .anchorPreference(key: IslandTipKey.self, value: .bounds) { hover ? [IslandTip(text: text, bounds: $0)] : [] }
    }
}

extension View {
    /// Says what this part of the notch island does, under it, while it's hovered.
    func islandTip(_ text: String) -> some View { modifier(IslandTipSource(text: text)) }
}

/// The tooltip under the hovered element, kept inside the island's window.
private struct IslandTipLayer: View {
    var tip: IslandTip?
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        GeometryReader { proxy in
            if let tip {
                Text(tip.text)
                    .font(look.font(11, .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 4.5)
                    .background(Capsule().fill(Color(hex: "#1C1C1E")))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .modifier(TipPlacement(anchor: proxy[tip.bounds], container: proxy.size))
                    .id(tip.text)
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: tip?.text)
        .allowsHitTesting(false)
    }
}

private struct TipWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Centers the label under its element, clamped so it never runs off the window's sides.
private struct TipPlacement: ViewModifier {
    var anchor: CGRect
    var container: CGSize
    @ViewState private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let half = width / 2
        let x = min(max(anchor.midX, half + 4), max(half + 4, container.width - half - 4))
        content
            .background(GeometryReader { label in
                Color.clear.preference(key: TipWidthKey.self, value: label.size.width)
            })
            .onPreferenceChange(TipWidthKey.self) { width = $0 }
            .position(x: x, y: anchor.maxY + 15)
    }
}

// MARK: - Pieces

/// A round button in the island's bar.
private struct IslandButton<Icon: View>: View {
    var size: CGFloat
    var active = false
    var tip: String
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            icon()
                .foregroundStyle(Color.white.opacity(hover || active ? 1 : 0.82))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(active ? 0.16 : 0)))
                .hoverHalo(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .pointerHover { hover = $0 }
        .islandTip(tip)
    }
}

/// One line of the dashboard: what an agent is doing. The first (the one that most needs you) is bigger.
private struct ActivityLine: View {
    var session: AgentSession
    var waiting: Int
    var status: AgentStatus
    var leading: Bool
    var scale: CGFloat
    var action: () -> Void
    @ObservedObject private var look = Appearance.shared
    @ViewState private var hover = false

    private var icon: String {
        if waiting > 0 { return "questionmark.bubble" }
        switch session.shownStatus {
        case .working: return "terminal"
        case .done, .ready: return "checkmark.square"
        default: return "hand.raised"
        }
    }

    private func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { look.font(size * scale, weight) }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
                Image(systemName: icon)
                    .font(font(leading ? 13 : 11, .medium))
                    .foregroundStyle(leading ? status.color : Theme.textFaint)
                    .frame(width: 16 * scale)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(font(leading ? 15 : 12.5, leading ? .medium : .regular))
                        .foregroundStyle(leading || hover ? Color.white : Color.white.opacity(0.5))
                        .lineLimit(1)
                    if leading {
                        Text(session.statusText(waiting: waiting) + " · " + session.folderName)
                            .font(font(11))
                            .foregroundStyle(status.color.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .pointerHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .islandTip(waiting > 0 ? "Answer \(session.displayName)" : "Open \(session.displayName)'s conversation")
    }
}

/// An agent as a tinted capsule: its status glyph in a disc, then its name.
private struct AgentChip: View {
    var session: AgentSession
    var status: AgentStatus
    var heat: HeatLevel
    var scale: CGFloat
    var action: () -> Void
    @ObservedObject private var look = Appearance.shared

    private var tint: Color { heat == .hot ? Fire.orange : status.color }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7 * scale) {
                StatusGlyph(status: status, size: 10 * scale, heat: heat, pop: 1.8)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .background(Circle().fill(tint.opacity(0.22)))
                Text(session.displayName)
                    .font(look.font(12.5 * scale, .medium))
                    .foregroundStyle(tint == AgentStatus.ready.color ? Color.white.opacity(0.85) : tint)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6 * scale).padding(.trailing, 10 * scale)
            .frame(minHeight: 34 * scale)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1))
            .hoverHalo(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .focusable(false)
    }
}

// MARK: - Panels hanging from the island

/// How a panel that opens out of the pill comes and goes. On an edge: a quick grow out of the
/// pill. At the notch: it unrolls downward from the island's bar, as if the island itself were
/// growing, and rolls back up into it when it closes.
struct PanelEntrance: ViewModifier {
    var open: Bool
    @ObservedObject private var look = Appearance.shared

    func body(content: Content) -> some View {
        if look.dock == .notch {
            content
                .mask(alignment: .top) {
                    Rectangle().scaleEffect(x: 1, y: open ? 1 : 0.001, anchor: .top)
                }
                .blur(radius: open ? 0 : 5)
                .opacity(open ? 1 : 0.5)
                .animation(open ? NotchIsland.opening : .spring(response: 0.3, dampingFraction: 0.95), value: open)
        } else {
            content
                .scaleEffect(open ? 1 : 0.92, anchor: look.dock.growAnchor)
                .opacity(open ? 1 : 0)
                .animation(.spring(response: 0.34, dampingFraction: 0.8), value: open)
        }
    }
}
