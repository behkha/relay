import Foundation
import SwiftUI
import Combine
import NimbiKit

// MARK: - Model

enum HeatLevel: Int, Comparable {
    case none, warm, hot

    static func < (a: HeatLevel, b: HeatLevel) -> Bool { a.rawValue < b.rawValue }
}

struct SessionHeat: Equatable {
    /// Smoothed CPU use of the agent and everything it started, in Activity Monitor percent (100 = one core).
    var cpu: Double
    var level: HeatLevel

    var cpuLabel: String { "\(Int(cpu.rounded()))% CPU" }
}

/// Finds the agents that make the Mac run hot.
///
/// Every few seconds it samples the CPU time of each agent's whole process tree (the claude process
/// plus the builds, tests and servers it started), including children that already exited, and
/// combines that with macOS's thermal state. An agent that keeps several cores busy, or the biggest
/// consumer while the Mac reports it is getting hot, is flagged.
final class HeatMonitor: ObservableObject {
    static let shared = HeatMonitor()

    /// By session id; only sessions that use measurable CPU are present.
    @Published private(set) var heat: [String: SessionHeat] = [:]
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    static let interval: TimeInterval = 2.5
    // Thresholds with hysteresis, so a flag doesn't flicker on and off around one value.
    private static let hotOn = 200.0, hotOff = 140.0
    private static let warmOn = 90.0, warmOff = 60.0

    private let queue = DispatchQueue(label: "relay.heat", qos: .utility)
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()

