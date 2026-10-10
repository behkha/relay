import AppKit
import SwiftUI
import Combine
import UserNotifications
import Carbon.HIToolbox

@main
enum RelayMain {
    static func main() {
        // scripts/selftest.sh: run the built-in checks and exit before anything starts
        // (no NSApplication, listeners, hooks or UI), so it never collides with a running Relay.
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.runAll() ? 0 : 1)
        }
        // scripts/record-mascot.sh: just the mascot in a window of its own, nothing else starts.
        if MascotRecording.isOn {
            MascotRecording.main()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let store = Store.shared
    private let ui = UIState.shared
    private var hookServer: HTTPServer?
    private var overlay: OverlayController!
    private var voice: VoiceController!
    private var remote: RemoteServer!
    private var access: RemoteAccess!
    private var main: MainWindowController!
    private var statusItem: NSStatusItem!
    private var hotkey: GlobalHotkey?
    private var optionTap: DoubleOptionTap?
    private var bag = Set<AnyCancellable>()
    private var viewer: SessionViewerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count > 1 {
            NSApp.terminate(nil)
            return
        }
        if Demo.isOn { Demo.prepareDefaults() }
        else {
            startHookServer()
            HeatMonitor.shared.start()
            PowerAssertion.shared.start(store: store)
            store.ensureHooks()
            store.refreshAllAccounts()
        }

        voice = VoiceController(store: store, ui: ui)
        remote = RemoteServer(store: store)
        access = RemoteAccess(store: store)
        main = MainWindowController(store: store, remote: remote, access: access, voice: voice)
        overlay = OverlayController(store: store, ui: ui)
        overlay.onVoice = { [weak self] shot in
            guard let self else { return }
            if self.voice.open { self.voice.send() }
            else { self.voice.start(target: self.ui.cardOpen ? self.ui.currentItem(in: self.store) : nil, screenshot: shot) }
        }
        overlay.onVoiceReply = { [weak self] item in self?.voice.start(target: item, screenshot: false) }
        voice.anchor = { [weak self] in self?.overlay.talkAnchor }
        voice.beforeScreenshot = { [weak self] in self?.overlay.prepareForScreenshot() }
        overlay.onHome = { [weak self] in self?.main.show() }
        overlay.phoneOn = { [weak self] in (self?.remote.enabled ?? false) || (self?.access.enabled ?? false) }
        overlay.onTalkTo = { [weak self] sessionId in self?.voice.start(sessionId: sessionId) }
        overlay.onSettingsAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .workspaces: self.main.show(.workspaces)
            case .phone: self.main.show(.phone)
            case .settings: self.main.show(.settings)
            case .hide:
                let until = Date().addingTimeInterval(2 * 3600)
                UserDefaults.standard.set(until, forKey: "hiddenUntil")
                self.overlay.isPillVisible = false
                self.statusItem.menu = self.buildMenu(forPill: false)
                self.scheduleUnhide(at: until)
            case .quit: NSApp.terminate(nil)
            case .look, .filter: break
            }
        }

        if Demo.isOn {
            Demo.run(store: store, ui: ui, overlay: overlay, voice: voice)
            return
        }

        setupStatusItem()
        if let until = UserDefaults.standard.object(forKey: "hiddenUntil") as? Date { scheduleUnhide(at: until) }
        hotkey = GlobalHotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), id: 1) { [weak self] in
            self?.overlay.toggleCard(focus: true)
        }
        optionTap = DoubleOptionTap { [weak self] in self?.voice.toggle() }

        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()

        NotificationCenter.default.addObserver(forName: .relayPillMoved, object: nil, queue: .main) { [weak self] _ in
            self?.overlay.positionPill()
        }
        viewer = SessionViewerController(store: store)
        NotificationCenter.default.addObserver(forName: .relayViewSession, object: nil, queue: .main) { [weak self] note in
            guard let self, let id = note.object as? String else { return }
            self.viewer.show(sessionId: id, near: self.overlay.anchorFrame)
        }
        NotificationCenter.default.addObserver(forName: .relayOpenItem, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let id = note.object as? String
            // Show the item even if its workspace is filtered out of the pill.
            if let id, let item = self.store.items.first(where: { $0.id == id }),
               let f = self.store.workspaceFilter, f != item.workspaceId {
                self.store.workspaceFilter = nil
            }
            self.overlay.openCard(focus: true, itemId: id)
        }

        // Debug aid: `open --env RELAY_VIEW_SESSION=<folder name> Relay.app` opens that agent's viewer.
        if let want = ProcessInfo.processInfo.environment["RELAY_VIEW_SESSION"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let s = self.store.sessions.values.filter({ $0.folderName == want }).max(by: { $0.updatedAt < $1.updatedAt }) {
                    NotificationCenter.default.post(name: .relayViewSession, object: s.id)
                }
            }
        }

        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            main.show(.workspaces)
        }
    }

    /// An answer still counting down is sent before quitting, and given a moment to reach its hook.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ui.commit != nil else { return .terminateNow }
        ui.flushCommit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Demo.isOn { try? FileManager.default.removeItem(at: Paths.support) }
        store.releaseAll()
        hookServer?.stop()
    }

    /// Shows the pill again when "Hide for 2 hours" runs out (wall clock, so sleep counts).
    private func scheduleUnhide(at until: Date) {
        let delay = max(0, until.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay) { [weak self] in
            guard let self, let current = UserDefaults.standard.object(forKey: "hiddenUntil") as? Date,
                  current == until else { return }   // a newer hide (or a manual show) replaced this one
            UserDefaults.standard.removeObject(forKey: "hiddenUntil")
            self.overlay.isPillVisible = true
            self.statusItem.menu = self.buildMenu(forPill: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.show()
        return true
    }

    // MARK: Hook server

    private func startHookServer() {
        let token = RemoteServer.randomToken()
        let server = HTTPServer(label: "hooks", localOnly: true) { [weak self] req, ex in
            guard let self else { ex.respond(.empty); return }
            guard req.method == "POST", req.path.hasPrefix("/hook/"),
                  req.header("x-relay-token") == token else {
                ex.respond(.unauthorized); return
            }
            let event = String(req.path.dropFirst("/hook/".count))
            self.store.handleHook(event: event, request: req, exchange: ex)
        }
        do {
            try server.start(preferredPort: 47823)
            hookServer = server
            let conf: [String: Any] = ["port": Int(server.port), "token": token, "pid": Int(getpid())]
            let data = try JSONSerialization.data(withJSONObject: conf, options: [.prettyPrinted])
            try data.write(to: Paths.serverConfig, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.serverConfig.path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Relay couldn't start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(count: 0)
        statusItem.menu = buildMenu(forPill: false)
        store.$items.combineLatest(store.$workspaceFilter).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusIcon(count: self.store.waitingCount)
        }.store(in: &bag)
        store.$workspaces.combineLatest(store.$sessions).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.statusItem.menu = self.buildMenu(forPill: false) }
        }.store(in: &bag)
    }

    private func updateStatusIcon(count: Int) {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: count > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill" : "bubble.left.and.bubble.right",
                          accessibilityDescription: "Relay")
        img?.isTemplate = true
        button.image = img
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = .imageLeading
    }

    func buildMenu(forPill: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("Open Inbox", key: " ", mods: [.control, .option]) { [weak self] in self?.overlay.openCard(focus: true) })
        menu.addItem(item("Talk to an agent  (⌥⌥)") { [weak self] in self?.voice.toggle() })
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let all = item("All workspaces") { [weak self] in self?.store.workspaceFilter = nil }
        all.state = store.workspaceFilter == nil ? .on : .off
        menu.addItem(all)
        for ws in store.workspaces {
            let count = store.sessions.values.filter { $0.workspaceId == ws.id }.count
            let title = ws.name + (ws.email.map { "  ·  \($0)" } ?? "") + (count > 0 ? "  (\(count))" : "")
            let mi = item(title) { [weak self] in self?.store.workspaceFilter = ws.id }
            mi.state = store.workspaceFilter == ws.id ? .on : .off
            mi.image = Self.dot(NSColor(Color(hex: ws.colorHex)))
            menu.addItem(mi)
        }
        menu.addItem(item("Add a Claude account…") { [weak self] in self?.main.show(.workspaces) })
        menu.addItem(.separator())
        menu.addItem(item("Workspaces…", key: ",", mods: [.command]) { [weak self] in self?.main.show(.workspaces) })
        menu.addItem(item("Agents…") { [weak self] in self?.main.show(.agents) })
        menu.addItem(item("Phone…") { [weak self] in self?.main.show(.phone) })
        menu.addItem(item("Settings…") { [weak self] in self?.main.show(.settings) })
        let pill = item(overlay.isPillVisible ? "Hide edge pill" : "Show edge pill") { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: "hiddenUntil")
            self.overlay.isPillVisible.toggle()
            self.statusItem.menu = self.buildMenu(forPill: false)
        }
        menu.addItem(pill)
        menu.addItem(.separator())
        menu.addItem(item("Quit Relay", key: "q", mods: [.command]) { NSApp.terminate(nil) })
        return menu
    }

    private func item(_ title: String, key: String = "", mods: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) -> NSMenuItem {
        let mi = ClosureMenuItem(title: title, action: action)
        mi.keyEquivalent = key
        mi.keyEquivalentModifierMask = mods
        return mi
    }

    private static func dot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return img
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Skip the banner when the card is already showing it.
        completionHandler(ui.cardOpen && overlay.isPillVisible ? [] : [.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["itemId"] as? String
        DispatchQueue.main.async {
            self.overlay.isPillVisible = true
            self.overlay.openCard(focus: true, itemId: id)
        }
        completionHandler()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
