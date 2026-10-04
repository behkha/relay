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
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private let side: FloatingPanel
    private var sideHost: SizeReportingHostingView<AnyView>!
    private let sub: FloatingPanel
    private var subHost: SizeReportingHostingView<AnyView>!

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
        super.init()

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
        pill.contentView = pillHost

        cardHost = SizeReportingHostingView(rootView: AnyView(
            CardView(store: store, ui: ui,
                     onClose: { [weak self] in self?.closeCard() },
                     onVoiceReply: { [weak self] item in self?.onVoiceReply?(item) })
        ))
        card.contentView = cardHost
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
        sideHost.onFittingSizeChange = { [weak self] in self?.layoutSide() }
        subHost = SizeReportingHostingView(rootView: AnyView(SubPanelRoot(
            store: store, ui: ui,
            onAddAccount: { [weak self] in self?.closeSide(); self?.onSettingsAction?(.workspaces) })))
        sub.contentView = subHost
        subHost.onFittingSizeChange = { [weak self] in self?.layoutSide() }

        // Card key state drives the key hints ("J", "esc", …).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: card, queue: .main) { [weak self] _ in
            self?.ui.cardIsKey = true
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
        store.itemArrived.receive(on: RunLoop.main).sink { [weak self] item in self?.itemArrived(item) }.store(in: &bag)

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

    func positionPill() {
        guard let screen else { return }
        let vf = screen.visibleFrame
        let full = screen.frame
        let expanded = ui.pillExpanded || ui.cardOpen
        let width = expanded ? Self.expandedWidth : Self.collapsedWidth
        // Collapsed, the window is only as tall as its dots so it never blocks clicks it doesn't need.
        let dots = max(1, min(store.visibleSessions.count, 8))
        let height = expanded ? Self.pillHeight : CGFloat(20 + dots * 14)
        let centerY = vf.minY + vf.height * verticalFraction
        let y = min(max(centerY - height / 2, vf.minY), vf.maxY - height)
        pill.setFrame(NSRect(x: full.maxX - width, y: y, width: width, height: height), display: true)
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
    }

    private func contentChanged() {
        if !ui.pillExpanded && !ui.cardOpen { DispatchQueue.main.async { self.positionPill() } }
        // Keep the current item valid; close when the inbox empties and the card was opened for an item.
        if ui.cardOpen {
            if ui.pinnedItem(in: store) == nil {
                // The shown item was resolved (or none was pinned yet): pin the next one.
                ui.currentItemId = store.visibleItems.first?.id
                if store.visibleItems.isEmpty && !ui.showAgentsList {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        guard let self, self.store.visibleItems.isEmpty, !self.ui.showAgentsList else { return }
                        self.closeCard()
                    }
                }
            }
        }
        DispatchQueue.main.async { self.layoutCard() }
    }

    // MARK: Hover

    private func setHover(_ inside: Bool) {
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.positionPill() }
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
        closeSide()
        let requested = itemId.flatMap { id in store.visibleItems.first { $0.id == id }?.id }
        ui.currentItemId = requested ?? ui.pinnedItem(in: store)?.id ?? store.visibleItems.first?.id
        ui.showAgentsList = store.visibleItems.isEmpty
        let wasOpen = ui.cardOpen
        ui.cardOpen = true
        positionPill()
        layoutCard()
        if focus {
            if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
            NSApp.activate(ignoringOtherApps: true)
            card.makeKeyAndOrderFront(nil)
            card.makeFirstResponder(nil)   // no focus ring on the first button
        } else if !wasOpen {
            card.orderFrontRegardless()
        }
        DispatchQueue.main.async { self.layoutCard() }
    }

    func closeCard() {
        guard ui.cardOpen else { return }
        ui.cardOpen = false
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

    private func itemArrived(_ item: InboxItem) {
        guard ui.openCardWhenAsked, item.isActionable,
              store.workspaceFilter == nil || store.workspaceFilter == item.workspaceId else { return }
        if !ui.cardOpen {
            ui.currentItemId = item.id
            openCard(focus: false)
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
        layoutSide()
        side.orderFrontRegardless()
        sub.orderOut(nil)
        DispatchQueue.main.async { self.layoutSide() }
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
        if ui.subPanel != nil {
            subHost.layoutSubtreeIfNeeded()
            let s2 = subHost.fittingSize
            var y2 = side.frame.maxY - s2.height
            y2 = min(max(y2, vf.minY + 4), vf.maxY - s2.height - 4)
            sub.setFrame(NSRect(x: side.frame.minX - s2.width + 24, y: y2, width: s2.width, height: s2.height), display: true)
        }
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
