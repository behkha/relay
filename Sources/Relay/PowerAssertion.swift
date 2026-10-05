import Foundation
import Combine
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while agents work or wait on you, so your phone can still reach
/// it (Settings → Phone → Keep the Mac awake while agents work). Released as soon as nothing needs it.
/// A closed lid on battery still sleeps; the phone's "can't reach the Mac" banner covers that.
final class PowerAssertion {
    static let shared = PowerAssertion()

    private var assertion: IOPMAssertionID = 0
    private(set) var isHeld = false
    private var bag = Set<AnyCancellable>()

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "keepAwake") }

    /// Follows the store from launch on.
    func start(store: Store) {
        store.$sessions.combineLatest(store.$items)
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions, items in
                self?.hold(Self.enabled && Self.needed(sessions: Array(sessions.values), items: items))
            }
            .store(in: &bag)
    }

    /// Re-checks after the setting changed.
    func refresh(store: Store = .shared) {
        hold(Self.enabled && Self.needed(sessions: Array(store.sessions.values), items: store.items))
    }

    /// An agent is working, or blocked on a question or permission prompt.
    static func needed(sessions: [AgentSession], items: [InboxItem]) -> Bool {
        sessions.contains { $0.shownStatus == .working || $0.status == .waiting } || items.contains { $0.isActionable }
    }

    func hold(_ on: Bool) {
        guard on != isHeld else { return }
        if on {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Relay: agents are working" as CFString, &id)
            guard result == kIOReturnSuccess else { return }
            assertion = id
            isHeld = true
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            isHeld = false
        }
    }
}
