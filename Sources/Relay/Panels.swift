import SwiftUI
import AppKit

// MARK: - Agents list

/// Every running agent, grouped by account (or by project with a single account), like One's list.
struct AgentsListView: View {
    @ObservedObject var store: Store
    @ObservedObject private var look = Appearance.shared
    var onOpen: (String) -> Void
    var onTalk: (String) -> Void

    private var groups: [(title: String, subtitle: String?, sessions: [AgentSession])] {
        // Stable order (oldest first) so rows never move under the pointer.
        let all = store.visibleSessions.sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        if store.workspaces.count > 1 {
            return store.workspaces.compactMap { ws in
                let list = all.filter { $0.workspaceId == ws.id }
                return list.isEmpty ? nil : (ws.name, ws.email, list)
            }
        }
        var order: [String] = []
        var byFolder: [String: [AgentSession]] = [:]
        for s in all {
            if byFolder[s.folderName] == nil { order.append(s.folderName) }
            byFolder[s.folderName, default: []].append(s)
        }
        return order.map { ($0, nil, byFolder[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No agents running").font(look.font(12.5, .semibold)).foregroundStyle(.white)
                    Text("Start Claude Code in any terminal or the Claude app.")
                        .font(look.font(11)).foregroundStyle(Theme.textDim)
                }
                .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(g.title).font(look.font(11, .semibold)).foregroundStyle(Theme.textDim)
                                    if let sub = g.subtitle {
                                        Text(sub).font(look.font(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 8).padding(.bottom, 2)
                                ForEach(g.sessions) { s in
                                    AgentRow(session: s,
                                             waiting: store.items.filter { $0.sessionId == s.id && $0.isActionable }.count,
                                             onOpen: { onOpen(s.id) },
                                             onTalk: { onTalk(s.id) },
                                             onHide: { store.forgetSession(s.id) })
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 480)
            }
        }
        .frame(width: 300 * look.textScale)
        .fixedSize(horizontal: false, vertical: true)
        .background(Glass())
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(16)
        .preferredColorScheme(.dark)
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let waiting: Int
    var onOpen: () -> Void
    var onTalk: () -> Void
    var onHide: () -> Void
    @ViewState private var hover = false
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: session.status, size: 8)
                .frame(width: 10)
            AgentMark(status: session.status, size: 13)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayName).font(look.font(12.5, .medium)).foregroundStyle(.white).lineLimit(1)
                if hover {
                    Text("\(session.shortPath) · \(session.status.label) · \(session.terminal.kindLabel)")
                        .font(look.font(10)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
            }
            if waiting > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "tray").font(look.font(8.5))
                    Text("\(waiting)").font(look.font(10, .semibold))
                }
                .foregroundStyle(Theme.amber)
            }
            Spacer(minLength: 4)
            IconButton(systemName: "mic", size: 10.5, action: onTalk).opacity(hover ? 1 : 0.55).help("Talk to this agent")
            IconButton(systemName: "xmark", size: 9.5, action: onHide).opacity(hover ? 1 : 0.55).help("Hide from the list")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
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
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(16)
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
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(16)
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
        .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        .padding(16)
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
