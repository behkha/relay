import SwiftUI

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
                .pillChrome(Capsule())
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
                // Comes out of the pill: from under it, small and see-through, to full size.
                .scaleEffect(shown ? 1 : (leaving ? 0.55 : 0.4), anchor: .trailing)
                .offset(x: shown ? 0 : 34)
                .opacity(shown ? 1 : 0)
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.8), value: model.phase)
                .padding(.trailing, pillWidth + 5)
                .padding(.top, 8)

            Mascot(size: 40, glance: shown ? -1 : 0, followsCursor: false)
                // Peeks out from behind the pill's top, then drops below the toast with a bounce.
                .scaleEffect(shown ? 1 : 0.5)
                .offset(x: shown ? -(pillWidth + 4) : 8, y: shown ? 50 : 0)
                .opacity(model.phase == .hidden ? 0 : (leaving ? 0 : 1))
                .animation(leaving ? .easeIn(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.56).delay(0.06),
                           value: model.phase)
        }
        .frame(width: 300, height: 140, alignment: .topTrailing)
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

/// The expanded pill's chrome. On macOS 26 and later it is Liquid Glass, smoked dark so the
/// white glyphs stay legible on any wallpaper; pieces that share a glass container blend and
/// morph into each other by `id`. Earlier systems get a flat dark fill under a thin rim.
struct PillChrome<S: Shape>: ViewModifier {
    var shape: S
    var active = false
    var id: String?
    var namespace: Namespace.ID?
    /// Off while pieces overlap as one, so their smoke doesn't stack into darker bands.
    var smoke = true

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            glass(content)
        } else {
            content
                .background(shape.fill(Color(hex: active ? "#2C2C2E" : "#111112")))
                .overlay(shape.stroke(Color.white.opacity(active ? 0.24 : 0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.32), radius: 5, y: 2)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder private func glass(_ content: Content) -> some View {
        // A black tint barely darkens glass; smoke laid under it does, and keeps the glass's edge light.
        let glassy = content
            .background(shape.fill(Color.black.opacity(smoke ? (active ? 0.22 : 0.48) : 0)))
            .glassEffect(.regular, in: shape)
        if let id, let namespace {
            glassy.glassEffectID(id, in: namespace)
        } else {
            glassy
        }
    }
}

extension View {
    func pillChrome<S: Shape>(_ shape: S, active: Bool = false, id: String? = nil, in namespace: Namespace.ID? = nil,
                              smoke: Bool = true) -> some View {
        modifier(PillChrome(shape: shape, active: active, id: id, namespace: namespace, smoke: smoke))
    }

    /// Lets the pill's glass pieces melt into each other as they move (macOS 26+).
    @ViewBuilder func glassGroup(spacing: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
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
