import SwiftUI
import AppKit

/// Where the pill lives on screen.
enum PillDock: String, CaseIterable, Identifiable {
    case right, left, notch
    var id: String { rawValue }

    var title: String {
        switch self {
        case .right: return "Right"
        case .left: return "Left"
        case .notch: return "Notch"
        }
    }

    /// The point panels grow out of: the screen edge the pill sits on, or the top at the notch.
    var growAnchor: UnitPoint {
        switch self {
        case .right: return .trailing
        case .left: return .leading
        case .notch: return .top
        }
    }

    var isEdge: Bool { self != .notch }
}

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

    /// The concave flare where the island's top meets the bezel, on each side.
    static let ear: CGFloat = 7

    /// Room on each side of the notch for the mascot (left) and the agents' dots (right).
    var wing: CGFloat { max(height + 12, 42) * scale }
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

    func update(for screen: NSScreen, scale newScale: CGFloat) {
        if abs(newScale - scale) > 0.001 { scale = newScale }
        let (width, h) = screen.notchSize
        if abs(width - notchWidth) > 0.5 { notchWidth = width }
        if abs(h - height) > 0.5 { height = h }
    }
}

extension NSScreen {
    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// The camera housing's width and height in points, or (0, menu bar height) without one.
    var notchSize: (CGFloat, CGFloat) {
        if hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return (max(0, frame.width - left.width - right.width), safeAreaInsets.top)
        }
        let menuBar = frame.maxY - visibleFrame.maxY
        return (0, menuBar > 10 ? menuBar : 24)
    }

    /// The middle of the camera housing (the screen's middle without one).
    var notchMidX: CGFloat {
        if hasNotch, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return frame.minX + left.width + (frame.width - left.width - right.width) / 2
        }
        return frame.midX
    }
}

/// The notch island: flat along the top of the screen, flaring into the bezel at both top
/// corners and rounded below, like the camera housing it grows out of. `rect` includes the
/// flares (`ear` on each side).
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = NotchGeometry.ear

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + ear, right = rect.maxX - ear
        let e = min(ear, rect.height / 2)
        let r = max(0, min(bottomRadius, (right - left) / 2, rect.height - e))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + e), control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: rect.maxY), control: CGPoint(x: left, y: rect.maxY))
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: right, y: rect.maxY - r), control: CGPoint(x: right, y: rect.maxY))
        p.addLine(to: CGPoint(x: right, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// A panel hanging from the island: square on top (where it meets the island), rounded below.
struct IslandBody: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.closeSubpath()
        return p
    }
}

private struct HangsFromPillKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The panel opens out of the pill (the card, the agents list, the settings menu). At the
    /// notch those hang from the island and drop their top corners.
    var hangsFromPill: Bool {
        get { self[HangsFromPillKey.self] }
        set { self[HangsFromPillKey.self] = newValue }
    }
}

/// Right edge, left edge or notch: where the pill lives.
struct PillDockPicker: View {
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        Picker("", selection: $look.dock) {
            ForEach(PillDock.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}
