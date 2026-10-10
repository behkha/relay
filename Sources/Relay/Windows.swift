import AppKit
import SwiftUI
import Combine
import NimbiKit

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

    /// The notch island sits in the menu bar; don't let AppKit push it down below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the edge pill and the inbox card and keeps them positioned together.
final class OverlayController: NSObject {
    let store: Store
    let ui: UIState
    /// Replaced on leaving the notch (see replacePill), so always read through `self`.
    private var pill: FloatingPanel
    /// The island has set `ignoresMouseEvents` on the pill's window. Once that has been set at
    /// all, AppKit no longer lets clicks through the window's transparent parts by itself.
    private var pillHitTestingSet = false
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
    /// The island's measurements when the pill lives at the notch.
    let notch = NotchGeometry()
    /// The pointer over the pill's window, for hover while Relay isn't the active app.
    private let pointer = PointerTracker()
    private var pillHost: HoverHostingView<AnyView>!
    private var pointerPoll: Timer?
    /// Opens the island once the pointer has rested on it for a moment (updateIslandHitTesting).
    private var dwellWork: DispatchWorkItem?
    private var islandWatch: Timer?
    private var outsideTicks = 0
    /// How long a panel takes to roll back up into the island before its window goes.
    static let rollUp: Double = 0.3
    private var look: Appearance { Appearance.shared }
    private var dock: PillDock { look.dock }

    var onVoice: ((Bool) -> Void)?          // Bool = with screenshot
    var onVoiceReply: ((InboxItem) -> Void)?
    var onHome: (() -> Void)?
    var onSettingsAction: ((SettingsAction) -> Void)?
    var onTalkTo: ((String) -> Void)?       // session id
    var phoneOn: () -> Bool = { false }

    static let collapsedWidth: CGFloat = 12
    static let pillHeight: CGFloat = 380

    /// The open pill's window on an edge: wide enough for the hover labels that appear beside the
    /// buttons (transparent there). That is the buttons' strip (7 of padding, the button), the
    /// gap to the label, and the longest label at the text size (HoverTip.maxTextWidth).
    static func expandedWidth(pillScale k: CGFloat, textScale: Double) -> CGFloat {
        let label = HoverTip.maxTextWidth * CGFloat(textScale) + 2 * HoverTip.padding
        return max(200, 46 * k + 156, (8 + HoverTip.gap) * k + label + 4).rounded(.up)
    }

    init(store: Store, ui: UIState) {
        self.store = store
        self.ui = ui
        pill = Self.makePill()
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
            onMore: { [weak self] in self?.toggleSide(.settings) },
            notch: notch)
        pillHost = HoverHostingView(rootView: AnyView(pillView.environment(\.pointerTracker, pointer)))
        pillHost.tracker = pointer
        pillHost.onHover = { [weak self] inside in
            guard let self else { return }
            // At the notch, opening waits for the pointer to rest on the island.
            if inside && self.dock == .notch { self.updateIslandHitTesting() } else { self.setHover(inside) }
        }
        // Moving onto the island inside a window still held open after it closed.
        pillHost.onMove = { [weak self] in self?.updateIslandHitTesting() }
        // At the notch the pointer only counts as over the island, not its bigger window, so
        // the view and updateIslandHitTesting agree on where it is.
        pillHost.activeArea = { [weak self] in
            guard let self, self.dock == .notch else { return nil }
            return self.islandHitRect
        }
        pill.contentView = pillHost

