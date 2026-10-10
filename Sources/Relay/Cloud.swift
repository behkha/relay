import SwiftUI
import AppKit
import Combine

// MARK: - The mascot

/// Relay's mascot: a soft, glowing cloud in a ring of liquid light. Its eyes follow the cursor,
/// and its mood follows your agents: it dozes when there are none, gets livelier with every
/// agent at work (each one a droplet circling it), puffs up and turns red when a question has
/// been left waiting, beams when you answer, and sulks when nobody has looked in a while.
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
        if followsCursor {
            CursorGaze { gaze, near, play in
                CloudFace(size: size, gaze: gaze, near: near, mood: feeling(play, near: near),
                          working: engine.working, blinks: blinks, lively: lively)
            }
        } else {
            CloudFace(size: size, gaze: CGPoint(x: glance, y: 0), near: 0, mood: engine.mood,
                      working: engine.working, blinks: blinks, lively: lively)
        }
    }

    /// The cursor can tickle it or make it dizzy, but only while nothing needs you.
    private func feeling(_ play: Mood?, near: CGFloat) -> Mood {
        let mood = engine.mood
        if let play, mood.isPlayful { return play }
        if mood == .asleep && near > 0.45 { return .relaxed }   // the cursor wakes it up
        return mood
    }
}

/// The cloud's outline: a circle with soft, slightly uneven scallops all the way round.
struct CloudShape: Shape {
    var lobes = 8

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let unit = lobes == 8 ? Self.eight : Self.unit(lobes)
        return unit.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: r, y: r))
    }

    /// The usual outline around the origin with radius 1, worked out once: the cloud is drawn
    /// many times a second.
    private static let eight = unit(8)

    private static func unit(_ lobes: Int) -> Path {
        let steps = 240
        var path = Path()
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            // Broad round lobes meeting in softer creases; a slower wave keeps them from
            // looking machine-made.
            let lobe = pow(abs(cos(Double(lobes) * t / 2 + 0.2)), 0.7)
            let bump = 0.043 * (2 * lobe - 1) + 0.012 * sin(2 * t + 1)
            let k = CGFloat(0.93 + bump)
            let p = CGPoint(x: k * CGFloat(cos(t)), y: k * CGFloat(sin(t)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

private enum Cloud {
    static let base = [Color(hex: "#7FD0FF"), Color(hex: "#B9B4FF"), Color(hex: "#F3B6EC")]
    static let sky = Color(hex: "#56BFFF")
    static let blush = Color(hex: "#F6A9E4")
    static let eye = Color(hex: "#24163A")
}

// MARK: - Expressions

private enum EyeShape: Hashable { case open, wide, sleepy, squint, angry, sad, happy, closed, dizzy }
private enum Mouth: Hashable { case none, smile, grin, frown, wobble, oh, snore, wavy }
private enum Mark: Hashable { case zzz, exclaim, sweat, steam, vein, sparkles, tear, hearts, stars, heat }

/// Everything a mood changes about the cloud.
private struct Expression {
    var eyes: EyeShape = .open
    var mouth: Mouth = .none
    var marks: [Mark] = []
    /// Overall size: it puffs up to be noticed and shrinks when it sulks.
    var scale: CGFloat = 1
    var glow = Color(hex: "#B07CFF")
    var glowStrength: Double = 0.55
    /// A wash over the skin: red when angry, grey when asleep or lonely.
    var tint = Color.clear
    var tintAmount: Double = 0
    var breathRate: Double = 0.3
    var breathDepth: CGFloat = 0.012
    /// Little hops (fraction of the size) and how often.
    var hop: CGFloat = 0
    var hopRate: Double = 1
    var shake: CGFloat = 0
    var sway: Double = 2.5
    /// A heartbeat-like swell (fraction of the size).
    var pulse: CGFloat = 0
    var pulseRate: Double = 1
    /// The liquid ring: how many droplets circle it, how fast, how far they stray, how wild.
    var drops = 2
    var dropSpeed: Double = 0.45
    var dropReach: CGFloat = 0.12
    var dropJitter: CGFloat = 0
    /// Droplets drift up and away instead of circling.
    var dropsRise = false

    init(_ mood: Mood, working: Int) {
        let n = min(working, 8)
        switch mood {
        case .asleep:
            eyes = .closed; mouth = .snore; marks = [.zzz]
            scale = 0.9; glow = Color(hex: "#8E86C9"); glowStrength = 0.35
            tint = Color(hex: "#8A8FB8"); tintAmount = 0.3
            breathRate = 0.18; breathDepth = 0.03; sway = 1
            drops = 1; dropSpeed = 0.15; dropReach = 0.06
        case .relaxed:
            eyes = .open; mouth = .none
            drops = 2; dropSpeed = 0.35
        case .busy:
            // Livelier with every agent; past five it starts to sweat.
            eyes = .open; mouth = n >= 5 ? .oh : .none; marks = n >= 6 ? [.sweat] : []
            scale = 1 + 0.02 * CGFloat(min(n, 5))
            glow = Color(hex: "#6FC8FF"); glowStrength = 0.55 + 0.04 * Double(n)
            breathRate = 0.35 + 0.08 * Double(n); sway = 2.5 + Double(n) * 0.4
            hop = n >= 4 ? 0.02 : 0; hopRate = 1.2 + 0.2 * Double(n)
            drops = max(1, n); dropSpeed = 0.6 + 0.12 * Double(n); dropReach = 0.14
        case .asking:
            eyes = .wide; mouth = .oh; marks = [.exclaim]
            scale = 1.12; glow = Color(hex: "#FFD426"); glowStrength = 0.8
            tint = Color(hex: "#FFE27A"); tintAmount = 0.12
            hop = 0.06; hopRate = 1.6; breathRate = 0.6
            pulse = 0.03; pulseRate = 1.6
            drops = 3; dropSpeed = 0.9; dropReach = 0.22
        case .impatient:
            eyes = .squint; mouth = .wobble; marks = [.sweat]
            scale = 1.2; glow = Color(hex: "#FFA53A"); glowStrength = 0.85
            tint = Color(hex: "#FFB347"); tintAmount = 0.22
            hop = 0.035; hopRate = 3.2; breathRate = 0.9; shake = 0.006
            drops = 4; dropSpeed = 1.5; dropReach = 0.2; dropJitter = 0.04
        case .angry:
            eyes = .angry; mouth = .frown; marks = [.vein, .steam]
            scale = 1.34; glow = Color(hex: "#FF4D4D"); glowStrength = 1
            tint = Color(hex: "#FF5A5A"); tintAmount = 0.5
            breathRate = 1.4; breathDepth = 0.03; shake = 0.02; sway = 0
            pulse = 0.06; pulseRate = 2.4
            drops = 7; dropSpeed = 2.6; dropReach = 0.3; dropJitter = 0.1
        case .happy:
            eyes = .happy; mouth = .grin; marks = [.sparkles]
            scale = 1.1; glow = Color(hex: "#FF9BE0"); glowStrength = 0.8
            tint = Color(hex: "#FFC2EC"); tintAmount = 0.15
            hop = 0.08; hopRate = 2.2; sway = 6
            drops = 5; dropSpeed = 1.1; dropReach = 0.2
        case .lonely:
            eyes = .sad; mouth = .frown; marks = [.tear]
            scale = 0.86; glow = Color(hex: "#7D8BC4"); glowStrength = 0.35
            tint = Color(hex: "#7F8FB8"); tintAmount = 0.32
            breathRate = 0.15; sway = 1.5
            drops = 1; dropSpeed = 0.12; dropReach = 0.04
        case .overheated:
            eyes = .sleepy; mouth = .wavy; marks = [.sweat, .heat]
            scale = 1.06; glow = Color(hex: "#FF7A3D"); glowStrength = 0.85
            tint = Color(hex: "#FF8A4D"); tintAmount = 0.35
            breathRate = 1.1; breathDepth = 0.025
            drops = 5; dropSpeed = 0.5; dropReach = 0.3; dropsRise = true
        case .giggly:
            eyes = .happy; mouth = .smile; marks = [.hearts]
            scale = 1.08; glow = Color(hex: "#FF9BE0"); glowStrength = 0.75
            tint = Color(hex: "#FFC2EC"); tintAmount = 0.12
            shake = 0.012; hop = 0.03; hopRate = 4; sway = 4
            drops = 4; dropSpeed = 1; dropReach = 0.16; dropJitter = 0.03
        case .dizzy:
            eyes = .dizzy; mouth = .wavy; marks = [.stars]
            sway = 12; breathRate = 0.8
            drops = 3; dropSpeed = 3; dropReach = 0.2
        }
    }
}

// MARK: - The face

/// Draws the cloud looking along `gaze` (each axis -1...1, y down) with the given mood.
/// `near` (0...1) is how close the cursor is: the closer, the bigger its eyes.
private struct CloudFace: View {
    var size: CGFloat
    var gaze: CGPoint
    var near: CGFloat
    var mood: Mood
    var working: Int
    var blinks: Bool
    var lively = true
    @ViewState private var blink = false
    /// Its window is hidden or covered: no point drawing frames nobody sees.
    @ViewState private var hidden = false
    /// A still cloud moving for a moment after its mood changed.
    @ViewState private var stirring = false
    @ViewState private var settle: DispatchWorkItem?

    private var e: Expression { Expression(mood, working: working) }
    private var paused: Bool { hidden || (!lively && !stirring) }

    var body: some View {
        let e = self.e
        ZStack {
            skin(e)
            face(e)
        }
        .frame(width: size, height: size)
        // The ring and the extras spill past the cloud without taking up room.
        .background(FluidRing(size: size, e: e, gaze: gaze, paused: paused))
        .overlay(Marks(size: size, marks: e.marks, paused: paused))
        .modifier(Wiggle(size: size, e: e, paused: paused))
        .scaleEffect(e.scale)
        .animation(.spring(response: 0.45, dampingFraction: 0.55), value: mood)
        .animation(.spring(response: 0.5, dampingFraction: 0.78), value: gaze)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: near)
        .background(VisibilityProbe(hidden: $hidden))
        .onChange(of: mood) { _ in stir() }
        .task {
            guard blinks else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.6...5.4) * 1e9))
                await blinkOnce()
                if Double.random(in: 0...1) < 0.2 { await blinkOnce() }   // now and then, a double blink
            }
        }
    }

    /// A still cloud shows off its new mood for a few seconds, then holds still again.
    private func stir() {
        guard !lively else { return }
        settle?.cancel()
        stirring = true
        let work = DispatchWorkItem { stirring = false; settle = nil }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    @MainActor private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.07)) { blink = true }
        try? await Task.sleep(nanoseconds: 110_000_000)
        withAnimation(.easeOut(duration: 0.14)) { blink = false }
        try? await Task.sleep(nanoseconds: 160_000_000)
    }

    // MARK: Skin

    /// Pastel light: sky blue on the left, pink at the top right, a white-hot core below the
    /// middle. The core drifts against the gaze, so the cloud seems to turn toward the cursor.
    private func skin(_ e: Expression) -> some View {
        ZStack {
            CloudShape().fill(LinearGradient(colors: Cloud.base, startPoint: .bottomLeading, endPoint: .topTrailing))
            CloudShape().fill(RadialGradient(colors: [Cloud.sky.opacity(0.9), Cloud.sky.opacity(0)],
                                             center: UnitPoint(x: 0.12, y: 0.5), startRadius: 0, endRadius: size * 0.55))
            CloudShape().fill(RadialGradient(colors: [Cloud.blush.opacity(0.85), Cloud.blush.opacity(0)],
                                             center: UnitPoint(x: 0.85, y: 0.12), startRadius: 0, endRadius: size * 0.5))
            CloudShape().fill(RadialGradient(
                colors: [Color.white, Color.white.opacity(0.55), Color.white.opacity(0)],
                center: UnitPoint(x: 0.44 - gaze.x * 0.08, y: 0.62 - gaze.y * 0.06),
                startRadius: 0, endRadius: size * 0.36))
            CloudShape().fill(e.tint).opacity(e.tintAmount)
            // A bright, soft rim.
            CloudShape()
                .stroke(Color.white.opacity(0.7), lineWidth: size * 0.05)
                .blur(radius: size * 0.035)
                .mask(CloudShape())
        }
        .compositingGroup()
    }

    // MARK: Eyes and mouth

    /// Whether the eyes still follow the cursor in this expression.
    private func tracks(_ shape: EyeShape) -> CGFloat {
        switch shape {
        case .closed, .dizzy: return 0
        case .happy, .sleepy, .sad: return 0.4
        default: return 1
        }
    }

    private func face(_ e: Expression) -> some View {
        let k = tracks(e.eyes)
        let w = size * (0.12 + 0.015 * near)
        let h = size * (0.18 + 0.02 * near)
        return VStack(spacing: size * 0.035) {
            HStack(spacing: size * 0.07) {
                eye(e.eyes, left: true, width: w, height: h)
                eye(e.eyes, left: false, width: w, height: h).offset(y: size * 0.01)
            }
            mouth(e.mouth)
                .frame(height: size * 0.08)
        }
        // At rest it looks a little to the right, like the icon; the cursor pulls its face
        // anywhere inside the cloud.
        .offset(x: size * (0.08 + gaze.x * 0.14 * k), y: size * (0.0 + gaze.y * 0.12 * k))
    }

    @ViewBuilder private func eye(_ shape: EyeShape, left: Bool, width w: CGFloat, height h: CGFloat) -> some View {
        let line = max(1, w * 0.36)
        Group {
            switch shape {
            case .open, .wide:
                let s: CGFloat = shape == .wide ? 1.18 : 1
                Ellipse().fill(Cloud.eye)
                    .overlay(Ellipse().fill(Color.white.opacity(shape == .wide ? 0.55 : 0.18))
                        .frame(width: w * 0.34 * s, height: h * 0.24 * s)
                        .offset(x: -w * 0.14, y: -h * 0.22)
                        .blur(radius: w * 0.05))
                    .frame(width: w * s, height: h * s)
                    .scaleEffect(x: 1, y: blink ? 0.1 : 1)
            case .sleepy:
                Ellipse().fill(Cloud.eye).frame(width: w, height: h)
                    .mask(cut(h: h, from: 0.5, tilt: 0))
                    .scaleEffect(x: 1, y: blink ? 0.1 : 1)
            case .squint:
                Ellipse().fill(Cloud.eye).frame(width: w * 1.1, height: h * 0.7)
                    .mask(cut(h: h * 0.7, from: 0.38, tilt: left ? 8 : -8))
            case .angry:
                // Lids slanting down toward the middle.
                Ellipse().fill(Cloud.eye).frame(width: w * 1.05, height: h)
                    .mask(cut(h: h, from: 0.36, tilt: left ? 26 : -26))
            case .sad:
                // Lids slanting down toward the outside.
                Ellipse().fill(Cloud.eye).frame(width: w, height: h * 0.9)
                    .mask(cut(h: h * 0.9, from: 0.3, tilt: left ? -22 : 22))
                    .offset(y: h * 0.08)
            case .happy:
                Arc(up: true).stroke(Cloud.eye, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: w * 1.15, height: h * 0.42)
            case .closed:
                Arc(up: false).stroke(Cloud.eye, style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round))
                    .frame(width: w * 1.15, height: h * 0.3)
            case .dizzy:
                Spiral().stroke(Cloud.eye, style: StrokeStyle(lineWidth: max(0.8, line * 0.55), lineCap: .round))
                    .frame(width: w * 1.3, height: w * 1.3)
            }
        }
        .frame(width: w * 1.4, height: h * 1.2)
        .id(shape)
        .transition(.scale(scale: 0.4).combined(with: .opacity))
    }

    /// Keeps the part of an eye below a lid line, `from` (0...1) of the way down, tilted.
    private func cut(h: CGFloat, from: CGFloat, tilt: Double) -> some View {
        Rectangle()
            .frame(width: h * 4, height: h * 2)
            .offset(y: h * (0.5 + from))
            .rotationEffect(.degrees(tilt))
    }

    @ViewBuilder private func mouth(_ mouth: Mouth) -> some View {
        let w = size * 0.11
        let line = max(0.9, size * 0.028)
        let ink = Cloud.eye.opacity(0.85)
        Group {
            switch mouth {
            case .none:
                Color.clear.frame(width: w, height: 1)
            case .smile:
                Arc(up: false).stroke(ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: w, height: w * 0.35)
            case .grin:
                HalfMoon().fill(ink).frame(width: w * 1.2, height: w * 0.6)
            case .frown:
                Arc(up: true).stroke(ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: w * 0.9, height: w * 0.3)
            case .wobble:
                Wave(waves: 2).stroke(ink, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .frame(width: w, height: w * 0.25)
            case .wavy:
                Wave(waves: 3).stroke(ink, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
                    .frame(width: w * 1.2, height: w * 0.3)
            case .oh:
                Ellipse().fill(ink).frame(width: w * 0.45, height: w * 0.55)
            case .snore:
                Ellipse().fill(ink.opacity(0.7)).frame(width: w * 0.3, height: w * 0.3)
            }
        }
        .id(mouth)
        .transition(.scale(scale: 0.3).combined(with: .opacity))
    }
}

// MARK: - Motion

/// Breathing, hopping, trembling and swaying, all on one clock.
private struct Wiggle: ViewModifier {
    var size: CGFloat
    var e: Expression
    var paused: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = CGFloat(sin(t * 2 * .pi * e.breathRate))
            let beat = CGFloat(pow(max(0, sin(t * 2 * .pi * e.pulseRate)), 6))
            let hop = CGFloat(abs(sin(t * .pi * e.hopRate)))
            let swell = 1 + e.pulse * beat
            content
                .scaleEffect(x: (1 + e.breathDepth * breath) * swell,
                             y: (1 - e.breathDepth * breath) * swell, anchor: .bottom)
                .rotationEffect(.degrees(e.sway * sin(t * 0.9)))
                .offset(x: size * e.shake * CGFloat(sin(t * 57) * cos(t * 23)),
                        y: -size * e.hop * hop + size * e.shake * CGFloat(sin(t * 41)))
        }
    }
}

