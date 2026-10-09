import SwiftUI
import AppKit

// MARK: - Agents list

/// Every running agent, grouped by account (or by project with a single account), like One's list:
/// one compact line per agent with talk and hide always at hand.
struct AgentsListView: View {
    @ObservedObject var store: Store
    @ObservedObject private var look = Appearance.shared
    @ObservedObject private var heat = HeatMonitor.shared
    var onOpen: (String) -> Void
    var onTalk: (String) -> Void
    /// Rows fade in one after another when the list opens.
    @ViewState private var revealed = false

    private struct AgentGroup {
        var title: String
        var subtitle: String?
        var color: Color?
        var sessions: [AgentSession]
    }

    private var byAccount: Bool { store.workspaces.count > 1 }

    private var groups: [AgentGroup] {
        // Stable order (oldest first) so rows never move under the pointer.
        let all = store.visibleSessions.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        if byAccount {
            return store.workspaces.compactMap { ws in
                let list = all.filter { $0.workspaceId == ws.id }
                return list.isEmpty ? nil : AgentGroup(title: ws.name, subtitle: ws.email, color: ws.color, sessions: list)
            }
        }
        var order: [String] = []
        var byFolder: [String: [AgentSession]] = [:]
        for s in all {
            if byFolder[s.folderName] == nil { order.append(s.folderName) }
            byFolder[s.folderName, default: []].append(s)
        }
        return order.map { AgentGroup(title: $0, subtitle: nil, color: nil, sessions: byFolder[$0] ?? []) }
    }

    private func waiting(_ s: AgentSession) -> Int {
        store.items.filter { $0.sessionId == s.id && $0.isActionable }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.visibleSessions.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        let gs = groups
                        ForEach(Array(gs.enumerated()), id: \.offset) { gi, g in
                            let before = gs.prefix(gi).reduce(0) { $0 + $1.sessions.count + 1 }
                            VStack(alignment: .leading, spacing: 1) {
                                groupHeader(g, first: gi == 0)
                                    .modifier(Reveal(on: revealed, index: before))
                                ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                                    AgentRow(session: s,
                                             waiting: waiting(s),
                                             heat: heat.heat[s.id],
                                             showFolder: byAccount,
                                             onOpen: { onOpen(s.id) },
                                             onTalk: { onTalk(s.id) },
                                             onHide: { store.forgetSession(s.id) })
                                        .modifier(Reveal(on: revealed, index: before + 1 + i))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 7).padding(.top, 11).padding(.bottom, 8)
                }
                .frame(maxHeight: 520)
            }
        }
        .frame(width: 318 * look.textScale)
        .fixedSize(horizontal: false, vertical: true)
        .background(Glass(cornerRadius: 18))
        .floatingPanelShadow()
        .scaleEffect(revealed ? 1 : 0.94, anchor: .trailing)
        .opacity(revealed ? 1 : 0)
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { revealed = true } }
    }

    private func groupHeader(_ g: AgentGroup, first: Bool) -> some View {
        let clearable = first ? store.visibleSessions.filter(store.isClearable).count : 0
        return HStack(spacing: 5) {
            if let color = g.color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(g.title).font(look.font(12, .semibold)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(1)
            if let sub = g.subtitle {
                Text("· \(sub)").font(look.font(12, .medium)).foregroundStyle(Color.white.opacity(0.32))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if heat.macIsHot && first { ThermalTally(thermal: heat.thermal) }
            if clearable > 0 { ClearButton(count: clearable) { store.forgetClearableSessions(store.visibleSessions) } }
        }
        .padding(.horizontal, 9).padding(.bottom, 3)
        .frame(minHeight: 20)
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Mascot(size: 30).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("No agents running").font(look.font(13, .semibold)).foregroundStyle(.white)
                Text("Start Claude Code in any terminal or the Claude app.")
                    .font(look.font(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15).padding(.vertical, 15)
    }
}

/// Staggered fade-and-slide for list rows as the panel opens.
private struct Reveal: ViewModifier {
    var on: Bool
    var index: Int

    func body(content: Content) -> some View {
        content
            .opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 6)
            .animation(.spring(response: 0.36, dampingFraction: 0.84).delay(Double(min(index, 14)) * 0.028), value: on)
    }
}

/// "Clear 5": hides every done or ready agent in one click.
private struct ClearButton: View {
    var count: Int
    var action: () -> Void
    @ObservedObject private var look = Appearance.shared
    @ViewState private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(look.font(8, .bold))
                Text("Clear \(count)").font(look.font(10, .medium).monospacedDigit())
            }
            .foregroundStyle(Theme.green)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.green.opacity(hover ? 0.24 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help("Remove done and ready agents from the list; each returns when it does something again")
    }
}

