import SwiftUI
import AppKit
import ServiceManagement

enum MainTab: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case agents = "Agents"
    case phone = "Phone"
    case settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .workspaces: return "person.2.crop.square.stack"
        case .agents: return "terminal"
        case .phone: return "iphone"
        case .settings: return "gearshape"
        }
    }
}

final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let store: Store
    private let remote: RemoteServer
    private let voice: VoiceController
    private let nav = MainNav()

    init(store: Store, remote: RemoteServer, voice: VoiceController) {
        self.store = store
        self.remote = remote
        self.voice = voice
    }

    func show(_ tab: MainTab? = nil) {
        if let tab { nav.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Relay"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 500)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: MainView(store: store, remote: remote, voice: voice, nav: nav))
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app once the window is closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

final class MainNav: ObservableObject {
    @Published var tab: MainTab = .workspaces
}

struct MainView: View {
    @ObservedObject var store: Store
    @ObservedObject var remote: RemoteServer
    @ObservedObject var voice: VoiceController
    @ObservedObject var nav: MainNav

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            Group {
                switch nav.tab {
                case .workspaces: WorkspacesPane(store: store)
                case .agents: AgentsPane(store: store)
                case .phone: PhonePane(remote: remote)
                case .settings: SettingsPane(store: store, voice: voice)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(hex: "#0E0E10"))
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AppGlyph(size: 22)
                Text("Relay").font(.system(size: 15, weight: .semibold))
            }
            .padding(.top, 38).padding(.bottom, 18).padding(.horizontal, 6)
            ForEach(MainTab.allCases) { t in
                SidebarItem {
                    HStack(spacing: 9) {
                        Image(systemName: t.icon).frame(width: 18)
                        Text(t.rawValue)
                        Spacer()
                        if t == .agents, store.waitingCount > 0 {
                            Text("\(store.waitingCount)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                                .padding(.horizontal, 5).background(Capsule().fill(Theme.amber))
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(nav.tab == t ? Color.white.opacity(0.09) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { nav.tab = t }
                }
            }
            Spacer()
            Text("Never keep an agent waiting.")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 8).padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .background(Color(hex: "#0A0A0B"))
    }
}

private struct SidebarItem<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

// MARK: - Workspaces

struct WorkspacesPane: View {
    @ObservedObject var store: Store
    @ViewState private var selected: String?
    @ViewState private var showingAdd = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Accounts").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textFaint)
                    Spacer()
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("Add workspace")
                }
                .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.workspaces) { ws in
                            WorkspaceListRow(ws: ws, sessions: store.sessions.values.filter { $0.workspaceId == ws.id }.count,
                                             selected: (selected ?? store.workspaces.first?.id) == ws.id)
                                .onTapGesture { selected = ws.id }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Spacer()
                Button { showingAdd = true } label: {
                    Label("Add a Claude account", systemImage: "plus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(14)
            }
            .frame(width: 250)
            .background(Color(hex: "#111113"))
            Divider().opacity(0.4)
            if let id = selected ?? store.workspaces.first?.id, let ws = store.workspace(id) {
                WorkspaceDetail(store: store, ws: ws, onRemoved: { selected = nil })
                    .id(ws.id)
            } else {
                Spacer()
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddWorkspaceSheet(store: store) { newId in selected = newId }
        }
        .onAppear { store.refreshAllAccounts() }
    }
}

struct WorkspaceListRow: View {
    var ws: Workspace
    var sessions: Int
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(ws.color.opacity(0.22))
                Text(String(ws.name.prefix(1)).uppercased()).font(.system(size: 12, weight: .bold)).foregroundStyle(ws.color)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(ws.email ?? (ws.loggedIn == false ? "Not signed in" : "Checking…"))
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer()
            if sessions > 0 {
                Text("\(sessions)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textDim)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.white.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }
}

struct WorkspaceDetail: View {
    @ObservedObject var store: Store
    @ViewState var ws: Workspace
    var onRemoved: () -> Void
    @ViewState private var hooksOK = false
    @ViewState private var error: String?
    @ViewState private var loginEmail = ""
    @ViewState private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(current.color.opacity(0.2))
                        Text(String(current.name.prefix(1)).uppercased()).font(.system(size: 20, weight: .bold)).foregroundStyle(current.color)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name", text: $ws.name, onCommit: save)
                            .textFieldStyle(.plain).font(.system(size: 20, weight: .semibold))
                        HStack(spacing: 6) {
                            Circle().fill(current.loggedIn == true ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                            Text(accountLine).font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        }
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(Workspace.palette, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.white, lineWidth: ws.colorHex == hex ? 2 : 0))
                                .onTapGesture { ws.colorHex = hex; save() }
                        }
                    }
                }
                .padding(.top, 30)

                section("Account") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(current.loggedIn == true
                             ? "Claude Code sessions started in this workspace use \(current.email ?? "this account")."
                             : "Sign in with the Google (Gmail) account you use for Claude. A terminal opens and your browser finishes the sign-in.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        HStack(spacing: 8) {
                            TextField("you@gmail.com (optional)", text: $loginEmail)
                                .textFieldStyle(.roundedBorder).frame(width: 230)
                            Button(current.loggedIn == true ? "Switch account" : "Sign in") {
                                Launcher.login(workspace: current, email: loginEmail)
                                pollAccount()
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            if current.loggedIn == true {
                                Button("Sign out") { Launcher.logout(workspace: current); pollAccount() }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                            Button { store.refreshAccount(current.id) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).help("Refresh")
                        }
                    }
                }

                section("Start an agent") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button {
                                if let folder = pickFolder() { Launcher.newSession(workspace: current, folder: folder) }
                            } label: { Label("New Claude Code session…", systemImage: "plus.rectangle.on.rectangle") }
                                .buttonStyle(PrimaryButtonStyle())
                            Picker("", selection: Binding(get: { Launcher.preferred }, set: { Launcher.preferred = $0 })) {
                                ForEach(Launcher.App.allCases.filter { $0.isInstalled }) { Text("in \($0.rawValue)").tag($0) }
                            }
                            .frame(width: 120)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Or run it in any terminal:").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                            CopyField(text: commandLine)
                            HStack(spacing: 8) {
                                Text("Shell command").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                                TextField("e.g. claude-work", text: Binding(get: { ws.shellCommand ?? "" }, set: { ws.shellCommand = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 160)
                                Button("Save") { saveShellCommand() }.buttonStyle(SecondaryButtonStyle())
                            }
                            Text("Adds a `\(ws.shellCommand?.isEmpty == false ? ws.shellCommand! : "claude-work")` command to ~/.zshrc that starts Claude Code with this account.")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                        }
                    }
                }

                section("Connection") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Config folder", current.resolvedConfigDir + (current.isDefault ? "  (Claude Code default)" : ""))
                        HStack(spacing: 8) {
                            Circle().fill(hooksOK ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                            Text(hooksOK ? "Relay is connected to this workspace's Claude Code hooks." : "Hooks are not installed.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                            Spacer()
                            Button(hooksOK ? "Reinstall" : "Install hooks") { installHooks() }.buttonStyle(SecondaryButtonStyle())
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: current.resolvedConfigDir)
                            }.buttonStyle(SecondaryButtonStyle())
                        }
                        Text("Sessions that were already running pick up the hooks after a restart (/exit, then claude --resume).")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                    }
                }

                let live = store.sessions.values.filter { $0.workspaceId == current.id }.sorted { $0.startedAt < $1.startedAt }
                section("Running now (\(live.count))") {
                    if live.isEmpty {
                        Text("No sessions yet.").font(.system(size: 12)).foregroundStyle(Theme.textFaint)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(live) { s in
                                SessionRow(session: s, workspace: nil) {
                                    NotificationCenter.default.post(name: .relayViewSession, object: s.id)
                                }
                            }
                        }
                    }
                }

                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Color.red.opacity(0.9))
                }

                HStack {
                    Spacer()
                    Button(role: .destructive) { confirmRemove = true } label: { Text("Remove workspace") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .onAppear { hooksOK = HookInstaller.isInstalled(current) }
        .alert("Remove \(current.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                store.removeWorkspace(current.id, uninstallHooks: true)
                onRemoved()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Relay stops watching this account and removes its hooks. The config folder, login and history stay on disk.")
        }
    }

    private var current: Workspace { store.workspace(ws.id) ?? ws }

    private var accountLine: String {
        switch current.loggedIn {
        case .some(true):
            return [current.email, current.plan.map { $0.capitalized }].compactMap { $0 }.joined(separator: " · ")
        case .some(false): return "Not signed in"
        case .none: return "Checking…"
        }
    }

    private var commandLine: String {
        if let dir = current.configDir { return "CLAUDE_CONFIG_DIR=\(Shell.quote(dir)) claude" }
        return "claude"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textFaint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rowBorder, lineWidth: 1))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(Theme.textFaint).frame(width: 100, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func save() {
        var updated = current
        updated.name = ws.name.trimmingCharacters(in: .whitespaces).isEmpty ? current.name : ws.name
        updated.colorHex = ws.colorHex
        store.updateWorkspace(updated)
    }

    private func saveShellCommand() {
        let name = (ws.shellCommand ?? "").trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && !ShellCommands.isValidName(name) {
            error = "Use letters, numbers, - or _ (and not plain \"claude\")."
            return
        }
        if !name.isEmpty, store.workspaces.contains(where: { $0.id != current.id && $0.shellCommand == name }) {
            error = "Another workspace already uses \(name)."
            return
        }
        var updated = current
        updated.shellCommand = name.isEmpty ? nil : name
        store.updateWorkspace(updated)
        do {
            try ShellCommands.sync(store.workspaces)
            error = nil
            store.showToast(name.isEmpty ? "Shell command removed" : "Open a new terminal and run \(name)")
        } catch { self.error = error.localizedDescription }
    }

    private func installHooks() {
        do {
            try HookInstaller.install(current)
            hooksOK = HookInstaller.isInstalled(current)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Re-checks the login a few times while the user finishes signing in.
    private func pollAccount() {
        for delay in [5.0, 12, 20, 35, 60, 90] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { store.refreshAccount(current.id) }
        }
    }

    private func pickFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Claude here"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct AddWorkspaceSheet: View {
    @ObservedObject var store: Store
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var email = ""
    @ViewState private var useDefault = false
    @ViewState private var customDir = ""
    @ViewState private var command = ""
    @ViewState private var error: String?

    private var defaultTaken: Bool { store.workspaces.contains { $0.isDefault } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Claude account").font(.system(size: 17, weight: .semibold))
            Text("Each workspace has its own Claude Code login, settings and history, so you can run several accounts side by side.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            field("Name") { TextField("Work", text: $name).textFieldStyle(.roundedBorder) }
            field("Gmail") { TextField("you@gmail.com (pre-fills the sign-in page)", text: $email).textFieldStyle(.roundedBorder) }
            field("Shell command") { TextField("claude-work (optional)", text: $command).textFieldStyle(.roundedBorder) }
            if !defaultTaken {
                Toggle("Use Claude Code's default folder (~/.claude)", isOn: $useDefault)
                    .font(.system(size: 12))
            }
            if !useDefault {
                field("Config folder") {
                    TextField(Paths.workspaceRoot.appendingPathComponent(Store.slug(name.isEmpty ? "work" : name)).path, text: $customDir)
                        .textFieldStyle(.roundedBorder)
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and sign in") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .preferredColorScheme(.dark)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textDim).frame(width: 100, alignment: .leading)
            content()
        }
    }

    private func create() {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        if !cmd.isEmpty {
            guard ShellCommands.isValidName(cmd) else { error = "Shell command: letters, numbers, - or _ only."; return }
            guard !store.workspaces.contains(where: { $0.shellCommand == cmd }) else { error = "\(cmd) is already used."; return }
        }
        do {
            let dir: String? = useDefault ? (NSHomeDirectory() as NSString).appendingPathComponent(".claude") : customDir
            let ws = try store.addWorkspace(name: name.trimmingCharacters(in: .whitespaces), configDir: dir,
                                            shellCommand: cmd.isEmpty ? nil : cmd)
            onCreated(ws.id)
            dismiss()
            // Sign in right away unless the folder already has a login.
            DispatchQueue.global().async {
                let status = ClaudeCLI.authStatus(for: ws)
                if status?.loggedIn != true {
                    DispatchQueue.main.async { Launcher.login(workspace: ws, email: email) }
                }
                for delay in [8.0, 20, 40, 70, 100] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { store.refreshAccount(ws.id) }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CopyField: View {
    var text: String
    @ViewState private var copied = false

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textDim)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35)))
    }
}

// MARK: - Agents

struct AgentsPane: View {
    @ObservedObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Agents").font(.system(size: 20, weight: .semibold)).padding(.top, 34)
                if store.sessions.isEmpty {
                    Text("No Claude Code sessions are running in your workspaces. Start one from Workspaces, or run claude in any terminal.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                }
                ForEach(store.workspaces) { ws in
                    let list = store.sessions.values.filter { $0.workspaceId == ws.id }.sorted { $0.startedAt < $1.startedAt }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Circle().fill(ws.color).frame(width: 8, height: 8)
                                Text(ws.name).font(.system(size: 13, weight: .semibold))
                                Text(ws.email ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                            }
                            ForEach(list) { s in AgentCard(store: store, session: s) }
                        }
                    }
                }
                if !store.items.isEmpty {
                    Text("Inbox").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
                    ForEach(store.items) { item in
                        HStack {
                            Circle().fill(item.isActionable ? Theme.amber : Theme.green).frame(width: 7, height: 7)
                            Text("@\(store.session(for: item)?.handle ?? "?")").font(.system(size: 12, weight: .medium))
                            Text(item.title).font(.system(size: 12)).foregroundStyle(Theme.textDim).lineLimit(1)
                            Spacer()
                            Text(item.createdAt, style: .relative).font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                            Button("Dismiss") { store.dismiss(item) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.row))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AgentCard: View {
    @ObservedObject var store: Store
    var session: AgentSession
    @ViewState private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusRing(status: session.status, workspaceColor: nil)
                Text("@\(session.handle)").font(.system(size: 13, weight: .semibold))
                Text(session.shortPath).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textFaint)
                Text("· \(session.status.label)").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
                Spacer()
                Text(session.terminal.kindLabel).font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                Button("View") { NotificationCenter.default.post(name: .relayViewSession, object: session.id) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Terminal") { store.focusTerminal(sessionId: session.id) }.buttonStyle(SecondaryButtonStyle())
            }
            if let p = session.lastPrompt, !p.isEmpty {
                Text("› \(p)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            if let m = session.lastMessage, !m.isEmpty {
                Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.textDim).lineLimit(3)
            }
            HStack {
                TextField("Message @\(session.handle)…", text: $message, onCommit: send).textFieldStyle(.roundedBorder)
                Button("Send", action: send).disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.rowBorder, lineWidth: 1))
    }

    private func send() {
        let t = message
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        message = ""
        store.sendText(t, toSession: session.id)
    }
}

// MARK: - Phone

struct PhonePane: View {
    @ObservedObject var remote: RemoteServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Answer from your phone").font(.system(size: 20, weight: .semibold)).padding(.top, 34)
                Text("Open the inbox on any phone browser on the same Wi‑Fi. Scan the code, then add the page to your Home Screen. Your Mac must be awake with Relay open.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow phone access on this network", isOn: Binding(get: { remote.enabled }, set: { remote.setEnabled($0) }))
                if remote.enabled {
                    if let url = remote.url {
                        HStack(alignment: .top, spacing: 22) {
                            if let img = QRCode.image(for: url.absoluteString, size: 220) {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                                    .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                CopyField(text: url.absoluteString)
                                Button("Open on this Mac") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryButtonStyle())
                                Button("New link (signs out phones)") { remote.rotateToken() }.buttonStyle(SecondaryButtonStyle())
                                Text("Anyone with this link on your network can answer your agents. Keep it private.")
                                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text(remote.error ?? "Looking for a network address…").font(.system(size: 12)).foregroundStyle(Theme.amber)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @ObservedObject var store: Store
    @ObservedObject var voice: VoiceController
    @ViewState private var openCard = UIState.shared.openCardWhenAsked
    @ViewState private var notifications = Notifier.enabled
    @ViewState private var sound = Notifier.soundEnabled
    @ViewState private var nextSteps = Store.shared.nextStepsEnabled
    @ViewState private var screenshot = false
    @ViewState private var doubleOption = true
    @ViewState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ViewState private var locale = ""
    @ViewState private var axTrusted = AXIsProcessTrusted()
    @ViewState private var vertical = UserDefaults.standard.object(forKey: "pillVertical") as? Double ?? 0.5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(.system(size: 20, weight: .semibold)).padding(.top, 34)

                group("Inbox") {
                    Toggle("Open the card when an agent asks", isOn: $openCard)
                        .onChange(of: openCard) { UIState.shared.openCardWhenAsked = $0 }
                    Toggle("Show notifications", isOn: $notifications)
                        .onChange(of: notifications) { Notifier.enabled = $0 }
                    Toggle("Play a sound", isOn: $sound)
                        .onChange(of: sound) { Notifier.soundEnabled = $0 }
                    Toggle("Suggest next steps when an agent finishes", isOn: $nextSteps)
                        .onChange(of: nextSteps) { store.nextStepsEnabled = $0 }
                    Text("Asks Claude Haiku on that agent's own account, with no tools, for two likely follow-ups.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    HStack {
                        Text("Pill position")
                        Slider(value: $vertical, in: 0.1...0.9)
                            .frame(width: 200)
                            .onChange(of: vertical) {
                                UserDefaults.standard.set($0, forKey: "pillVertical")
                                NotificationCenter.default.post(name: .relayPillMoved, object: nil)
                            }
                        Text(vertical > 0.6 ? "high" : vertical < 0.4 ? "low" : "middle").foregroundStyle(Theme.textFaint)
                    }
                    Text("Shortcut: ⌃⌥Space opens the inbox. 1–9 picks an answer, ⏎ replies, ←→ moves, esc closes.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                }

                group("Talk") {
                    Toggle("Double-tap Option to talk", isOn: $doubleOption)
                        .onChange(of: doubleOption) { UserDefaults.standard.set($0, forKey: "doubleOptionEnabled") }
                    Toggle("Attach a screenshot of what I'm looking at", isOn: $screenshot)
                        .onChange(of: screenshot) { voice.attachScreenshotByDefault = $0 }
                    HStack {
                        Text("Language")
                        TextField("en-US", text: $locale, onCommit: { voice.localeId = locale })
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                        Text("e.g. en-US, fa-IR, de-DE").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    }
                    HStack(spacing: 8) {
                        Circle().fill(axTrusted ? Theme.green : Theme.amber).frame(width: 7, height: 7)
                        Text(axTrusted ? "Accessibility allowed (double-tap Option works everywhere)"
                                       : "Allow Accessibility so double-tap Option works in every app")
                            .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                        if !axTrusted {
                            Button("Allow…") {
                                DoubleOptionTap.requestPermission()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { axTrusted = AXIsProcessTrusted() }
                            }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                group("General") {
                    Toggle("Open Relay at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            } catch {
                                store.showToast("Move Relay to Applications first")
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    HStack {
                        Text("Hook script").foregroundStyle(Theme.textFaint)
                        Text(Paths.hookScript.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Text("Claude Code").foregroundStyle(Theme.textFaint)
                        Text(ClaudeCLI.path ?? "not found on PATH").font(.system(size: 11, design: .monospaced))
                    }
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 28).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            screenshot = voice.attachScreenshotByDefault
            doubleOption = UserDefaults.standard.object(forKey: "doubleOptionEnabled") as? Bool ?? true
            locale = voice.localeId
            axTrusted = AXIsProcessTrusted()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textFaint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.rowBorder, lineWidth: 1))
    }
}

extension Notification.Name {
    static let relayPillMoved = Notification.Name("relayPillMoved")
}

/// Small rounded glyph used as the app's mark.
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white)
            HStack(spacing: size * 0.12) {
                Circle().fill(Color.black).frame(width: size * 0.16)
                Circle().fill(Color.black).frame(width: size * 0.16)
            }
            .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
    }
}