/// The liquid around the cloud: a ring of droplets that bulge out of its edge, pinch off,
/// circle and flow back in, drawn as metaballs so they melt into each other like a fluid.
private struct FluidRing: View {
    var size: CGFloat
    var e: Expression
    var gaze: CGPoint
    var paused: Bool

    var body: some View {
        let side = size * 2
        ZStack {
            // A soft halo (cheap: it doesn't move), then the liquid itself.
            CloudShape().fill(e.glow)
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: size * 0.2)
                .opacity(e.glowStrength)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
                liquid(t: ctx.date.timeIntervalSinceReferenceDate, side: side)
                    .blur(radius: size * 0.018)
                    .opacity(0.4 * e.glowStrength + 0.15)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    private func liquid(t: Double, side: CGFloat) -> some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2 + gaze.x * size * 0.05, y: sz.height / 2 + gaze.y * size * 0.04)
            let core = size * 0.43
            ctx.addFilter(.alphaThreshold(min: 0.5, color: e.glow))
            ctx.addFilter(.blur(radius: max(1, size * 0.07)))
            ctx.drawLayer { l in
                func blob(_ p: CGPoint, _ r: CGFloat) {
                    l.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white))
                }
                // A wobbling core just inside the cloud's edge.
                for k in 0..<3 {
                    let a = t * (0.7 + Double(k) * 0.3) + Double(k) * 2.1
                    blob(CGPoint(x: c.x + size * 0.035 * CGFloat(cos(a)), y: c.y + size * 0.035 * CGFloat(sin(a * 1.3))), core)
                }
                for i in 0..<e.drops {
                    let phase = Double(i) / Double(max(1, e.drops))
                    let r = size * (0.085 + 0.03 * CGFloat(sin(t * 1.7 + phase * 9)))
                    let jitter = e.dropJitter * size * CGFloat(sin(t * 31 + phase * 17))
                    if e.dropsRise {
                        // Rising like heat off the top, then starting over.
                        let rise = (t * e.dropSpeed * 0.5 + phase).truncatingRemainder(dividingBy: 1)
                        let x = c.x + size * 0.32 * CGFloat(sin(phase * 2 * .pi + t * 0.6))
                        let y = c.y - core * 0.6 - size * (e.dropReach + 0.5) * CGFloat(rise)
                        blob(CGPoint(x: x + jitter, y: y), r * CGFloat(1 - rise * 0.7))
                    } else {
                        // Circling, swinging out of the edge and back in.
                        let a = t * e.dropSpeed + phase * 2 * .pi
                        let out = core + size * (0.04 + e.dropReach * CGFloat(0.5 + 0.5 * sin(t * 1.3 + phase * 7)))
                        blob(CGPoint(x: c.x + out * CGFloat(cos(a)) + jitter,
                                     y: c.y + out * CGFloat(sin(a)) - jitter), r)
                    }
                }
            }
        }
        .frame(width: side, height: side)
    }
}

