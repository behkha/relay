import AppKit
import SwiftUI
import Combine

/// Borderless floating panel that can take keyboard focus without activating the app.
final class FloatingPanel: NSPanel {
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true   // the mascot's eyes follow the cursor over these too
    }
}

/// Owns the edge pill and the inbox card and keeps them positioned together.
final class OverlayController: NSObject {
    let store: Store
    let ui: UIState
    private let pill: FloatingPanel
    private let card: FloatingPanel
    private var cardHost: SizeReportingHostingView<AnyView>!
    private var bag = Set<AnyCancellable>()
    private var collapseWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private let side: FloatingPanel
    private var sideHost: SizeReportingHostingView<AnyView>!
    private let sub: FloatingPanel
    private var subHost: SizeReportingHostingView<AnyView>!
    /// "Agent needs you" and the mascot, sliding out of the pill.
    private let toast: FloatingPanel
    private let announcement = AnnounceModel()
    private var announceWork: DispatchWorkItem?

    var onVoice: ((Bool) -> Void)?          // Bool = with screenshot
    var onVoiceReply: ((InboxItem) -> Void)?
    var onHome: (() -> Void)?
    var onSettingsAction: ((SettingsAction) -> Void)?
    var onTalkTo: ((String) -> Void)?       // session id
    var phoneOn: () -> Bool = { false }

    static let collapsedWidth: CGFloat = 12
    /// Wide enough for the hover labels that appear left of the buttons (transparent there).
    static let expandedWidth: CGFloat = 200
    static let pillHeight: CGFloat = 380

