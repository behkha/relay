import Foundation
import Combine
import AppKit

/// View state shared by the pill, the card and the hotkeys.
final class UIState: ObservableObject {
    static let shared = UIState()

    @Published var cardOpen = false
    /// The agents list or the settings menu next to the pill.
    enum SidePanel: Equatable { case agents, settings }
    enum SubPanel: Equatable { case look, workspaces }
    @Published var sidePanel: SidePanel?
    @Published var subPanel: SubPanel?
    var panelOpen: Bool { sidePanel != nil }
    /// The item the card shows. Pinned: it only changes when you move, or when it is resolved.
    @Published var currentItemId: String? {
        didSet {
            guard oldValue != currentItemId else { return }
            // Moving to another card commits the pending answer of the one you left;
            // its countdown must never be undone (or lost) from a different card.
            if let c = commit, c.itemId != currentItemId { flushCommit() }
            displayChangedAt = Date()
            resetItemState()
        }
    }
    /// When the displayed item last changed; choice keys are ignored briefly after, so a key
    /// meant for one request can never land on the next one.
    private(set) var displayChangedAt = Date.distantPast
    @Published var pillExpanded = false
    @Published var replyFocused = false
    /// Per-item answers being built for multi-question / multi-select cards.
    @Published var questionStep = 0
    @Published var multiSelection: Set<Int> = []
    @Published var collected: [String: String] = [:]
    /// Selected option shown with a check right before the card advances.
    @Published var flashSelected: Int?
    @Published var replyText = ""
    /// The card has keyboard focus (shows key hints like One does).
    @Published var cardIsKey = false
    /// Attach a screenshot to the next reply sent from the card.
    @Published var attachShot = false
    /// When the card was opened from the menu with nothing to show.
    @Published var showAgentsList = false

    // MARK: Undo window

    /// An action that runs after a short countdown, unless you press esc ("esc to undo").
    struct Commit: Identifiable {
        enum Kind { case sent, discarded, killed }
        let id = UUID()
        let itemId: String
        let label: String
        let kind: Kind
        let duration: Double
        let started = Date()
        let action: () -> Void
        /// What the card looked like before, restored by undo (draft text, question step…).
        let snapshot: Snapshot
    }

    struct Snapshot {
        var questionStep: Int
        var multiSelection: Set<Int>
        var collected: [String: String]
        var replyText: String
        var attachShot: Bool
    }

    @Published private(set) var commit: Commit?

    func schedule(itemId: String, label: String, kind: Commit.Kind = .sent, duration: Double = 2.0,
                  action: @escaping () -> Void) {
        flushCommit()
        let snap = Snapshot(questionStep: questionStep, multiSelection: multiSelection, collected: collected,
                            replyText: draftBeforeSend ?? replyText, attachShot: attachShot)
        draftBeforeSend = nil
        let c = Commit(itemId: itemId, label: label, kind: kind, duration: duration, action: action, snapshot: snap)
        commit = c
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.commit?.id == c.id else { return }
            self.commit = nil
            c.action()
            // Only clear the card's state if it still shows the item that was answered.
            if self.currentItemId == c.itemId || self.currentItemId == nil { self.resetItemState() }
        }
    }

    /// Cancels the pending action. Returns false when there was nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let c = commit else { return false }
        commit = nil
        flashSelected = nil
        if currentItemId == c.itemId {
            questionStep = c.snapshot.questionStep
            multiSelection = c.snapshot.multiSelection
            collected = c.snapshot.collected
            replyText = c.snapshot.replyText
            attachShot = c.snapshot.attachShot
        }
        return true
    }

    /// Set by a send just before it clears the field, so undo can put the text back.
    var draftBeforeSend: String?

    /// Runs the pending action right away (before moving on to something else).
    func flushCommit() {
        guard let c = commit else { return }
        commit = nil
        c.action()
    }

    var openCardWhenAsked: Bool {
        get { UserDefaults.standard.object(forKey: "openCardWhenAsked") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openCardWhenAsked") }
    }

    func resetItemState() {
        questionStep = 0
        multiSelection = []
        collected = [:]
        flashSelected = nil
        replyText = ""
        attachShot = false
    }

    /// The pinned item, if it is still in the inbox.
    func pinnedItem(in store: Store) -> InboxItem? {
        guard let id = currentItemId else { return nil }
        return store.visibleItems.first { $0.id == id }
    }

    var acceptsChoiceKeys: Bool {
        Date().timeIntervalSince(displayChangedAt) > 0.45 && flashSelected == nil && commit == nil
    }

    /// The item the card shows, falling back to the first visible one.
    func currentItem(in store: Store) -> InboxItem? {
        let items = store.visibleItems
        if let id = currentItemId, let it = items.first(where: { $0.id == id }) { return it }
        return items.first
    }

    func move(_ delta: Int, store: Store) {
        // Pick the neighbour first: committing may remove the current card from the list.
        let items = store.visibleItems
        guard !items.isEmpty else { return }
        let cur = items.firstIndex { $0.id == currentItem(in: store)?.id } ?? 0
        let next = (cur + delta + items.count) % items.count
        let target = items[next].id
        flushCommit()
        currentItemId = store.visibleItems.contains { $0.id == target } ? target : store.visibleItems.first?.id
    }
}