/// Little extras floating around the cloud: z's, a "!", sweat, steam, sparkles, tears…
private struct Marks: View {
    var size: CGFloat
    var marks: [Mark]
    var paused: Bool

    var body: some View {
        if marks.isEmpty {
            Color.clear.frame(width: 0, height: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(marks, id: \.self) { mark in
                        draw(mark, t: t).transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
            }
            .frame(width: size, height: size)
            .allowsHitTesting(false)
        }
    }

    /// 0...1, looping every `period` seconds, offset by `shift`.
    private func loop(_ t: Double, _ period: Double, _ shift: Double = 0) -> CGFloat {
        CGFloat((t / period + shift).truncatingRemainder(dividingBy: 1))
    }

    @ViewBuilder private func draw(_ mark: Mark, t: Double) -> some View {
        let s = size
        switch mark {
        case .zzz:
            ForEach(0..<3, id: \.self) { i in
                let p = loop(t, 3, Double(i) / 3)
                Text("z").font(.system(size: s * (0.16 + 0.12 * p), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .offset(x: s * (0.36 + 0.18 * p), y: -s * (0.3 + 0.4 * p))
                    .opacity(Double(sin(p * .pi)))
            }
        case .exclaim:
            let bob = CGFloat(sin(t * 7)) * s * 0.03
            Text("!").font(.system(size: s * 0.26, weight: .black, design: .rounded))
                .foregroundStyle(Color(hex: "#3A2A00"))
                .frame(width: s * 0.3, height: s * 0.3)
                .background(Circle().fill(Color(hex: "#FFD426")))
                .shadow(color: Color(hex: "#FFD426").opacity(0.6), radius: s * 0.06)
                .offset(x: s * 0.42, y: -s * 0.42 + bob)
                .rotationEffect(.degrees(sin(t * 5) * 8))
        case .sweat:
            let p = loop(t, 1.8)
            Image(systemName: "drop.fill").font(.system(size: s * 0.17))
                .foregroundStyle(Color(hex: "#9FE0FF"))
                .offset(x: -s * 0.4, y: -s * (0.25 - 0.3 * p))
                .opacity(Double(1 - p))
        case .steam:
            ForEach(0..<4, id: \.self) { i in
                let p = loop(t, 0.9, Double(i) / 4)
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                Circle().fill(Color.white.opacity(0.75))
                    .frame(width: s * (0.08 + 0.14 * p), height: s * (0.08 + 0.14 * p))
                    .blur(radius: s * 0.02)
                    .offset(x: side * s * (0.3 + 0.12 * p), y: -s * (0.38 + 0.3 * p))
                    .opacity(Double(1 - p))
            }
        case .vein:
            let throb = 1 + 0.15 * CGFloat(max(0, sin(t * 2 * .pi * 2.4)))
            Text("💢").font(.system(size: s * 0.3))
                .scaleEffect(throb)
                .offset(x: s * 0.36, y: -s * 0.36)
        case .sparkles:
            ForEach(0..<3, id: \.self) { i in
                let tw = CGFloat(0.5 + 0.5 * sin(t * 4 + Double(i) * 2.1))
                let spots: [CGPoint] = [CGPoint(x: -0.48, y: -0.32), CGPoint(x: 0.5, y: -0.4), CGPoint(x: 0.46, y: 0.34)]
                Image(systemName: "sparkle").font(.system(size: s * (0.12 + 0.1 * tw), weight: .bold))
                    .foregroundStyle(Color(hex: "#FFF4B0"))
                    .offset(x: s * spots[i].x, y: s * spots[i].y)
                    .opacity(Double(0.3 + 0.7 * tw))
            }
        case .tear:
            let p = loop(t, 2.6)
            Image(systemName: "drop.fill").font(.system(size: s * 0.11))
                .foregroundStyle(Color(hex: "#8FD3FF"))
                .offset(x: s * 0.0, y: s * (0.05 + 0.35 * p))
                .opacity(Double(p < 0.85 ? 1 : (1 - p) / 0.15))
        case .hearts:
            ForEach(0..<2, id: \.self) { i in
                let p = loop(t, 1.6, Double(i) / 2)
                Image(systemName: "heart.fill").font(.system(size: s * (0.12 + 0.08 * p)))
                    .foregroundStyle(Color(hex: "#FF7FC4"))
                    .offset(x: s * (0.3 + 0.1 * CGFloat(sin(p * 6))) * (i == 0 ? 1 : -0.8), y: -s * (0.35 + 0.35 * p))
                    .opacity(Double(sin(p * .pi)))
            }
        case .stars:
            ForEach(0..<3, id: \.self) { i in
                let a = t * 4 + Double(i) * 2 * .pi / 3
                Image(systemName: "star.fill").font(.system(size: s * 0.12))
                    .foregroundStyle(Color(hex: "#FFE066"))
                    .offset(x: s * 0.34 * CGFloat(cos(a)), y: -s * 0.48 + s * 0.08 * CGFloat(sin(a)))
                    .opacity(sin(a) > -0.3 ? 1 : 0.5)
            }
        case .heat:
            ForEach(0..<3, id: \.self) { i in
                let p = loop(t, 1.4, Double(i) / 3)
                Wave(waves: 2).stroke(Color(hex: "#FFB27A").opacity(0.8),
                                      style: StrokeStyle(lineWidth: max(0.8, s * 0.025), lineCap: .round))
                    .frame(width: s * 0.2, height: s * 0.05)
                    .rotationEffect(.degrees(90))
                    .offset(x: s * (-0.18 + 0.18 * CGFloat(i)), y: -s * (0.5 + 0.2 * p))
                    .opacity(Double(sin(p * .pi)))
            }
        }
    }
}

// MARK: - Small shapes

/// A shallow arc: ∩ when `up`, ∪ otherwise.
private struct Arc: Shape {
    var up: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = up ? r.maxY : r.minY, y1 = up ? r.minY - r.height * 0.6 : r.maxY + r.height * 0.6
        p.move(to: CGPoint(x: r.minX, y: y0))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: y0), control: CGPoint(x: r.midX, y: y1))
        return p
    }
}