    init(store: Store, ui: UIState) {
        self.store = store
        self.ui = ui
        pill = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: Self.pillHeight))
        pill.allowsKey = false
        card = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 348, height: 300))
        side = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300))
        sub = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300))
        toast = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Self.toastSize.width, height: Self.toastSize.height))
        toast.allowsKey = false
        toast.ignoresMouseEvents = true
        super.init()
        toast.contentView = NSHostingView(rootView: NeedsYouToast(model: announcement))

        let pillView = PillView(
            store: store, ui: ui,
            onInbox: { [weak self] in self?.toggleCard(focus: true) },
            onAgents: { [weak self] in self?.toggleSide(.agents) },
            onVoice: { [weak self] in self?.onVoice?(false) },
            onScreenshotVoice: { [weak self] in self?.onVoice?(true) },
            onHome: { [weak self] in self?.closeSide(); self?.onHome?() },
            onMore: { [weak self] in self?.toggleSide(.settings) })
        let pillHost = HoverHostingView(rootView: pillView)
        pillHost.onHover = { [weak self] inside in self?.setHover(inside) }
        // These windows grow leftward from the screen edge; until SwiftUI redraws after a resize,
        // keep the old frame's pixels pinned right rather than flashing them at the left.
        pillHost.layerContentsPlacement = .right
        pill.contentView = pillHost

        cardHost = SizeReportingHostingView(rootView: AnyView(
            CardView(store: store, ui: ui,
                     onClose: { [weak self] in self?.closeCard() },
                     onVoiceReply: { [weak self] item in self?.onVoiceReply?(item) })
        ))
        card.contentView = cardHost
        cardHost.layerContentsPlacement = .right
        cardHost.onFittingSizeChange = { [weak self] in self?.layoutCard() }

        sideHost = SizeReportingHostingView(rootView: AnyView(SidePanelRoot(
            store: store, ui: ui,
            phoneOn: { [weak self] in self?.phoneOn() ?? false },
            onOpenSession: { [weak self] id in
                NotificationCenter.default.post(name: .relayViewSession, object: id)
                _ = self
            },
            onTalk: { [weak self] id in self?.closeSide(); self?.onTalkTo?(id) },
            onAction: { [weak self] a in self?.settingsAction(a) })))
        side.contentView = sideHost
        sideHost.layerContentsPlacement = .right
        sideHost.onFittingSizeChange = { [weak self] in self?.layoutSide() }
        subHost = SizeReportingHostingView(rootView: AnyView(SubPanelRoot(
            store: store, ui: ui,
            onAddAccount: { [weak self] in self?.closeSide(); self?.onSettingsAction?(.workspaces) })))
        sub.contentView = subHost
        subHost.onFittingSizeChange = { [weak self] in self?.layoutSide() }

        // Card key state drives the key hints ("J", "esc", …).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: card, queue: .main) { [weak self] _ in
            self?.ui.cardIsKey = true
            self?.ui.autoOpened = false   // you're using the card now
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: card, queue: .main) { [weak self] _ in
            self?.ui.cardIsKey = false
        }
        // A click anywhere else closes the side panels.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.closeSide() }
        }

        store.$items.combineLatest(store.$sessions, store.$workspaceFilter)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.contentChanged() }
            .store(in: &bag)
        ui.$questionStep.merge(with: ui.$flashSelected.map { _ in 0 })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.layoutCard() } }
            .store(in: &bag)
        store.$toast.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutCard() }
        }.store(in: &bag)
        // A new filter: keep the shown item if it still matches, else show the filter's first one.
        store.$inboxFilter.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.ui.cardOpen else { return }
            if self.ui.pinnedItem(in: self.store) == nil { self.ui.currentItemId = self.store.filteredItems.first?.id }
            DispatchQueue.main.async { self.layoutCard() }
        }.store(in: &bag)
        store.itemArrived.receive(on: RunLoop.main).sink { [weak self] item in self?.itemArrived(item) }.store(in: &bag)
        // The mascot's mood, and its nudges when a question has been left waiting.
        MoodEngine.shared.attach(store: store, ui: ui)
        MoodEngine.shared.nudge.receive(on: RunLoop.main).sink { [weak self] text in
            guard let self, !self.ui.cardOpen, self.announcement.phase == .hidden else { return }
            self.announce(text, then: nil)
        }.store(in: &bag)
        // The pill stays open while you talk; it needs its wide frame for that.
        ui.$talking.removeDuplicates().dropFirst().receive(on: RunLoop.main).sink { [weak self] talking in
            guard let self else { return }
            self.positionPill()
            if !talking && !NSMouseInRect(NSEvent.mouseLocation, self.pill.frame, false) { self.setHover(false) }
        }.store(in: &bag)

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        installKeyMonitor()
        positionPill()
        pill.orderFrontRegardless()
    }

    var isPillVisible: Bool {
        get { UserDefaults.standard.object(forKey: "pillVisible") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "pillVisible")
            if newValue { pill.orderFrontRegardless() } else { pill.orderOut(nil); closeCard() }
        }
    }

    // MARK: Layout

    /// nil when no display is online (lid closed with the Mac kept awake); layout is skipped then.
    private var screen: NSScreen? {
        let pref = UserDefaults.standard.string(forKey: "pillScreen") ?? "main"
        if pref == "mouse" {
            let loc = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) { return s }
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Vertical position as a fraction of the screen height (0.5 = centered).
    private var verticalFraction: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "pillVertical") as? Double ?? 0.5)
    }

    @objc private func screensChanged() { positionPill(); layoutCard() }

    var pillFrame: NSRect { pill.frame }

    func positionPill() {
        let open = ui.pillExpanded || ui.cardOpen || ui.talking
        guard let rect = pillRect(expanded: open) else { return }
        shrinkWork?.cancel()
        shrinkWork = nil
        if !open && pill.frame.width > rect.width {
            // The column flows back into one piece and then into the sliver; narrow the window
            // once that has played out, so it isn't cut off halfway.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !(self.ui.pillExpanded || self.ui.cardOpen || self.ui.talking),
                      let rect = self.pillRect(expanded: false) else { return }
                self.pill.setFrame(rect, display: true)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            return
        }
        pill.setFrame(rect, display: true)
    }

    private func pillRect(expanded: Bool) -> NSRect? {
        guard let screen else { return nil }
        let vf = screen.visibleFrame
        let full = screen.frame
        let width = expanded ? Self.expandedWidth : Self.collapsedWidth
        // Collapsed, the window is only as tall as its dots so it never blocks clicks it doesn't need.
        let dots = max(1, min(store.visibleSessions.count, 8))
        let height = expanded ? Self.pillHeight : CGFloat(24 + dots * 14)
        let centerY = vf.minY + vf.height * verticalFraction
        let y = min(max(centerY - height / 2, vf.minY), vf.maxY - height)
        return NSRect(x: full.maxX - width, y: y, width: width, height: height)
    }

    /// Where the talk bar sits: level with the pill's mic (or beside the card or list when one is open).
    var talkAnchor: NSRect {
        if (ui.panelOpen && side.isVisible) || (ui.cardOpen && card.isVisible) { return anchorFrame }
        guard let pf = pillRect(expanded: true) else { return anchorFrame }
        // Mirrors PillView's expanded column: inbox, agents, then the talk group (workspaces, mic, camera), "…".
        let n = CGFloat(min(store.visibleSessions.count, 10))
        let agents: CGFloat = n > 0 ? n * 9 + (n - 1) * 7 + 20 + 7 : 0
        let column: CGFloat = 32 + 7 + agents + 91 + 7 + 32
        let micFromTop: CGFloat = 32 + 7 + agents + 5 + 27 + 13.5
        let scale = Appearance.shared.pillScale
        let micY = pf.midY + (column / 2 - micFromTop) * scale
        return NSRect(x: pf.maxX - 44 * scale, y: micY - 1, width: 44 * scale, height: 2)
    }

    // MARK: Announcement

    /// Tall enough for the mascot puffed up to its angriest.
    static let toastSize = NSSize(width: 300, height: 140)

    /// Slides "Agent needs you" out of the pill with the mascot, then runs `then` as it leaves.
    private func announce(_ text: String, then: (() -> Void)?) {
        guard isPillVisible, let screen else { then?(); return }
        announceWork?.cancel()
        let pf = pill.frame
        let size = Self.toastSize
        // Level with the pill: the capsule just above its middle, the mascot below.
        toast.setFrame(NSRect(x: screen.frame.maxX - size.width, y: pf.midY + 33 - size.height,
                              width: size.width, height: size.height), display: false)
        announcement.pillWidth = ui.pillExpanded ? 46 * Appearance.shared.pillScale : 10
        announcement.text = text
        announcement.phase = .hidden
        toast.order(.below, relativeTo: pill.windowNumber)   // the mascot comes out from behind the pill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard self?.announcement.phase == .hidden else { return }
            self?.announcement.phase = .shown
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.announcement.phase = .leaving
            then?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.announcement.phase == .leaving else { return }
                self.hideToast()
            }
        }
        announceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (then == nil ? 2.4 : 1.3), execute: work)
    }

    private func hideToast() {
        announceWork?.cancel()
        announceWork = nil
        announcement.phase = .hidden
        toast.orderOut(nil)
    }

    private func layoutCard() {
        guard ui.cardOpen else { return }
        cardHost.layoutSubtreeIfNeeded()
        let size = cardHost.fittingSize
        guard let screen else { return }
        let vf = screen.visibleFrame
        let pillFrame = pill.frame
        let pillLeft = pillFrame.maxX - 44 * Appearance.shared.pillScale
        let x = pillLeft - size.width + 12
        var y = pillFrame.midY - size.height / 2
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        card.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        settle(cardHost)
    }

    private func contentChanged() {
        if !ui.pillExpanded && !ui.cardOpen { DispatchQueue.main.async { self.positionPill() } }
        // Keep the current item valid; close when the inbox empties and the card was opened for an item.
        if ui.cardOpen {
            if ui.pinnedItem(in: store) == nil, ui.autoOpened, ui.currentItemId != nil {
                // It popped open for a question that was then answered elsewhere (the terminal, the
                // Claude app, the phone). Show the next question if one is waiting, else get out of the way.
                if let next = store.filteredItems.first(where: InboxFilter.isAsking) {
                    ui.currentItemId = next.id
                } else {
                    closeCard()
                    return
                }
            }
            if ui.pinnedItem(in: store) == nil {
                // The shown item was resolved (or none was pinned yet): pin the next one.
                // Close once the filter has nothing left, but not when it was already empty
                // (you picked a filter with nothing in it, and the card shows that).
                let hadItem = ui.currentItemId != nil
                ui.currentItemId = store.filteredItems.first?.id
                if hadItem && store.filteredItems.isEmpty && !ui.showAgentsList {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        guard let self, self.store.filteredItems.isEmpty, !self.ui.showAgentsList else { return }
                        self.closeCard()
                    }
                }
            }
        }
        DispatchQueue.main.async { self.layoutCard() }
    }

    // MARK: Hover

    func setHover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside {
            if !ui.pillExpanded {
                ui.pillExpanded = true
                positionPill()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Stay open while the mouse is over the pill or the "…" menu is up.
                if NSMouseInRect(NSEvent.mouseLocation, self.pill.frame, false) || self.ui.panelOpen { return }
                self.ui.pillExpanded = false
                self.positionPill()
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    // MARK: Card

    /// Opens the card, focuses it if it's open but not focused, or closes it.
    func toggleCard(focus: Bool) {
        if ui.cardOpen && (card.isKeyWindow || !focus) { closeCard(); return }
        openCard(focus: focus)
    }

    func openCard(focus: Bool, itemId: String? = nil) {
        guard isPillVisible else { return }
        if announcement.phase == .shown { hideToast() }
        closeSide()
        ui.autoOpened = false
        // An item the filter hides (a question while showing Done): show everything so it can appear.
        if let id = itemId, store.visibleItems.contains(where: { $0.id == id }),
           !store.filteredItems.contains(where: { $0.id == id }) {
            store.inboxFilter = .all
        }
        let requested = itemId.flatMap { id in store.filteredItems.first { $0.id == id }?.id }
        ui.currentItemId = requested ?? ui.pinnedItem(in: store)?.id ?? store.filteredItems.first?.id
        ui.showAgentsList = store.visibleItems.isEmpty
        let wasOpen = ui.cardOpen
        ui.cardOpen = true
        positionPill()
        layoutCard()
        if focus {
            if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
            NSApp.activate(ignoringOtherApps: true)
            card.orderFrontRegardless()     // even if macOS declines to activate Relay
            card.makeKey()
            card.makeFirstResponder(nil)   // no focus ring on the first button
        } else if !wasOpen {
            card.orderFrontRegardless()
        }
        DispatchQueue.main.async { self.layoutCard() }
    }

    func closeCard() {
        guard ui.cardOpen else { return }
        ui.cardOpen = false
        ui.autoOpened = false
        card.makeFirstResponder(nil)
        ui.replyFocused = false
        ui.showAgentsList = false
        card.orderOut(nil)
        positionPill()
        // Give focus back only if you didn't switch to something else meanwhile.
        if let prev = previousApp, prev != NSRunningApplication.current, NSApp.isActive {
            prev.activate(options: [])
        }
        previousApp = nil
    }

    /// A new question: "Agent needs you" slides out of the pill, then the card opens on it
    /// (unless you turned that off, or the question was answered meanwhile).
    private func itemArrived(_ item: InboxItem) {
        guard item.isActionable, !ui.cardOpen,
              store.workspaceFilter == nil || store.workspaceFilter == item.workspaceId else { return }
        let openAfter = ui.openCardWhenAsked
        announce("Agent needs you") { [weak self] in
            guard let self, openAfter, !self.ui.cardOpen,
                  self.store.items.contains(where: { $0.id == item.id }) else { return }
            self.openCard(focus: false, itemId: item.id)
            self.ui.autoOpened = true
        }
    }

    private func openSession(_ s: AgentSession) {
        NotificationCenter.default.post(name: .relayViewSession, object: s.id)
    }

    /// Where the session viewer should sit: left of the card if it's open, else left of the pill.
    var anchorFrame: NSRect {
        if ui.panelOpen && side.isVisible { return side.frame.insetBy(dx: 16, dy: 16) }
        if ui.cardOpen && card.isVisible { return card.frame.insetBy(dx: 16, dy: 16) }
        let pf = pill.frame
        return NSRect(x: pf.maxX - 44, y: pf.minY, width: 44, height: pf.height)
    }

    // MARK: Side panels (agents list, settings)

    func toggleSide(_ panel: UIState.SidePanel) {
        if ui.sidePanel == panel { closeSide(); return }
        closeCard()
        ui.subPanel = nil
        ui.sidePanel = panel
        if panel == .agents { store.refreshTitles() }
        positionPill()
        sub.orderOut(nil)
        // Measure once SwiftUI has built the new panel, so it never shows at a stale size first.
        DispatchQueue.main.async {
            guard self.ui.sidePanel == panel else { return }
            self.layoutSide()
            self.side.orderFrontRegardless()
            DispatchQueue.main.async { self.layoutSide() }
        }
    }

    func closeSide() {
        guard ui.sidePanel != nil || ui.subPanel != nil else { return }
        ui.sidePanel = nil
        ui.subPanel = nil
        side.orderOut(nil)
        sub.orderOut(nil)
        positionPill()
        if !NSMouseInRect(NSEvent.mouseLocation, pill.frame, false) { setHover(false) }
    }

    private func settingsAction(_ a: SettingsAction) {
        switch a {
        case .look, .filter:
            let want: UIState.SubPanel = a == .look ? .look : .workspaces
            if ui.subPanel == want {
                ui.subPanel = nil
                sub.orderOut(nil)
            } else {
                ui.subPanel = want
                layoutSide()
                sub.orderFrontRegardless()
                DispatchQueue.main.async { self.layoutSide() }
            }
        default:
            closeSide()
            onSettingsAction?(a)
        }
    }

    private func layoutSide() {
        guard ui.sidePanel != nil, let screen else { return }
        let vf = screen.visibleFrame
        sideHost.layoutSubtreeIfNeeded()
        let size = sideHost.fittingSize
        let pf = pill.frame
        // The pill window is wide (for hover labels); the buttons sit at its right edge.
        let pillLeft = pf.maxX - 44 * Appearance.shared.pillScale
        var y: CGFloat
        if ui.sidePanel == .settings {
            y = pf.midY - size.height + 40   // hangs from the "…" button area
        } else {
            y = pf.midY - size.height / 2
        }
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        side.setFrame(NSRect(x: pillLeft - size.width + 12, y: y, width: size.width, height: size.height), display: true)
        settle(sideHost)
        if ui.subPanel != nil {
            subHost.layoutSubtreeIfNeeded()
            let s2 = subHost.fittingSize
            var y2 = side.frame.maxY - s2.height
            y2 = min(max(y2, vf.minY + 4), vf.maxY - s2.height - 4)
            sub.setFrame(NSRect(x: side.frame.minX - s2.width + 24, y: y2, width: s2.width, height: s2.height), display: true)
            settle(subHost)
        }
    }

    /// SwiftUI can keep laying a panel out for the window's previous size after a resize (seen
    /// when the panel opens from a click: it drew at its old 1×1 size, so only a corner showed).
    /// A fresh layout pass makes it take the new size before the window is seen.
    private func settle(_ host: NSView) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.ui.cardOpen, self.card.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// Focusing a text field selects its text; put the caret after what was typed instead,
    /// so the next keystroke doesn't replace the first letter.
    private func placeCursorAtEnd() {
        for delay in [0.0, 0.03, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let tv = self?.card.firstResponder as? NSTextView else { return }
                let end = (tv.string as NSString).length
                if tv.selectedRange() != NSRange(location: end, length: 0) {
                    tv.setSelectedRange(NSRange(location: end, length: 0))
                }
            }
        }
    }

    /// Returns true when the key was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Ask the window, not a mirrored flag: the text field is the real source of truth.
        let typing = card.firstResponder is NSTextView
        if event.keyCode == 53 { // esc: undo, then leave the text field, then close
            if ui.undo() { return true }
            if typing {
                card.makeFirstResponder(nil)
                ui.replyFocused = false
            } else {
                closeCard()
            }
            return true
        }
        if typing { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // Physical keys, so shortcuts work on any keyboard layout (Persian included).
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                     83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        let code = event.keyCode
        switch code {
        case 123: ui.move(-1, store: store); return true   // ←
        case 124: ui.move(1, store: store); return true    // →
        case 38 where !shift: ui.move(-1, store: store); return true   // J
        case 40 where !shift: ui.move(1, store: store); return true    // K
        default: break
        }
        guard let item = ui.pinnedItem(in: store) else { return false }
        if let n = digits[code], !shift {
            // Swallow held-down repeats and keys pressed right after the card changed.
            if !event.isARepeat && ui.acceptsChoiceKeys {
                CardLogic.choose(n - 1, item: item, store: store, ui: ui)
            }
            return true
        }
        if event.isARepeat { return true }
        let busy = ui.commit != nil
        switch code {
        case 49: // space
            NotificationCenter.default.post(name: .relayFocusReply, object: nil)
            return true
        case 36, 76: // return
            if item.kind == .question, !ui.multiSelection.isEmpty {
                CardLogic.submitMulti(item: item, store: store, ui: ui)
            } else {
                NotificationCenter.default.post(name: .relayFocusReply, object: nil)
            }
            return true
        case 44 where shift: ui.showKeys.toggle(); return true                           // ?
        case 1 where !shift: ui.attachShot.toggle(); return true                         // S
        case 9 where !shift: onVoiceReply?(item); return true                            // V
        case 14 where !shift: CardLogic.discard(item, store: store, ui: ui); return true  // E (undoable)
        case 7 where shift:                                                              // ⇧X
            if !item.isActionable { CardLogic.kill(item, store: store, ui: ui) }
            return true
        case 31 where !shift && !busy:                                                   // O
            NotificationCenter.default.post(name: .relayViewSession, object: item.sessionId)
            return true
        case 17 where !shift && !busy:                                                   // T
            store.focusTerminal(sessionId: item.sessionId)
            return true
        default:
            break
        }
        // Any other character starts a reply instead of being lost (or triggering something).
        if !busy, let chars = event.characters, let ch = chars.first, !ch.isNewline,
           ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            ui.replyText += chars
            NotificationCenter.default.post(name: .relayFocusReply, object: nil)
            placeCursorAtEnd()
            return true
        }
        return busy   // keys during the undo countdown do nothing (esc undoes)
    }
}