/// "3 working" with a colored dot, used in agents list headers.
struct Tally: View {
    var count: Int
    var label: String
    var color: Color
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count) \(label)").font(look.font(10, .medium).monospacedDigit())
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let waiting: Int
    let heat: SessionHeat?
    /// Show the project folder (rows are grouped by account rather than by folder).
    let showFolder: Bool
    var onOpen: () -> Void
    var onTalk: () -> Void
    var onHide: () -> Void
    @ViewState private var hover = false
    /// Green wash that fades out after the agent finishes.
    @ViewState private var flash: Double = 0
    @ObservedObject private var look = Appearance.shared

    private var needsYou: Bool { session.needsYou(waiting: waiting) }
    private var status: AgentStatus { waiting > 0 ? .waiting : session.shownStatus }
    private var heatLevel: HeatLevel { heat?.level ?? .none }
    private var tasks: Int { session.backgroundTasks ?? 0 }

    /// Everything the compact row leaves out, on hover.
    private var details: String {
        var parts = [session.statusText(waiting: waiting)]
        if showFolder || session.title?.isEmpty == false { parts.append(session.folderName) }
        parts.append(session.terminal.kindLabel)
        if let h = heat, h.level > .none { parts.append(h.cpuLabel) }
        var text = parts.joined(separator: " · ")
        if let p = session.promptPreview { text += "\n" + p }
        return text
    }

    var body: some View {
        HStack(spacing: 9) {
            StatusGlyph(status: status, size: 8.5, heat: heatLevel, pop: 1.9)
                .frame(width: 12)
            Image(systemName: "staroflife.fill")
                .font(look.font(11, .bold))
                .foregroundStyle(heatLevel == .hot ? AnyShapeStyle(Fire.gradient) : AnyShapeStyle(Theme.claude))
                .frame(width: 15)
            Text(session.displayName)
                .font(look.font(13, .medium)).foregroundStyle(.white).lineLimit(1)
            if tasks > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(look.font(9.5, .medium))
                    Text("\(tasks)").font(look.font(11, .medium).monospacedDigit())
                }
                .foregroundStyle(Theme.textDim)
                .help(tasks == 1 ? "1 background task" : "\(tasks) background tasks")
            }
            Spacer(minLength: 6)
            RowIcon(systemName: "mic", size: 11.5, action: onTalk).help("Talk to this agent")
            RowIcon(systemName: "xmark", size: 10, action: onHide).help("Hide from the list")
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.vertical, 4)
        .frame(minHeight: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowFill)
        )
        .overlay {
            if heatLevel > .none { FireBorder(cornerRadius: 9, level: heatLevel) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(details)
        .onChange(of: session.shownStatus) { new in
            guard new == .done || new == .ready || new == .idle else { return }
            flash = 1
            withAnimation(.easeOut(duration: 1.6).delay(0.25)) { flash = 0 }
        }
    }

    private var rowFill: Color {
        if flash > 0 { return Theme.green.opacity(0.16 * flash + (hover ? 0.04 : 0)) }
        if needsYou && waiting > 0 { return Theme.amber.opacity(hover ? 0.13 : 0.08) }
        return Color.white.opacity(hover ? 0.065 : 0)
    }
}

/// Mic and close on each agent row: dim until you point at them.
private struct RowIcon: View {
    var systemName: String
    var size: CGFloat
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(look.font(size, .medium))
                .foregroundStyle(Color.white.opacity(hover ? 0.95 : 0.45))
                .frame(width: 24, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)).frame(width: 22, height: 22))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .focusable(false)
        .onHover { hover = $0 }
    }
}