/// An open, smiling mouth: flat on top, round below.
private struct HalfMoon: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.9))
        p.closeSubpath()
        return p
    }
}

private struct Wave: Shape {
    var waves: Int

    func path(in r: CGRect) -> Path {
        var p = Path()
        let steps = 40
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let pt = CGPoint(x: r.minX + f * r.width, y: r.midY + r.height / 2 * CGFloat(sin(Double(f) * Double(waves) * 2 * .pi)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

private struct Spiral: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let steps = 60
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let a = f * 2.6 * 2 * .pi
            let k = CGFloat(f) * r.width / 2
            let pt = CGPoint(x: c.x + k * CGFloat(cos(a)), y: c.y + k * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

// MARK: - Following the cursor

/// Works out where the cursor is relative to its content and hands that over as a gaze, plus
/// a playful mood when the cursor rests on it (giggly) or is shaken around it (dizzy).
private struct CursorGaze<Content: View>: View {
    @ViewBuilder var content: (CGPoint, CGFloat, Mood?) -> Content
    @StateObject private var cursor = GazeSource()
    @ViewState private var anchor = ScreenAnchor()
    @ViewState private var play: Mood?
    @ViewState private var pending: DispatchWorkItem?
    @ViewState private var hidden = true

    var body: some View {
        let (gaze, near) = look()
        content(gaze, near, play)
            .background(ScreenProbe(anchor: anchor))
            .background(VisibilityProbe(hidden: $hidden))
            // Only a cloud on screen watches the cursor; hidden ones would redraw (and relayout
            // their windows) on every mouse move for nothing.
            .onChange(of: hidden) { h in h ? cursor.stop() : cursor.start() }
            .onDisappear { cursor.stop(); pending?.cancel() }
            .onChange(of: cursor.location) { p in react(to: p) }
    }

    private func look() -> (CGPoint, CGFloat) {
        guard !hidden, let c = anchor.center else { return (.zero, 0) }
        let p = cursor.location
        let dx = p.x - c.x, dy = c.y - p.y      // screen y points up; the face's y points down
        let d = hypot(dx, dy)
        let near = min(1, max(0, 1 - (d - 40) / 260))
        guard d > 0.5 else { return (.zero, near) }
        let reach = min(1, d / 140)               // close by, the eyes only turn a little
        return (CGPoint(x: dx / d * reach, y: dy / d * reach), near)
    }

    private func react(to p: CGPoint) {
        guard let c = anchor.center else { return }
        let now = Date()
        anchor.trail.append((now, p))
        anchor.trail.removeAll { now.timeIntervalSince($0.0) > 0.9 }
        let d = hypot(p.x - c.x, p.y - c.y)

        // Shaken: plenty of quick back-and-forth close by.
        if play != .dizzy, d < max(160, anchor.radius * 5), anchor.shakes() >= 5 {
            set(.dizzy)
            schedule(after: 2.8) { if play == .dizzy { set(nil) } }
            return
        }
        // Petted: the cursor resting on it for a moment.
        let onIt = d < max(14, anchor.radius * 1.1)
        if onIt, play == nil, pending == nil {
            schedule(after: 0.7) {
                guard let c = anchor.center, hypot(cursor.location.x - c.x, cursor.location.y - c.y) < max(14, anchor.radius * 1.1)
                else { return }
                set(.giggly)
            }
        } else if !onIt {
            if play == .giggly { set(nil) }
            if play != .dizzy { pending?.cancel(); pending = nil }
        }
    }

    private func set(_ mood: Mood?) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { play = mood }
    }

    private func schedule(after delay: Double, _ step: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { pending = nil; step() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

/// One cloud's view of the cursor: the shared position, at most 30 times a second, and only
/// between `start()` and `stop()`.
private final class GazeSource: ObservableObject {
    @Published private(set) var location = NSEvent.mouseLocation
    private var sub: AnyCancellable?

    func start() {
        guard sub == nil else { return }
        CursorTracker.shared.retain()
        location = NSEvent.mouseLocation
        sub = CursorTracker.shared.$location
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] p in self?.location = p }
    }

    func stop() {
        guard sub != nil else { return }
        sub = nil
        CursorTracker.shared.release()
    }

    deinit { stop() }
}

/// The cursor's position on screen, published as it moves, while any mascot is watching it.
final class CursorTracker: ObservableObject {
    static let shared = CursorTracker()
    @Published private(set) var location = NSEvent.mouseLocation
    private var monitors: [Any] = []
    private var watchers = 0

    func retain() {
        watchers += 1
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Mouse events (unlike keys) need no Accessibility permission to watch.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.update() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.update(); return e }) {
            monitors.append(m)
        }
        update()
    }

    func release() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func update() {
        let p = NSEvent.mouseLocation
        if p != location { location = p }
    }
}

/// Knows where a view is on screen, through a plain NSView placed behind it.
final class ScreenAnchor {
    weak var view: NSView?
    /// Where the cursor has been lately, for spotting a shake.
    var trail: [(Date, CGPoint)] = []

    var radius: CGFloat { (view?.bounds.width ?? 0) / 2 }

    /// How often the cursor reversed direction, quickly, over the recent trail.
    func shakes() -> Int {
        var turns = 0, last: CGFloat = 0, path: CGFloat = 0
        for (a, b) in zip(trail, trail.dropFirst()) {
            let dx = b.1.x - a.1.x
            path += hypot(dx, b.1.y - a.1.y)
            guard abs(dx) > 2 else { continue }
            if last != 0 && (dx > 0) != (last > 0) { turns += 1 }
            last = dx
        }
        return path > 260 ? turns : 0
    }

    var center: CGPoint? {
        guard let v = view, let w = v.window else { return nil }
        return w.convertPoint(toScreen: v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
    }
}

private struct ScreenProbe: NSViewRepresentable {
    let anchor: ScreenAnchor

    func makeNSView(context: Context) -> NSView {
        let v = ProbeView()
        anchor.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { anchor.view = v }

    /// Never takes clicks from the button it sits in.
    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Tells its view when the window it sits in is hidden or fully covered, so the cloud stops
/// animating frames nobody can see.
private struct VisibilityProbe: NSViewRepresentable {
    @Binding var hidden: Bool

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = { hidden = $0 }
        return v
    }

    func updateNSView(_ v: ProbeView, context: Context) { v.onChange = { hidden = $0 } }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var token: NSObjectProtocol?
        private var last: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { return }
            token = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: window, queue: .main) { [weak self] _ in self?.report() }
            report()
        }

        private func report() {
            let hidden = !(window?.occlusionState.contains(.visible) ?? false)
            guard hidden != last else { return }
            last = hidden
            DispatchQueue.main.async { [weak self] in self?.onChange?(hidden) }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
