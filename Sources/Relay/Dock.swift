import SwiftUI
import AppKit
import NimbiKit

/// Where the pill lives on screen (NimbiKit's `NimbiDock`).
typealias PillDock = NimbiDock

/// The notch island's measurements, taken from the screen it sits on. Shared by the island
/// view (which draws it) and the overlay (which sizes the window and hangs panels from it).
final class NotchGeometry: ObservableObject {
    /// The camera housing's width; 0 on a screen without a notch (the island then just meets in the middle).
    @Published var notchWidth: CGFloat = 0
    /// The notch's height, or the menu bar's on a screen without one.
    @Published var height: CGFloat = 32
    /// Width of the panel hanging from the island right now (0 when none is).
    @Published var attachedWidth: CGFloat = 0

    /// The pill size setting (0.8 … 1.3): everything but the notch itself grows with it.
    @Published var scale: CGFloat = 1

    /// The concave flare where the island's top meets the bezel, on each side (NimbiKit's `IslandShape`).
    static let ear: CGFloat = IslandShape.defaultEar

    /// Room on each side of the notch for the mascot (left) and the agents' dots (right): just
    /// enough for them, since the collapsed island sits over the menu bar and takes its clicks.
    var wing: CGFloat { max(height + 4, 36) * scale }
    /// Never shorter than the notch it hugs; taller when the pill is bigger than normal.
    var collapsedHeight: CGFloat { height * max(1, scale) }
    var collapsedWidth: CGFloat { notchWidth > 0 ? notchWidth + 2 * wing : 2 * wing + 8 * scale }

    var buttonSize: CGFloat { min(26, max(20, height - 6)) * scale }
    /// The button bar: the notch's height, or taller when the buttons need it.
    var barHeight: CGFloat { max(height, buttonSize + 6) }
    /// The agents' capsule in the bar: up to three dots and a "+N".
    var agentsCapsuleWidth: CGFloat { 56 * scale }
    /// The wider side of the bar (mascot, inbox and the agents' capsule) with its padding.
    private var barSide: CGFloat { 2 * buttonSize + agentsCapsuleWidth + (2 * 3 + 12 + 8) * scale }
    var minBarWidth: CGFloat { max(collapsedWidth, notchWidth + 2 * barSide) }
    /// The bar's width with a panel hanging from it: as wide as the panel.
    var barWidth: CGFloat { max(minBarWidth, attachedWidth) }

    func dashboardWidth(_ textScale: Double) -> CGFloat { max(minBarWidth, 610 * textScale * scale) }
    func dashboardContentHeight(_ textScale: Double) -> CGFloat { 128 * textScale * scale }
    func dashboardHeight(_ textScale: Double) -> CGFloat { barHeight + dashboardContentHeight(textScale) + 12 * scale }

    /// The island's size in each of its states (without the flares).
    func size(_ mode: NotchIsland.Mode, textScale: Double) -> CGSize {
        switch mode {
        case .collapsed: return CGSize(width: collapsedWidth, height: collapsedHeight)
        case .dashboard: return CGSize(width: dashboardWidth(textScale), height: dashboardHeight(textScale))
        case .attached: return CGSize(width: barWidth, height: barHeight)
        }
    }

    /// The island's black shape in a state, flares included, for a notch centred on `midX` at
    /// the top of the screen (`top`), in screen coordinates.
    func shape(_ mode: NotchIsland.Mode, textScale: Double, midX: CGFloat, top: CGFloat) -> CGRect {
        let size = size(mode, textScale: textScale)
        let width = size.width + 2 * Self.ear
        return CGRect(x: midX - width / 2, y: top - size.height, width: width, height: size.height)
    }

    /// The part of the island that takes the pointer (and its clicks) in a state. Collapsed, only
    /// the island's body: not its flares, which are mostly menu bar. Open, a little more around
    /// the dashboard, so its edge isn't a hair trigger.
    func hitRect(_ mode: NotchIsland.Mode, textScale: Double, midX: CGFloat, top: CGFloat) -> CGRect {
        let shape = shape(mode, textScale: textScale, midX: midX, top: top)
        switch mode {
        case .collapsed: return shape.insetBy(dx: Self.ear, dy: 0)
        case .dashboard: return shape.insetBy(dx: -6, dy: -8)
        case .attached: return shape
        }
    }

    func update(for screen: NSScreen, scale newScale: CGFloat) {
        if abs(newScale - scale) > 0.001 { scale = newScale }
        let (width, h) = screen.notchSize
        if abs(width - notchWidth) > 0.5 { notchWidth = width }
        if abs(h - height) > 0.5 { height = h }
    }
}

/// Right edge, left edge or notch: where the pill lives.
struct PillDockPicker: View {
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Picker("", selection: $look.preferredDock) {
            ForEach(PillDock.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Shown under the dock picker while another nimbi app has the notch Relay wants
/// (DESIGN.md 18.2): who has it, where the pill is meanwhile, and the switch back.
struct NotchOwnerNote: View {
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        if let owner = look.notchTakenBy {
            HStack(spacing: 8) {
                Text("Notch is used by \(Self.appName(owner)). The pill waits at the right edge.")
                    .font(look.font(11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Use for Relay") { look.takeNotch() }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}