/// "now", "4m", "2h", "3d".
func shortAgo(_ date: Date, now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

extension AgentSession {
    /// Waiting on you: a question or permission prompt, or idle at its prompt with nothing in the background.
    func needsYou(waiting: Int) -> Bool {
        waiting > 0 || shownStatus == .waiting || shownStatus == .idle
    }

    func statusText(waiting: Int) -> String {
        if waiting > 0 { return waiting == 1 ? "Needs you" : "\(waiting) waiting" }
        let bg = backgroundTasks ?? 0
        if bg > 0 && status != .working && shownStatus == .working {
            return bg == 1 ? "1 background task" : "\(bg) background tasks"
        }
        switch shownStatus {
        case .working: return "Working"
        case .waiting: return "Asking"
        case .idle: return "Your turn"
        case .done: return "Done"
        case .ready: return "Ready"
        case .ended: return "Ended"
        }
    }
}

/// The agent's avatar in the list: the Claude spark in a soft disc, ringed by its status
/// (a spinning arc while it works).
struct AgentOrb: View {
    var status: AgentStatus
    var attention: Bool
    var size: CGFloat = 30
    var heat: HeatLevel = .none
    @ViewState private var spin = false

    var body: some View {
        ZStack {
            if heat > .none {
                // A glowing coal: opaque, so the flames behind it read as rising off its rim.
                Circle().fill(RadialGradient(colors: [heat == .hot ? Fire.ember : Fire.ember.opacity(0.45), Fire.coal],
                                             center: UnitPoint(x: 0.5, y: 0.65), startRadius: 0, endRadius: size * 0.55))
            } else {
                Circle().fill(Theme.claude.opacity(0.13))
            }
            if heat == .hot {
                Image(systemName: "staroflife.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Fire.gradient)
                    .shadow(color: Fire.yellow.opacity(0.7), radius: 3)
            } else {
                Image(systemName: "staroflife.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Theme.claude)
            }
            if heat == .hot {
                Circle()
                    .strokeBorder(Fire.ring, lineWidth: 2)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
                    }
            } else if status == .working {
                Circle().strokeBorder(Theme.blue.opacity(0.18), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Theme.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true }
                    }
            } else {
                Circle().strokeBorder((attention ? Theme.amber : status.color).opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        // Behind, not in the ZStack: the aura is larger than the orb and would stretch its circles.
        .background {
            if heat > .none { FlameAura(size: size, intensity: heat == .hot ? 1 : 0.5) }
        }
        .shadow(color: attention ? Theme.amber.opacity(0.45) : heat == .hot ? Fire.orange.opacity(0.6) : .clear, radius: 6)
        .id("\(status == .working)-\(heat.rawValue)")   // fresh view (and animation) every time work starts again
    }
}

// MARK: - Settings menu

enum SettingsAction {
    case workspaces, phone, settings, look, filter, hide, quit
}

struct SettingsMenuView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @ObservedObject private var look = Appearance.shared
    var phoneOn: Bool
    var onAction: (SettingsAction) -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "gearshape").font(look.font(12, .semibold))
                Text("Settings").font(look.font(13, .semibold))
                Spacer()
                Text(version).font(look.font(10.5)).foregroundStyle(Theme.textFaint)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)

            VStack(spacing: 1) {
                MenuRow(icon: "person.crop.circle", title: "Accounts", value: accountsValue) { onAction(.workspaces) }
                MenuRow(icon: "line.3.horizontal.decrease.circle", title: "Showing", value: filterValue,
                        selected: ui.subPanel == .workspaces) { onAction(.filter) }
                MenuRow(icon: "iphone", title: "Phone", value: phoneOn ? "On" : "Off") { onAction(.phone) }
                MenuRow(icon: "paintpalette", title: "Look & sound",
                        value: "\(look.theme.rawValue) · \(Int(look.textScale * 100))%",
                        selected: ui.subPanel == .look) { onAction(.look) }
                MenuRow(icon: "slider.horizontal.3", title: "Advanced", value: nil) { onAction(.settings) }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.05)))

            VStack(spacing: 1) {
                PlainMenuRow(icon: "pause", title: "Hide for 2 hours") { onAction(.hide) }
                PlainMenuRow(icon: "power", title: "Quit Relay") { onAction(.quit) }
            }
            .padding(.top, 4)
        }
        .padding(8)
        .frame(width: 272 * look.textScale)
        .background(Glass(cornerRadius: 16))
        .floatingPanelShadow()
        .preferredColorScheme(.dark)
    }

    private var accountsValue: String {
        if store.workspaces.count == 1 { return store.workspaces.first?.email ?? "Not signed in" }
        return "\(store.workspaces.count) accounts"
    }

    private var filterValue: String {
        store.workspaceFilter.flatMap { store.workspace($0)?.name } ?? "All"
    }
}

