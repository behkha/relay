import SwiftUI
import Combine

/// How the cloud feels. The engine works most of these out from the agents and from how much
/// attention you have been paying; the last two come from the cursor playing with it.
enum Mood: Equatable {
    /// No agents at all.
    case asleep
    /// Agents around, none of them working, nothing asked.
    case relaxed
    /// Agents working; the more of them, the livelier it gets.
    case busy
    /// An agent just asked something.
    case asking
    /// A question has been waiting a while.
    case impatient
    /// A question has waited far too long, or several are piling up.
    case angry
    /// You just answered, an agent finished, or you came back after a long time away.
    case happy
    /// Finished work is piling up and nobody has looked in a long while.
    case lonely
    /// The Mac, or one of the agents, is running hot.
    case overheated
    /// The cursor is resting on it.
    case giggly
    /// The cursor has been shaken around it.
    case dizzy

    /// Moods the cursor is allowed to play over; anything that needs you comes first.
    var isPlayful: Bool {
        switch self {
        case .asleep, .relaxed, .busy, .happy, .lonely: return true
        default: return false
        }
    }
}

/// Works out the cloud's mood from the store, the UI and the Mac's heat, and nudges you with
/// the "Agent needs you" toast when a question has been left waiting too long.
final class MoodEngine: ObservableObject {
    static let shared = MoodEngine()

    @Published private(set) var mood: Mood = .asleep
    /// Agents working right now; each one is a droplet circling the cloud.
    @Published private(set) var working = 0
    /// Questions and permission prompts waiting for you.
    @Published private(set) var waiting = 0

    /// Text for a nudge: the question has waited long enough to say something.
    let nudge = PassthroughSubject<String, Never>()

    static let impatientAfter: TimeInterval = 45
    static let angryAfter: TimeInterval = 180
    static let lonelyAfter: TimeInterval = 12 * 60
    /// While still angry, it says so again this often.
    static let nagEvery: TimeInterval = 4 * 60

    private weak var store: Store?
    private weak var ui: UIState?
    private var bag = Set<AnyCancellable>()
    private var timer: Timer?
    private var happyUntil = Date.distantPast
    private var lastAttention = Date()
    private var askedIds: Set<String> = []
    private var wasWorking: Set<String> = []
    private var lastNag = Date.distantPast

    func attach(store: Store, ui: UIState) {
        self.store = store
        self.ui = ui
        let heat = HeatMonitor.shared
        store.$items.map { _ in () }
            .merge(with: store.$sessions.map { _ in () }, store.$workspaceFilter.map { _ in () },
                   heat.$heat.map { _ in () }, heat.$thermal.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &bag)
        // Any look at Relay counts as attention.
        ui.$pillExpanded.merge(with: ui.$cardOpen, ui.$talking, ui.$sidePanel.map { $0 != nil })
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.noticed() }
            .store(in: &bag)
        // Waiting turns into impatience and anger with time alone.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    private func noticed() {
        // Back after a long time away: it's glad to see you.
        if mood == .lonely { happyUntil = Date().addingTimeInterval(3) }
        lastAttention = Date()
        update()
    }

    private func update() {
        guard let store else { return }
        let now = Date()
        let items = store.visibleItems
        let sessions = store.visibleSessions
        let asking = items.filter { $0.isActionable }

        // A question went away (answered here, in the terminal, or by the agent): relief.
        let askedNow = Set(asking.map(\.id))
        if !askedIds.subtracting(askedNow).isEmpty { happyUntil = now.addingTimeInterval(3.5) }
        askedIds = askedNow
        // An agent finished its turn.
        let workingNow = Set(sessions.filter { $0.shownStatus == .working }.map(\.id))
        let finished = wasWorking.subtracting(workingNow).filter { id in
            guard let s = store.sessions[id] else { return false }
            return s.shownStatus == .done || s.shownStatus == .idle || s.shownStatus == .ready
        }
        if !finished.isEmpty { happyUntil = max(happyUntil, now.addingTimeInterval(2.5)) }
        wasWorking = workingNow

        let oldest = asking.map(\.createdAt).min().map { now.timeIntervalSince($0) } ?? 0
        let heat = HeatMonitor.shared
        let hot = heat.macIsHot || (heat.hottest?.heat.level ?? .none) == .hot
        let unread = items.contains { !$0.isActionable }

        let next: Mood
        if !asking.isEmpty {
            if oldest > Self.angryAfter || (asking.count >= 3 && oldest > Self.impatientAfter) {
                next = .angry
            } else if oldest > Self.impatientAfter {
                next = .impatient
            } else {
                next = .asking
            }
        } else if hot {
            next = .overheated
        } else if now < happyUntil {
            next = .happy
        } else if unread && now.timeIntervalSince(lastAttention) > Self.lonelyAfter {
            next = .lonely
        } else if !workingNow.isEmpty {
            next = .busy
        } else if !sessions.isEmpty {
            next = .relaxed
        } else {
            next = .asleep
        }

        nudgeIfNeeded(from: mood, to: next, asking: asking.count, oldest: oldest, now: now)
        if next != mood { mood = next }
        if working != workingNow.count { working = workingNow.count }
        if waiting != asking.count { waiting = asking.count }
    }

    /// Says something when it gets impatient or angry, and again now and then while angry.
    private func nudgeIfNeeded(from old: Mood, to new: Mood, asking: Int, oldest: TimeInterval, now: Date) {
        guard let ui, !ui.cardOpen else { return }
        let minutes = max(1, Int(oldest / 60))
        if new == .impatient && old == .asking {
            nudge.send(asking == 1 ? "Psst… still waiting on you" : "\(asking) agents are waiting")
            lastNag = now
        } else if new == .angry && (old != .angry || now.timeIntervalSince(lastNag) > Self.nagEvery) {
            nudge.send(asking == 1 ? "Hey! It's been waiting \(minutes) min" : "Hey! \(asking) agents are stuck on you")
            lastNag = now
        }
    }
}