    // Sampler state, touched only on `queue`.
    private struct Sample { var own: UInt64; var child: UInt64; var session: String? }
    private var previous: [pid_t: Sample] = [:]
    private var lastSampleAt: Date?
    private var smoothed: [String: Double] = [:]
    private var levels: [String: HeatLevel] = [:]
    private let nanosPerTick: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    private init() {
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.thermal = ProcessInfo.processInfo.thermalState }
            .store(in: &bag)
    }

    /// Demo mode: mock readings instead of sampling real processes.
    func injectDemo(_ values: [String: SessionHeat]) { heat = values }

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The agent heating the Mac the most, if any is flagged.
    var hottest: (id: String, heat: SessionHeat)? {
        heat.filter { $0.value.level == .hot }.max { $0.value.cpu < $1.value.cpu }.map { ($0.key, $0.value) }
    }

    var macIsHot: Bool { thermal == .serious || thermal == .critical }

    private func tick() {
        var roots: [pid_t: String] = [:]
        for s in Store.shared.sessions.values where s.status != .ended {
            if let pid = s.pid, pid > 0 { roots[pid] = s.id }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.sample(roots: roots, thermal: thermal)
            DispatchQueue.main.async { self.publish(result) }
        }
    }

    private func publish(_ result: (heat: [String: SessionHeat], newlyHot: [String])) {
        if result.heat != heat { heat = result.heat }
        thermal = ProcessInfo.processInfo.thermalState
        for id in result.newlyHot {
            guard let s = Store.shared.sessions[id], let h = result.heat[id] else { continue }
            Store.shared.showToast("@\(s.handle) is heating up your Mac · \(h.cpuLabel)")
            PushDispatcher.shared.agentOnFire(id, cpu: h.cpuLabel)
        }
    }

    // MARK: Sampling (on `queue`)

    private func sample(roots: [pid_t: String], thermal: ProcessInfo.ThermalState)
        -> (heat: [String: SessionHeat], newlyHot: [String]) {
        let now = Date()
        let elapsed = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        let firstRun = lastSampleAt == nil
        lastSampleAt = now

        // Every process with its parent, and which agent's tree it belongs to.
        let procs = Self.listProcesses()
        var parent: [pid_t: pid_t] = [:]
        var started: [pid_t: Double] = [:]
        for p in procs { parent[p.pid] = p.ppid; started[p.pid] = p.start }
        var owner: [pid_t: String?] = [:]
        func session(of pid: pid_t) -> String? {
            var chain: [pid_t] = []
            var cur = pid
            var found: String?
            while cur > 1, chain.count < 64 {
                if let known = owner[cur] { found = known; break }
                if let s = roots[cur] { found = s; break }
                chain.append(cur)
                guard let up = parent[cur], up != cur else { break }
                cur = up
            }
            for p in chain { owner[p] = found }
            return found
        }

        var used: [String: Double] = [:]   // CPU nanoseconds this interval, by session
        var next: [pid_t: Sample] = [:]
        let windowStart = now.timeIntervalSince1970 - elapsed - 0.5
        for p in procs {
            guard let sid = session(of: p.pid), let t = cpuTime(p.pid) else { continue }
            let cur = Sample(own: t.own, child: t.child, session: sid)
            next[p.pid] = cur
            if let prev = previous[p.pid] {
                used[sid, default: 0] += Double(cur.own &- min(prev.own, cur.own))
                used[sid, default: 0] += Double(cur.child &- min(prev.child, cur.child))
            } else if !firstRun, (started[p.pid] ?? 0) >= windowStart {
                // Started during this interval: all of its time is new.
                used[sid, default: 0] += Double(cur.own + cur.child)
            }
        }
        // A process that exited moves its whole lifetime into its parent's child counter;
        // take back the part already counted while it ran.
        for (pid, prev) in previous where next[pid] == nil {
            guard let sid = prev.session else { continue }
            used[sid, default: 0] -= Double(prev.own + prev.child)
        }
        previous = next

        guard !firstRun, elapsed > 0.5 else { return ([:], []) }

        // Smooth over a few samples so a one-second spike doesn't flag an agent.
        let alpha = 0.4
        var cpu: [String: Double] = [:]
        for sid in Set(roots.values) {
            let pct = max(0, (used[sid] ?? 0) * nanosPerTick / (elapsed * 1e9) * 100)
            let s = (smoothed[sid] ?? pct) * (1 - alpha) + pct * alpha
            smoothed[sid] = s
            cpu[sid] = s
        }
        smoothed = smoothed.filter { cpu[$0.key] != nil }

        let top = cpu.max { $0.value < $1.value }
        var heat: [String: SessionHeat] = [:]
        var newlyHot: [String] = []
        for (sid, c) in cpu {
            let prev = levels[sid] ?? .none
            var level: HeatLevel
            switch prev {
            case .hot: level = c >= Self.hotOff ? .hot : (c >= Self.warmOff ? .warm : .none)
            case .warm: level = c >= Self.hotOn ? .hot : (c >= Self.warmOff ? .warm : .none)
            case .none: level = c >= Self.hotOn ? .hot : (c >= Self.warmOn ? .warm : .none)
            }
            // When macOS itself says the Mac is hot, the biggest consumer is the likely cause.
            if sid == top?.key {
                if thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, c >= 40 { level = .hot }
                else if thermal == .fair, c >= 60 { level = max(level, .warm) }
            }
            levels[sid] = level
            if level == .hot && prev != .hot { newlyHot.append(sid) }
            if c >= 1 || level != .none { heat[sid] = SessionHeat(cpu: c, level: level) }
        }
        levels = levels.filter { cpu[$0.key] != nil }
        return (heat, newlyHot)
    }

    private struct ProcInfo { var pid: pid_t; var ppid: pid_t; var start: Double }

    private static func listProcesses() -> [ProcInfo] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        guard n > 0 else { return [] }
        var out: [ProcInfo] = []
        out.reserveCapacity(n)
        for pid in pids.prefix(min(n, pids.count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            out.append(ProcInfo(pid: pid, ppid: pid_t(info.pbi_ppid),
                                start: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6))
        }
        return out
    }

    /// The process's own CPU time and that of its exited (reaped) children, in mach ticks.
    private func cpuTime(_ pid: pid_t) -> (own: UInt64, child: UInt64)? {
        var ri = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &ri) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard ok == 0 else { return nil }
        return (ri.ri_user_time + ri.ri_system_time, ri.ri_child_user_time + ri.ri_child_system_time)
    }
}