/// Hosting view that reports mouse enter/exit for the whole pill window.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Hosting view that tells its owner when SwiftUI content wants a different size,
/// so the borderless card window always matches its content.
final class SizeReportingHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSizeChange: (() -> Void)?
    private var lastSize: NSSize = .zero

    override func layout() {
        super.layout()
        report()
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    private func report() {
        let size = fittingSize
        guard abs(size.width - lastSize.width) > 0.5 || abs(size.height - lastSize.height) > 0.5 else { return }
        lastSize = size
        DispatchQueue.main.async { [weak self] in self?.onFittingSizeChange?() }
    }
}

/// Hosts whichever side panel is open.
struct SidePanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    var phoneOn: () -> Bool
    var onOpenSession: (String) -> Void
    var onTalk: (String) -> Void
    var onAction: (SettingsAction) -> Void

    var body: some View {
        switch ui.sidePanel {
        case .agents:
            AgentsListView(store: store, onOpen: onOpenSession, onTalk: onTalk)
        case .settings:
            SettingsMenuView(store: store, ui: ui, phoneOn: phoneOn(), onAction: onAction)
        case nil:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

struct SubPanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    var onAddAccount: () -> Void

    var body: some View {
        switch ui.subPanel {
        case .look: LookSoundView()
        case .workspaces: WorkspaceFilterView(store: store, onAddAccount: onAddAccount)
        case nil: Color.clear.frame(width: 1, height: 1)
        }
    }
}