private struct MenuRow: View {
    var icon: String
    var title: String
    var value: String?
    var selected = false
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(look.font(12)).frame(width: 18).foregroundStyle(Color.white.opacity(0.8))
                Text(title).font(look.font(12.5, .medium)).foregroundStyle(.white)
                Spacer(minLength: 6)
                if let value {
                    Text(value).font(look.font(11)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(look.font(9, .semibold)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8).padding(.vertical, 6.5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : (hover ? 0.08 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
    }
}

private struct PlainMenuRow: View {
    var icon: String
    var title: String
    var action: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(look.font(11)).frame(width: 18).foregroundStyle(Theme.textDim)
                Text(title).font(look.font(12.5)).foregroundStyle(Color.white.opacity(0.9))
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 5.5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
        .onHover { hover = $0 }
    }
}

// MARK: - Look & sound

struct LookSoundView: View {
    @ObservedObject private var look = Appearance.shared
    @ViewState private var sounds = Notifier.soundEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "paintpalette").font(look.font(12, .semibold))
                Text("Look & sound").font(look.font(13, .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)

            section("Theme") {
                HStack(spacing: 10) {
                    ForEach(Appearance.ThemeChoice.allCases) { t in
                        Button { look.theme = t } label: {
                            VStack(spacing: 4) {
                                ThemeSwatch(dark: t == .black ? 0.95 : 0.6)
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .stroke(look.theme == t ? Theme.blue : Color.white.opacity(0.15), lineWidth: look.theme == t ? 2 : 1))
                                Text(t.rawValue).font(look.font(10.5, look.theme == t ? .semibold : .regular))
                                    .foregroundStyle(look.theme == t ? .white : Theme.textDim)
                            }
                        }
                        .buttonStyle(.plain)
                .focusable(false)
                    }
                    Spacer()
                }
            }

            section("Pill") {
                VStack(spacing: 6) {
                    sliderRow(icon: "arrow.up.left.and.arrow.down.right", title: "Pill size", value: $look.pillScale, range: 0.8...1.3)
                    sliderRow(icon: "textformat.size", title: "Text size", value: $look.textScale, range: 0.9...1.25)
                }
            }

            section("Keyboard") {
                VStack(alignment: .leading, spacing: 5) {
                    shortcut("Talk", keys: "⌥ ×2", note: "Double-tap Option from any app to talk. One more tap sends it.")
                    shortcut("Inbox", keys: "⌃⌥Space", note: "1–9 answer · J/K move · E discard · esc undo")
                }
            }

            section("Sounds") {
                VStack(spacing: 6) {
                    HStack {
                        Text("Play sounds").font(look.font(12)).foregroundStyle(.white)
                        Spacer()
                        Toggle("", isOn: $sounds)
                            .labelsHidden()
                            .toggleStyle(.switch).controlSize(.mini)
                            .onChange(of: sounds) { Notifier.soundEnabled = $0 }
                    }
                    HStack {
                        Text("Sound").font(look.font(12)).foregroundStyle(.white)
                        Spacer()
                        Picker("", selection: $look.soundName) {
                            ForEach(Appearance.sounds, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                        .onChange(of: look.soundName) { NSSound(named: $0)?.play() }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 290 * look.textScale)
        .background(Glass(cornerRadius: 16))
        .floatingPanelShadow()
        .preferredColorScheme(.dark)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(look.font(10.5, .semibold)).foregroundStyle(Theme.textFaint).padding(.horizontal, 4)
            content()
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
        }
    }

    private func sliderRow(icon: String, title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(look.font(10)).foregroundStyle(Theme.textDim).frame(width: 14)
            Text(title).font(look.font(12)).foregroundStyle(.white).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
            Text("\(Int(value.wrappedValue * 100))%").font(look.font(10.5)).foregroundStyle(Theme.textDim).frame(width: 36, alignment: .trailing)
        }
    }

    private func shortcut(_ title: String, keys: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(look.font(12)).foregroundStyle(.white)
                Spacer()
                KeyHint(key: keys)
            }
            Text(note).font(look.font(10)).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ThemeSwatch: View {
    var dark: Double
    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.black.opacity(dark))
            .overlay(
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: 22, height: 2.5)
                    Capsule().fill(Color.white.opacity(0.4)).frame(width: 14, height: 2.5)
                }
                .padding(7), alignment: .topLeading)
            .overlay(Circle().fill(Theme.blue).frame(width: 5, height: 5).padding(6), alignment: .bottomTrailing)
            .frame(width: 52, height: 34)
    }
}

// MARK: - Workspace filter

struct WorkspaceFilterView: View {
    @ObservedObject var store: Store
    @ObservedObject private var look = Appearance.shared
    var onAddAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Show agents from").font(look.font(11, .semibold)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 8).padding(.bottom, 4)
            row(title: "All accounts", subtitle: nil, color: nil, selected: store.workspaceFilter == nil) {
                store.workspaceFilter = nil
            }
            ForEach(store.workspaces) { ws in
                row(title: ws.name, subtitle: ws.email ?? (ws.loggedIn == false ? "Not signed in" : nil),
                    color: ws.color, selected: store.workspaceFilter == ws.id) {
                    store.workspaceFilter = ws.id
                }
            }
            Divider().opacity(0.3).padding(.vertical, 4)
            Button(action: onAddAccount) {
                Label("Add a Claude account…", systemImage: "plus")
                    .font(look.font(12)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
                .focusable(false)
        }
        .padding(8)
        .frame(width: 260 * look.textScale)
        .background(Glass(cornerRadius: 16))
        .floatingPanelShadow()
        .preferredColorScheme(.dark)
    }

    private func row(title: String, subtitle: String?, color: Color?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(color ?? Color.white.opacity(0.5)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(look.font(12.5, .medium)).foregroundStyle(.white)
                    if let subtitle { Text(subtitle).font(look.font(10)).foregroundStyle(Theme.textFaint).lineLimit(1) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").font(look.font(10, .bold)).foregroundStyle(Theme.blue) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(selected ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
                .focusable(false)
    }
}
