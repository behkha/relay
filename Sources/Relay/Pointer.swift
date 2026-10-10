import SwiftUI
import AppKit
import Combine

/// Where the pointer is over one of Relay's floating windows, in that window's SwiftUI
/// coordinates (nil when it's elsewhere).
///
/// SwiftUI's `onHover` only fires while the app is active, and Relay almost never is: the pill
/// and the island live in non-activating panels over other apps. Their hosting view feeds this
/// from an always-active tracking area instead, and `pointerHover` reads it.
final class PointerTracker: ObservableObject {
    @Published var location: CGPoint?
}

private struct PointerTrackerKey: EnvironmentKey {
    static let defaultValue: PointerTracker? = nil
}

extension EnvironmentValues {
    var pointerTracker: PointerTracker? {
        get { self[PointerTrackerKey.self] }
        set { self[PointerTrackerKey.self] = newValue }
    }
}

/// Hover that works whether or not Relay is the active app. Falls back to `onHover` in
/// windows that don't track the pointer themselves.
private struct PointerHover: ViewModifier {
    var action: (Bool) -> Void
    @Environment(\.pointerTracker) private var tracker
    @ViewState private var frame: CGRect = .zero
    @ViewState private var inside = false

    func body(content: Content) -> some View {
        if let tracker {
            content
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { frame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { frame = $0 }
                })
                .onReceive(tracker.$location.removeDuplicates()) { update($0) }
                .onChange(of: frame) { _ in update(tracker.location) }
                .onDisappear { if inside { inside = false; action(false) } }
        } else {
            content.onHover(perform: action)
        }
    }

    private func update(_ location: CGPoint?) {
        let now = location.map { frame.contains($0) } ?? false
        guard now != inside else { return }
        inside = now
        action(now)
    }
}

extension View {
    /// Like `onHover`, but also while Relay isn't the active app (see PointerTracker).
    func pointerHover(perform action: @escaping (Bool) -> Void) -> some View {
        modifier(PointerHover(action: action))
    }
}