        cardHost = SizeReportingHostingView(rootView: AnyView(
            CardView(store: store, ui: ui,
                     onClose: { [weak self] in self?.closeCard() },
                     onVoiceReply: { [weak self] item in self?.onVoiceReply?(item) })
                .environment(\.hangsFromPill, true)
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
            onAction: { [weak self] a in self?.settingsAction(a) })
                .environment(\.hangsFromPill, true)))
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
            self?.ui.autoOpened = false   // you're using the card now
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: card, queue: .main) { [weak self] _ in
            self?.ui.cardIsKey = false
        }
        // A click anywhere else closes the side panels.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeSide()
                self?.clickedOutside()
            }
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

        // Moving the pill to another edge or the notch: put everything away and start over there.
        Appearance.shared.$dock.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.dockChanged() }
        }.store(in: &bag)
        // Resizing the pill (or its text) resizes its window, and moves what hangs from it.
        Appearance.shared.$textScale.dropFirst().merge(with: Appearance.shared.$pillScale.dropFirst())
            .receive(on: RunLoop.main).sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateNotch()
                    self.positionPill()
                    self.layoutCard()
                    self.layoutSide()
                }
            }.store(in: &bag)

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        installKeyMonitor()
        applyDock()
        positionPill()
        pill.orderFrontRegardless()
    }

    private func dockChanged() {
        closeCard()
        closeSide()
        hideToast()
        ui.pillExpanded = false
        let replaced = dock != .notch && pillHitTestingSet
        if replaced { replacePill() }
        applyDock()
        shrinkWork?.cancel()
        shrinkWork = nil
        if let rect = pillRect(expanded: false) { pill.setFrame(rect, display: true) }
        if replaced && isPillVisible { pill.orderFrontRegardless() }
        updateIslandHitTesting()
    }

    private static func makePill() -> FloatingPanel {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: pillHeight))
        p.allowsKey = false
        return p
    }

    /// On an edge the open pill's window is mostly transparent (room for the hover labels), and
    /// clicks there must reach the app underneath, which AppKit does by itself only for a window
    /// whose `ignoresMouseEvents` was never set. The island sets it, and setting it back to false
    /// makes the whole window take clicks, so leaving the notch moves the pill into a new window.
    private func replacePill() {
        let old = pill
        old.contentView = nil
        old.orderOut(nil)
        pill = Self.makePill()
        pill.contentView = pillHost
        pillHitTestingSet = false
    }

    /// Window levels and resize pinning for where the pill lives.
    private func applyDock() {
        // These windows grow out of the pill; until SwiftUI redraws after a resize, keep the old
        // frame's pixels pinned to that side rather than flashing them at the other.
        let placement: NSView.LayerContentsPlacement
        switch dock {
        case .right: placement = .right
        case .left: placement = .left
        case .notch: placement = .top
        }
        pill.contentView?.layerContentsPlacement = placement
        cardHost.layerContentsPlacement = placement
        sideHost.layerContentsPlacement = placement
        // At the notch the island sits over the panels hanging from it, hiding the seam.
        pill.level = dock == .notch ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .statusBar
        // The island reads the pointer on the controller's timer; the edge pill on its own.
        pillHost.pollsPointer = dock != .notch
        updateNotch()
        pollPointer()
    }

    /// At the notch: where the pointer is decides whether the island takes clicks (and opens
    /// it). Polled rather than taken from mouse events: the island window ignores the mouse
    /// while the pointer is elsewhere, and a global monitor misses moves into Relay's windows
    /// (the card under the island, say). Only at the notch and while the pill is on screen;
    /// quick near the island, slower elsewhere, where it only has to notice the pointer coming.
    private func pollPointer() {
        pointerPoll?.invalidate()
        pointerPoll = nil
        guard dock == .notch, isPillVisible else {
            dwellWork?.cancel()
            dwellWork = nil
            return
        }
        let near = NSMouseInRect(NSEvent.mouseLocation, pill.frame.insetBy(dx: -60, dy: -60), false)
        let timer = Timer(timeInterval: near ? 1.0 / 30 : 0.1, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.updateIslandHitTesting()
            self.pollPointer()
        }
        timer.tolerance = near ? 0.005 : 0.03
        RunLoop.main.add(timer, forMode: .common)
        pointerPoll = timer
    }

    /// Takes the notch's measurements from the screen (and the pill size setting).
    private func updateNotch() {
        guard let screen else { return }
        notch.update(for: screen, scale: CGFloat(look.pillScale))
        if abs(look.notchPanelMinWidth - notch.minBarWidth) > 0.5 { look.notchPanelMinWidth = notch.minBarWidth }
    }

    var isPillVisible: Bool {
        get { UserDefaults.standard.object(forKey: "pillVisible") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "pillVisible")
            if newValue { pill.orderFrontRegardless() } else { pill.orderOut(nil); closeCard() }
            pollPointer()
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
        // At the notch: the screen that has one (the built-in display), if any is connected.
        if dock == .notch, let s = NSScreen.screens.first(where: { $0.hasNotch }) { return s }
        return NSScreen.screens.first ?? NSScreen.main
    }

    /// Vertical position as a fraction of the screen height (0.5 = centered).
    private var verticalFraction: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "pillVertical") as? Double ?? 0.5)
    }

    @objc private func screensChanged() {
        updateNotch()
        positionPill(); layoutCard(); layoutSide()
    }

    var pillFrame: NSRect { pill.frame }

    /// The buttons' strip of the pill window (it's wider, for the hover labels beside them).
    private var pillButtons: NSRect {
        let pf = pill.frame
        let w = 44 * look.pillScale
        return NSRect(x: dock == .left ? pf.minX : pf.maxX - w, y: pf.minY, width: w, height: pf.height)
    }

    func positionPill() {
        if dock == .notch { positionIsland(); return }
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
        if dock == .notch { return islandRect(expanded ? islandMode : .collapsed) }
        guard let screen else { return nil }
        let vf = screen.visibleFrame
        let full = screen.frame
        // Sized for the pill at its size setting (its views are scaled from the screen edge).
        let scale = CGFloat(look.pillScale)
        let width = expanded ? Self.expandedWidth(pillScale: scale, textScale: look.textScale) : Self.collapsedWidth * scale
        // Collapsed, the window is only as tall as its dots so it never blocks clicks it doesn't need.
        let dots = max(1, min(store.visibleSessions.count, 8))
        let height = (expanded ? Self.pillHeight : CGFloat(24 + dots * 14)) * scale
        let centerY = vf.minY + vf.height * verticalFraction
        let y = min(max(centerY - height / 2, vf.minY), vf.maxY - height)
        let x = dock == .left ? full.minX : full.maxX - width
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: Notch island

    /// Mirrors NotchIsland.mode.
    private var islandMode: NotchIsland.Mode {
        if ui.cardOpen || ui.panelOpen || ui.talking { return .attached }
        return ui.pillExpanded ? .dashboard : .collapsed
    }

    /// The island itself (its black shape, flares included) in a state, in screen coordinates.
    private func islandShape(_ mode: NotchIsland.Mode) -> NSRect? {
        guard let screen else { return nil }
        return notch.shape(mode, textScale: look.textScale, midX: screen.notchMidX, top: screen.frame.maxY)
    }

    /// The island's window: one fixed rectangle under the notch, big enough for the island's
    /// largest state plus its shadow and button labels. It never resizes when the island changes
    /// state (resizing a window under a running SwiftUI animation makes the content jump), and
    /// it lets clicks through everywhere but the island itself (`updateIslandHitTesting`).
    private func islandRect(_ mode: NotchIsland.Mode = .dashboard) -> NSRect? {
        updateNotch()
        guard let screen else { return nil }
        let dash = notch.size(.dashboard, textScale: look.textScale)
        let width = max(dash.width, notch.barWidth) + 2 * NotchGeometry.ear + 48
        let height = dash.height + 44
        return NSRect(x: screen.notchMidX - width / 2, y: screen.frame.maxY - height, width: width, height: height).integral
    }

    /// The bottom edge of the island's button bar (what panels hang from), in screen coordinates.
    private var islandBottom: CGFloat {
        (screen?.frame.maxY ?? pill.frame.maxY) - notch.barHeight
    }

    private func positionIsland() {
        shrinkWork?.cancel()
        shrinkWork = nil
        watchIsland()
        guard let rect = islandRect() else { return }
        if pill.frame != rect { pill.setFrame(rect, display: true) }
        updateIslandHitTesting()
    }

    /// The part of the island window that takes the pointer: the island in its current state
    /// (see NotchGeometry.hitRect).
    private var islandHitRect: NSRect {
        guard let screen else { return .zero }
        return notch.hitRect(islandMode, textScale: look.textScale, midX: screen.notchMidX, top: screen.frame.maxY)
    }

    /// How long the pointer has to rest on the collapsed island before it opens, so passing
    /// over it on the way to the menu bar doesn't drop the dashboard over everything.
    static let islandDwell: Double = 0.2

    /// Lets clicks fall through the island window except over the island, and opens the island
    /// once the pointer has stayed on it for `islandDwell`. Runs on the pointer poll and on
    /// moves over the island's view.
    private func updateIslandHitTesting() {
        guard dock == .notch else {
            // Never set on an edge (see replacePill).
            dwellWork?.cancel()
            dwellWork = nil
            return
        }
        let inside = NSMouseInRect(NSEvent.mouseLocation, islandHitRect, false)
        if !pillHitTestingSet || pill.ignoresMouseEvents == inside {
            pill.ignoresMouseEvents = !inside
            pillHitTestingSet = true
        }
        pillHost.refreshPointer()
        guard inside, !ui.pillExpanded else {
            // Left before the dwell was up (or it's open already): start over next time.
            dwellWork?.cancel()
            dwellWork = nil
            return
        }
        guard dwellWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWork = nil
            guard self.dock == .notch, !self.ui.pillExpanded,
                  NSMouseInRect(NSEvent.mouseLocation, self.islandHitRect, false) else { return }
            self.setHover(true)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.islandDwell, execute: work)
    }

    /// While the dashboard is open, checks where the pointer is: once it has left the island
    /// (not just its window, which is bigger), the island closes. Hover tracking alone misses
    /// exits while the window is being resized under the pointer.
    private func watchIsland() {
        let open = dock == .notch && ui.pillExpanded && islandMode == .dashboard
        guard open else {
            islandWatch?.invalidate()
            islandWatch = nil
            return
        }
        guard islandWatch == nil else { return }
        outsideTicks = 0
        islandWatch = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.dock == .notch, self.ui.pillExpanded, self.islandMode == .dashboard,
                  let shape = self.islandShape(.dashboard) else {
                self.islandWatch?.invalidate()
                self.islandWatch = nil
                return
            }
            if NSMouseInRect(NSEvent.mouseLocation, shape.insetBy(dx: -8, dy: -10), false) {
                self.outsideTicks = 0
            } else {
                self.outsideTicks += 1
                if self.outsideTicks >= 3 { self.collapseIsland() }
            }
        }
    }

    /// Puts the island back around the notch: closes the dashboard and the side panels hanging
    /// from it. An open card stays, as it does on an edge (it may be a question that opened by
    /// itself), with the island kept as the bar it hangs from; so does the talk bar (it closes
    /// itself when it's done).
    private func collapseIsland() {
        islandWatch?.invalidate()
        islandWatch = nil
        collapseWork?.cancel()
        dwellWork?.cancel()
        dwellWork = nil
        closeSide()
        guard ui.pillExpanded, !ui.talking else { return }
        ui.pillExpanded = false
        positionPill()
    }

    /// A click in another app: at the notch, the dashboard and side panels fold back into the
    /// island (the card stays, see collapseIsland).
    private func clickedOutside() {
        guard dock == .notch else { return }
        collapseIsland()
    }

    /// Before a screenshot: at the notch, the dashboard folds back into the island, so it
    /// isn't what comes back once the shot is taken (Relay's windows are hidden for the shot
    /// itself, see Screenshot.captureHidingRelay).
    func prepareForScreenshot() {
        guard dock == .notch else { return }
        collapseIsland()
    }

    /// The width of the panel hanging from the island; the bar matches it.
    private func setAttachedWidth(_ width: CGFloat) {
        guard dock == .notch, abs(notch.attachedWidth - width) > 0.5 else { return }
        notch.attachedWidth = width
        positionPill()
    }

    /// Where the talk bar sits: level with the pill's mic (or beside the card or list when one is open).
    var talkAnchor: NSRect {
        if (ui.panelOpen && side.isVisible) || (ui.cardOpen && card.isVisible) { return anchorFrame }
        if dock == .notch {
            // Under the island's bar.
            guard let screen else { return anchorFrame }
            let w = notch.barWidth
            return NSRect(x: screen.notchMidX - w / 2, y: islandBottom - 2, width: w, height: 2)
        }
        guard let pf = pillRect(expanded: true) else { return anchorFrame }
        // Mirrors PillView's expanded column: inbox, agents, then the talk group (workspaces, mic, camera), "…".
        let n = CGFloat(min(store.visibleSessions.count, 10))
        let agents: CGFloat = n > 0 ? n * 9 + (n - 1) * 7 + 20 + 7 : 0
        let column: CGFloat = 32 + 7 + agents + 91 + 7 + 32
        let micFromTop: CGFloat = 32 + 7 + agents + 5 + 27 + 13.5
        let scale = look.pillScale
        let micY = pf.midY + (column / 2 - micFromTop) * scale
        let x = dock == .left ? pf.minX : pf.maxX - 44 * scale
        return NSRect(x: x, y: micY - 1, width: 44 * scale, height: 2)
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
        let frame: NSRect
        switch dock {
        case .right, .left:
            // Level with the pill: the capsule just above its middle, the mascot below.
            let x = dock == .left ? screen.frame.minX : screen.frame.maxX - size.width
            frame = NSRect(x: x, y: pf.midY + 33 - size.height, width: size.width, height: size.height)
        case .notch:
            // Dropping out of the island.
            frame = NSRect(x: screen.notchMidX - size.width / 2, y: islandBottom + 2 - size.height,
                           width: size.width, height: size.height)
        }
        toast.setFrame(frame, display: false)
        announcement.pillWidth = ui.pillExpanded ? 46 * look.pillScale : 10
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

    /// Where a panel that opens out of the pill goes (the card, the agents list, the settings menu):
    /// beside the pill's buttons on an edge, hanging from the island at the notch. `size` is the
    /// window's, which includes the panel's shadow margin (16 around, 8 more below).
    private func hangingFrame(size: NSSize, hangFromTop: CGFloat? = nil) -> NSRect? {
        guard let screen else { return nil }
        let vf = screen.visibleFrame
        if dock == .notch {
            let y = max(islandBottom + 16 - size.height, vf.minY + 4)
            return NSRect(x: (screen.notchMidX - size.width / 2).rounded(), y: y, width: size.width, height: size.height)
        }
        let buttons = pillButtons
        let x = dock == .left ? buttons.maxX - 12 : buttons.minX - size.width + 12
        var y = hangFromTop.map { $0 - size.height } ?? buttons.midY - size.height / 2
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func layoutCard() {
        guard ui.cardOpen else { return }
        cardHost.layoutSubtreeIfNeeded()
        let size = cardHost.fittingSize
        guard let frame = hangingFrame(size: size) else { return }
        card.setFrame(frame, display: true)
        settle(cardHost)
        setAttachedWidth(size.width - 32)
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
        if inside, dock == .notch, !ui.pillExpanded {
            // The window can be bigger than the island for a moment (while it shrinks back);
            // only the island itself opens it.
            guard let shape = islandShape(.collapsed),
                  NSMouseInRect(NSEvent.mouseLocation, shape.insetBy(dx: -2, dy: -2), false) else { return }
        }
        collapseWork?.cancel()
        if inside {
            if !ui.pillExpanded {
                ui.pillExpanded = true
                positionPill()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Stay open while the mouse is over the pill (at the notch: the island, not its
                // bigger window) or the "…" menu is up.
                let over = self.dock == .notch ? (self.islandShape(self.islandMode)?.insetBy(dx: -8, dy: -10) ?? .zero)
                                               : self.pill.frame
                if NSMouseInRect(NSEvent.mouseLocation, over, false) || self.ui.panelOpen { return }
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
        closeSide(forCard: true)
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
        hideHanging(card) { [weak self] in self?.ui.cardOpen == false }
        if ui.sidePanel == nil { notch.attachedWidth = 0 }
        positionPill()
        // Give focus back only if you didn't switch to something else meanwhile.
        if let prev = previousApp, prev != NSRunningApplication.current, NSApp.isActive {
            prev.activate(options: [])
        }
        previousApp = nil
    }

    /// Hides a panel that hangs from the pill. At the notch it first rolls back up into the
    /// island (PanelEntrance), so its window goes once that has played out, if it's still closed.
    private func hideHanging(_ window: NSWindow, ifStillClosed closed: @escaping () -> Bool) {
        guard dock == .notch else { window.orderOut(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rollUp + 0.05) {
            if closed() { window.orderOut(nil) }
        }
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

    /// Where the session viewer should sit: beside the card if it's open, else beside the pill
    /// (or the notch island).
    var anchorFrame: NSRect {
        if ui.panelOpen && side.isVisible { return side.frame.insetBy(dx: 16, dy: 16) }
        if ui.cardOpen && card.isVisible { return card.frame.insetBy(dx: 16, dy: 16) }
        if dock == .notch, let screen {
            let w = notch.collapsedWidth
            let top = screen.frame.maxY
            return NSRect(x: screen.notchMidX - w / 2, y: top - notch.collapsedHeight, width: w, height: notch.collapsedHeight)
        }
        return pillButtons
    }

    // MARK: Side panels (agents list, settings)

    func toggleSide(_ panel: UIState.SidePanel) {
        if ui.sidePanel == panel { closeSide(); return }
        // Set first, so the island stays a bar (and keeps its width) while the card goes.
        ui.subPanel = nil
        ui.sidePanel = panel
        closeCard()
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

    /// `forCard`: the card is about to open in its place, so the island keeps its bar.
    func closeSide(forCard: Bool = false) {
        guard ui.sidePanel != nil || ui.subPanel != nil else { return }
        ui.sidePanel = nil
        ui.subPanel = nil
        hideHanging(side) { [weak self] in self?.ui.sidePanel == nil }
        sub.orderOut(nil)
        if !ui.cardOpen && !forCard { notch.attachedWidth = 0 }
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
        // The settings menu hangs from the "…" button area.
        let top: CGFloat? = ui.sidePanel == .settings ? pill.frame.midY + 40 : nil
        guard let frame = hangingFrame(size: size, hangFromTop: top) else { return }
        side.setFrame(frame, display: true)
        settle(sideHost)
        setAttachedWidth(size.width - 32)
        if ui.subPanel != nil {
            subHost.layoutSubtreeIfNeeded()
            let s2 = subHost.fittingSize
            // Beside the menu, on the side away from the pill's edge (at the notch: to the right,
            // a little lower, unless there's no room there).
            var y2 = side.frame.maxY - s2.height - (dock == .notch ? 10 : 0)
            y2 = min(max(y2, vf.minY + 4), vf.maxY - s2.height - 4)
            var x2: CGFloat
            switch dock {
            case .right: x2 = side.frame.minX - s2.width + 24
            case .left: x2 = side.frame.maxX - 24
            case .notch:
                x2 = side.frame.maxX - 24
                if x2 + s2.width > vf.maxX { x2 = side.frame.minX - s2.width + 24 }
            }
            sub.setFrame(NSRect(x: x2, y: y2, width: s2.width, height: s2.height), display: true)
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
    var onMove: (() -> Void)?
    /// Fed with the pointer's position while it's over this view (see PointerTracker).
    var tracker: PointerTracker?
    /// Where the pointer counts as over this view, in screen coordinates; nil for all of it.
    /// (At the notch: the island, not its bigger window.)
    var activeArea: (() -> NSRect?)?
    /// Whether this view reads the pointer on its own timer while it's inside. Off when its
    /// owner already does (the notch island, on OverlayController's poll).
    var pollsPointer = true {
        didSet { if !pollsPointer { poll?.invalidate(); poll = nil } }
    }
    private var area: NSTrackingArea?
    /// Mouse-moved events don't always come (a pointer that jumps, the window resizing under
    /// it), so while the pointer is inside, its position is also read on a timer.
    private var poll: Timer?

    /// Reads where the pointer is now (nil outside `activeArea`), and publishes it if it moved.
    func refreshPointer() {
        guard let window else { return }
        var location: CGPoint?
        if activeArea?().map({ NSMouseInRect(NSEvent.mouseLocation, $0, false) }) ?? true {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(p) { location = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y) }
        }
        setPointer(location)
    }

    private func setPointer(_ location: CGPoint?) {
        guard let tracker, tracker.location != location else { return }
        tracker.location = location
    }

    private func startPolling() {
        guard pollsPointer, poll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.refreshPointer()
            if !NSMouseInRect(NSEvent.mouseLocation, window.frame, false) { self.stopPolling() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
        setPointer(nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        refreshPointer()
        startPolling()
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        stopPolling()
        onHover?(false)
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        refreshPointer()
        startPolling()
        onMove?()
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

    @ObservedObject private var look = Appearance.shared
    /// At the notch, the panel stays on show while it rolls back up into the island.
    @ViewState private var leaving: UIState.SidePanel?

    private var panel: UIState.SidePanel? { ui.sidePanel ?? (look.dock == .notch ? leaving : nil) }

    var body: some View {
        // Switching between the list and the menu blurs one into the other.
        ZStack(alignment: .top) {
            Group {
                switch panel {
                case .agents:
                    AgentsListView(store: store, onOpen: onOpenSession, onTalk: onTalk)
                case .settings:
                    SettingsMenuView(store: store, ui: ui, phoneOn: phoneOn(), onAction: onAction)
                case nil:
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .id(panel)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: panel)
        .modifier(PanelEntrance(open: ui.sidePanel != nil))
        .onChange(of: ui.sidePanel) { new in
            guard new == nil else { leaving = new; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + OverlayController.rollUp) {
                if ui.sidePanel == nil { leaving = nil }
            }
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