// MARK: - Fire

enum Fire {
    static let core = Nimbi.Heat.core
    static let yellow = Nimbi.Heat.yellow
    static let orange = Nimbi.Heat.orange
    static let red = Nimbi.Heat.red
    static let ember = Nimbi.Heat.ember
    static let coal = Nimbi.Heat.coal

    static let gradient = LinearGradient(colors: [yellow, orange, red], startPoint: .top, endPoint: .bottom)
    static let ring = AngularGradient(colors: [yellow, orange, red, orange, yellow], center: .center)
}

/// Flames licking up around a round avatar of `size`. Drawn behind it; larger than its frame.
struct FlameAura: View {
    var size: CGFloat
    /// 0…1: warm is a low ember glow, hot is full fire.
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            Canvas { g, canvas in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let cx = canvas.width / 2
                // The orb's center in this canvas (the canvas is shifted up by `lift`).
                let cy = canvas.height / 2 + Self.lift * size
                let rise = size * (0.45 + 0.85 * intensity)
                let hot = intensity > 0.6

                // Glow around the orb that breathes.
                let breathe = 0.85 + 0.15 * sin(t * 2.3)
                let glowR = size * (0.68 + 0.14 * intensity) * breathe
                g.fill(Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)),
                       with: .radialGradient(Gradient(colors: [(hot ? Fire.orange : Fire.red).opacity(0.6 * intensity + 0.15), Fire.red.opacity(0)]),
                                             center: CGPoint(x: cx, y: cy), startRadius: size * 0.3, endRadius: glowR))

                g.drawLayer { layer in
                    layer.addFilter(.blur(radius: size * 0.05))
                    layer.blendMode = .plusLighter
                    let count = hot ? 26 : 10
                    for i in 0..<count {
                        let seed = Double(i)
                        let life = 0.75 + Self.rand(seed * 1.7) * 0.6
                        let phase = (t / life + Self.rand(seed * 3.1)).truncatingRemainder(dividingBy: 1)
                        // Born along the orb's upper rim, drifting toward the center as they rise.
                        let lane = (Self.rand(seed * 5.3) - 0.5) * size * 0.9
                        let rim = cy - sqrt(max(0, size * size * 0.25 - lane * lane)) + size * 0.06
                        let sway = sin(t * (3 + Self.rand(seed) * 3) + seed) * size * 0.06 * phase
                        let x = cx + lane * (1 - phase * 0.6) + sway
                        let y = rim - phase * rise * (1 - abs(lane) / size * 0.6)
                        let r = size * (0.11 + 0.08 * Self.rand(seed * 7.7)) * pow(1 - phase, 0.5) * (0.6 + 0.4 * intensity)
                        guard r > 0.3 else { continue }
                        // Embers (warm) skip the white-hot core and yellow.
                        let heatPhase = hot ? phase : 0.45 + phase * 0.55
                        let color: Color = heatPhase < 0.18 ? Fire.core : heatPhase < 0.45 ? Fire.yellow : heatPhase < 0.7 ? Fire.orange : Fire.red
                        let alpha = pow(1 - phase, 0.6) * (0.5 + 0.5 * intensity)
                        // Tongues: taller than wide, stretching as they rise.
                        let h = r * (2.4 + phase * 1.6)
                        layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - h / 2, width: r * 2, height: h)),
                                   with: .color(color.opacity(alpha)))
                    }
                }

                // A few sparks that shoot higher.
                if hot {
                    for i in 0..<5 {
                        let seed = Double(i) + 40
                        let phase = (t / (1.1 + Self.rand(seed) * 0.7) + Self.rand(seed * 2.9)).truncatingRemainder(dividingBy: 1)
                        let x = cx + (Self.rand(seed * 4.1) - 0.5) * size * 0.8 + sin(t * 5 + seed) * size * 0.08
                        let y = cy - size * 0.3 - phase * size * 1.1
                        let r = max(0.6, size * 0.035 * (1 - phase))
                        g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                               with: .color(Fire.yellow.opacity((1 - phase) * 0.9)))
                    }
                }
            }
        }
        .frame(width: size * 1.9, height: size * 2.4)
        .offset(y: -size * Self.lift)
        .allowsHitTesting(false)
    }

    /// How far the canvas sits above the orb, as a fraction of `size`, so flames have room to rise.
    private static let lift: CGFloat = 0.45

    /// Stable pseudo-random 0…1 per seed.
    private static func rand(_ x: Double) -> Double {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return v - floor(v)
    }
}

