import SwiftUI

// MARK: - The mascot

/// Relay's speech bubble with eyes (the app icon), as one outline so it can be filled or stroked.
struct MascotShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let bh = rect.height * 0.8             // the bubble; the tail hangs below it
        let r = bh * 0.42
        let x0 = rect.minX, y0 = rect.minY
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: y0))
        p.addArc(tangent1End: CGPoint(x: x0 + w, y: y0), tangent2End: CGPoint(x: x0 + w, y: y0 + bh), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0 + w, y: y0 + bh), tangent2End: CGPoint(x: x0, y: y0 + bh), radius: r)
        // The tail leaves the bottom edge and points down-left.
        p.addLine(to: CGPoint(x: x0 + r + w * 0.2, y: y0 + bh))
        p.addLine(to: CGPoint(x: x0 + r * 0.3, y: y0 + rect.height))
        p.addLine(to: CGPoint(x: x0 + r, y: y0 + bh))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0 + bh), tangent2End: CGPoint(x: x0, y: y0), radius: r)
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0 + w, y: y0), radius: r)
        p.closeSubpath()
        return p
    }
}

/// The mascot. It blinks now and then and can glance sideways.
struct Mascot: View {
    enum Style { case dark, light, outline }
    var style: Style = .dark
    var size: CGFloat = 32
    /// -1 looks left, 1 looks right.
    var glance: CGFloat = 0
    var blinks = true
    @ViewState private var blink = false

    private var height: CGFloat { size * 0.92 }
    private var body_: Color {
        switch style {
        case .dark: return Color(hex: "#151515")
        case .light: return .white
        case .outline: return .clear
        }
    }
    private var eyes: Color {
        switch style {
        case .dark: return .white
        case .light: return Color(hex: "#151515")
        case .outline: return .white
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            MascotShape().fill(body_)
            if style == .outline {
                MascotShape().stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: max(1.2, size * 0.085), lineJoin: .round))
            } else if style == .dark {
                // A light rim keeps it visible on dark backgrounds too.
                MascotShape().stroke(Color.white.opacity(0.22), lineWidth: max(0.75, size * 0.03))
            }
            HStack(spacing: size * 0.13) {
                eye
                eye
            }
            .offset(x: glance * size * 0.06)
            .frame(height: height * 0.8)
        }
        .frame(width: size, height: height)
        .task {
            guard blinks else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.4...4.6) * 1e9))
                withAnimation(.easeIn(duration: 0.07)) { blink = true }
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.easeOut(duration: 0.1)) { blink = false }
            }
        }
    }

    private var eye: some View {
        Capsule()
            .fill(eyes)
            .frame(width: size * 0.12, height: height * 0.3)
            .scaleEffect(x: 1, y: blink ? 0.12 : 1)
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(model.text)
                .font(look.font(14.5))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 15).padding(.vertical, 8.5)
                .background(Capsule().fill(Color(hex: "#0F0F0F")))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                // Comes out of the pill: from under it, small and see-through, to full size.
                .scaleEffect(shown ? 1 : (leaving ? 0.55 : 0.4), anchor: .trailing)
                .offset(x: shown ? 0 : 34)
                .opacity(shown ? 1 : 0)
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8), value: model.phase)
                .padding(.trailing, pillWidth + 5)
                .padding(.top, 8)

            Mascot(style: .dark, size: 40, glance: shown ? -1 : 0)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                // Peeks out from behind the pill's top, then drops below the toast with a bounce.
                .scaleEffect(shown ? 1 : 0.5)
                .offset(x: shown ? -(pillWidth + 4) : 8, y: shown ? 50 : 0)
                .opacity(model.phase == .hidden ? 0 : (leaving ? 0 : 1))
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.56).delay(0.06),
                           value: model.phase)
        }
        .frame(width: 300, height: 110, alignment: .topTrailing)
    }
}

// MARK: - Pill pieces

/// The collapsed pill: a tab rounded on its left that flares into the screen edge at both ends,
/// so it reads as part of the edge rather than a chip floating next to it.
struct EdgeTab: Shape {
    var radius: CGFloat = 5
    var flare: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.height / 4)
        let top = rect.minY + f, bottom = rect.maxY - f
        let r = min(radius, (bottom - top) / 2, rect.width - f)
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: top), tangent2End: CGPoint(x: rect.minX, y: top), radius: f)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: top), tangent2End: CGPoint(x: rect.minX, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: bottom), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: f)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// The glossy black chrome of the expanded pill's buttons: a dark gradient under a bright rim.
struct PillChrome<S: InsettableShape>: ViewModifier {
    var shape: S
    var active = false

    func body(content: Content) -> some View {
        content
            .background(
                shape.fill(LinearGradient(colors: active ? [Color(hex: "#4A4A4D"), Color(hex: "#232325")]
                                                         : [Color(hex: "#3A3A3C"), Color(hex: "#131314"), Color(hex: "#050505")],
                                          startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.14), Color.white.opacity(0.32)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
    }
}

extension View {
    func pillChrome<S: InsettableShape>(_ shape: S, active: Bool = false) -> some View {
        modifier(PillChrome(shape: shape, active: active))
    }
}

/// Red level bars that replace the mic while it listens.
struct ListeningBars: View {
    var color: Color = Color(hex: "#FF4F5E")
    var height: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: height * 0.16) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (5.5 + Double(i) * 1.3) + Double(i) * 1.7
                    let level = 0.35 + 0.65 * abs(sin(phase) * cos(phase * 0.37))
                    Capsule()
                        .fill(color)
                        .frame(width: height * 0.17, height: max(height * 0.22, height * level))
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - Status changes

/// Pops a status glyph when its status changes (an agent finished, or started asking),
/// the way One's dots swell for a moment.
struct StatusPop<V: Equatable>: ViewModifier {
    var value: V
    var strength: CGFloat = 1.5
    /// Only pop for changes this returns true for.
    var when: (V) -> Bool = { _ in true }
    @ViewState private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: value) { v in
                guard when(v) else { return }
                scale = 0.35
                withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { scale = strength }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { scale = 1 }
                }
            }
    }
}

extension View {
    func popOnChange<V: Equatable>(of value: V, strength: CGFloat = 1.5, when: @escaping (V) -> Bool = { _ in true }) -> some View {
        modifier(StatusPop(value: value, strength: strength, when: when))
    }
}
