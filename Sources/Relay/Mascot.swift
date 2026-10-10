import SwiftUI
import NimbiKit

// MARK: - The mascot

/// Relay's mascot: the nimbi cloud, with its mood following your agents. It dozes when there
/// are none, gets livelier with every agent at work (each one a droplet circling it), puffs up
/// and turns red when a question has been left waiting, beams when you answer, and sulks when
/// nobody has looked in a while.
struct Mascot: View {
    var size: CGFloat = 32
    /// -1 looks left, 1 looks right. Only used when it does not follow the cursor.
    var glance: CGFloat = 0
    var blinks = true
    var followsCursor = true
    /// Breathes and swirls all the time. When false it holds still (blinks aside) and only stirs
    /// for a moment when its mood changes: for a cloud that is always on screen.
    var lively = true
    @ObservedObject private var engine = MoodEngine.shared

    var body: some View {
        NimbiCloud(size: size, mood: engine.mood, working: engine.working, glance: glance, blinks: blinks,
                   followsCursor: followsCursor, lively: lively)
    }
}

// MARK: - "Agent needs you"

/// Drives the toast that slides out of the pill when an agent asks something.
final class AnnounceModel: ObservableObject {
    enum Phase { case hidden, shown, leaving }
    @Published var phase: Phase = .hidden
    @Published var text = "Agent needs you"
    /// Room on the right for the pill (the window reaches the screen edge, under the pill).
    @Published var pillWidth: CGFloat = 10
}

/// A black capsule slides out of the pill while the mascot drops out from behind it.
struct NeedsYouToast: View {
    @ObservedObject var model: AnnounceModel
    @ObservedObject private var look = Appearance.shared

    private var pillWidth: CGFloat { model.pillWidth }
    private var shown: Bool { model.phase == .shown }
    private var leaving: Bool { model.phase == .leaving }

    /// Which way it slides: away from the edge the pill is on, or down out of the notch.
    private var dock: PillDock { look.dock }
    /// Toward the middle of the screen: -1 from the right edge, 1 from the left, 0 down from the notch.
    private var away: CGFloat { dock == .right ? -1 : (dock == .left ? 1 : 0) }
    private var alignment: Alignment {
        switch dock {
        case .right: return .topTrailing
        case .left: return .topLeading
        case .notch: return .top
        }
    }

    var body: some View {
        ZStack(alignment: alignment) {
            Text(model.text)
                .font(look.font(14.5))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 15).padding(.vertical, 8.5)
                .modifier(ToastChrome(notch: dock == .notch))
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                // Comes out of the pill: from under it, small and see-through, to full size.
                .scaleEffect(shown ? 1 : (leaving ? 0.55 : 0.4), anchor: dock.growAnchor)
                .offset(x: shown ? 0 : -34 * away, y: shown || dock != .notch ? 0 : -24)
                .opacity(shown ? 1 : 0)
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8), value: model.phase)
                .padding(dock == .left ? .leading : .trailing, dock == .notch ? 0 : pillWidth + 5)
                .padding(.top, 8)

            Mascot(size: 40, glance: shown ? away : 0, followsCursor: false)
                // Peeks out from behind the pill's top, then drops below the toast with a bounce.
                .scaleEffect(shown ? 1 : 0.5)
                .offset(x: shown ? (pillWidth + 4) * away : -8 * away, y: shown ? 50 : 0)
                .opacity(model.phase == .hidden ? 0 : (leaving ? 0 : 1))
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.56).delay(0.06),
                           value: model.phase)
        }
        .frame(width: 300, height: 140, alignment: alignment)
    }
}

/// The toast's capsule: the pill's glass on an edge; at the notch, black like the island it drops from.
private struct ToastChrome: ViewModifier {
    var notch: Bool

    func body(content: Content) -> some View {
        if notch {
            content
                .background(Capsule().fill(Color.black))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75))
        } else {
            content.pillChrome(Capsule())
        }
    }
}