/// "312% CPU" chip with a flickering flame.
struct HeatBadge: View {
    var heat: SessionHeat
    var fontSize: CGFloat = 10
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 3) {
            TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let flicker = 1 + 0.08 * sin(t * 17) + 0.05 * sin(t * 29 + 1)
                Image(systemName: heat.level == .hot ? "flame.fill" : "flame")
                    .font(look.font(fontSize * 0.95, .bold))
                    .foregroundStyle(Fire.gradient)
                    .scaleEffect(x: 2 - flicker, y: flicker, anchor: .bottom)
                    .shadow(color: Fire.orange.opacity(heat.level == .hot ? 0.8 : 0.3), radius: 3)
            }
            Text(heat.cpuLabel).font(look.font(fontSize, .semibold).monospacedDigit())
        }
        .foregroundStyle(heat.level == .hot ? Fire.yellow : Fire.orange.opacity(0.9))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((heat.level == .hot ? Fire.red : Fire.orange).opacity(heat.level == .hot ? 0.2 : 0.12)))
        .overlay(Capsule().strokeBorder(Fire.orange.opacity(heat.level == .hot ? 0.5 : 0.25), lineWidth: 0.6))
        .help(heat.level == .hot ? "This agent and the processes it started are heating up your Mac"
                                 : "This agent is using a lot of CPU")
    }
}

/// A slowly turning ring of fire for the border of a hot agent's row or card.
struct FireBorder: View {
    var cornerRadius: CGFloat
    var level: HeatLevel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let hot = level == .hot
            ZStack {
                // Heat rising from the bottom of the row.
                shape.fill(LinearGradient(colors: [Fire.red.opacity(hot ? 0.16 + 0.05 * sin(t * 2.4) : 0.06),
                                                   Fire.orange.opacity(hot ? 0.05 : 0.02), .clear],
                                          startPoint: .bottom, endPoint: .top))
                shape.strokeBorder(
                    AngularGradient(colors: [Fire.yellow, Fire.orange, Fire.red, Fire.ember.opacity(0.4), Fire.red, Fire.orange, Fire.yellow],
                                    center: .center, angle: .degrees(t * 70)),
                    lineWidth: hot ? 1.1 : 0.75)
                    .opacity(hot ? 0.85 : 0.4)
            }
            .shadow(color: Fire.orange.opacity(hot ? 0.25 + 0.1 * sin(t * 3) : 0), radius: 8)
        }
        .allowsHitTesting(false)
    }
}

/// "Mac is hot" chip for list headers.
struct ThermalTally: View {
    var thermal: ProcessInfo.ThermalState
    @ObservedObject private var look = Appearance.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "thermometer.high").font(look.font(9.5, .bold))
            Text(thermal == .critical ? "Mac is overheating" : "Mac is hot").font(look.font(10, .medium))
        }
        .foregroundStyle(Fire.orange)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Fire.red.opacity(0.15)))
        .help("macOS reports the Mac is running hot. Agents flagged with fire are using the most CPU.")
    }
}
