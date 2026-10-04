import SwiftUI

/// The strip on the right edge of the screen. Collapsed it is a sliver of status glyphs;
/// hovering opens the control column: inbox, agents, talk, screenshot and settings.
struct PillView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject private var look = Appearance.shared
    var onInbox: () -> Void
    var onAgents: () -> Void
    var onVoice: () -> Void
    var onScreenshotVoice: () -> Void
    var onHome: () -> Void
    var onMore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if ui.pillExpanded || ui.cardOpen || ui.panelOpen {
                expanded
                    .scaleEffect(look.pillScale, anchor: .trailing)
                    .padding(.trailing, 7)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                collapsed.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: ui.pillExpanded || ui.cardOpen || ui.panelOpen)
    }

    private var sessions: [AgentSession] { Array(store.visibleSessions.prefix(10)) }

    // MARK: Collapsed

    private var collapsed: some View {
        VStack(spacing: 4) {
            if sessions.isEmpty {
                Circle().fill(Color.white.opacity(0.35)).frame(width: 4, height: 4)
            }
            ForEach(sessions) { s in
                StatusGlyph(status: s.status, size: 5)
            }
        }
        .padding(.vertical, 7)
        .frame(width: 9)
        .background(LeftRoundedRect(radius: 5).fill(Color.black.opacity(0.82)))
        .overlay(LeftRoundedRect(radius: 5).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 7) {
            // Inbox
            Button(action: onInbox) {
                Image(systemName: "tray")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(ui.cardOpen ? Color.white.opacity(0.2) : Color.black.opacity(0.78)))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                    .overlay(alignment: .topTrailing) { inboxBadge }
            }
            .buttonStyle(.plain)
                .focusable(false)
            .hoverTip(store.waitingCount > 0 ? "\(store.waitingCount) waiting · ⌃⌥Space" : "Inbox · ⌃⌥Space")

            // Agents
            if !sessions.isEmpty {
                Button(action: onAgents) {
                    VStack(spacing: 6) {
                        ForEach(sessions) { s in
                            StatusGlyph(status: s.status, size: 8.5)
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(width: 22)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .hoverTip(agentsSummary)
            }

            // Talk group
            VStack(spacing: 2) {
                GroupButton(systemName: "face.smiling", help: "Workspaces", action: onHome)
                GroupButton(systemName: "mic", help: "Talk · ⌥⌥", action: onVoice)
                GroupButton(systemName: "camera", help: "Talk with a screenshot", action: onScreenshotVoice)
            }
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))

            // More
            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ui.panelOpen ? Color.white.opacity(0.2) : Color.black.opacity(0.78)))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
                .focusable(false)
            .hoverTip("Settings")
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    @ViewBuilder private var inboxBadge: some View {
        let items = store.visibleItems
        if items.contains(where: { $0.isActionable }) {
            Circle().fill(Theme.amber).frame(width: 7, height: 7).offset(x: 1, y: -1)
        } else if !items.isEmpty {
            Circle().fill(Theme.green).frame(width: 7, height: 7).offset(x: 1, y: -1)
        }
    }

    private var agentsSummary: String {
        let waiting = sessions.filter { $0.status == .waiting || $0.status == .idle }.count
        let working = sessions.filter { $0.status == .working }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.isEmpty ? "\(sessions.count) agents" : parts.joined(separator: " · ")
    }
}

private struct GroupButton: View {
    var systemName: String
    var help: String
    var action: () -> Void
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.85))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
        .hoverTip(help)
    }
}

/// Rectangle rounded only on its left side (it hugs the screen's right edge).
struct LeftRoundedRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(radius, rect.height / 2, rect.width)
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return p
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
