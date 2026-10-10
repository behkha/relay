import AppKit
import SwiftUI
import ScreenCaptureKit
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import NimbiKit

/// Records the mascot alone for the README: `RELAY_MASCOT=<scene> RELAY_MASCOT_OUT=/path/frames .build/release/Relay`.
///
/// It shows one transparent window with a big cloud, plays a short script of moods on it and
/// writes every frame as a PNG with its alpha into the output folder, plus `info.txt` with the
/// loop length, so scripts/record-mascot.sh can turn them into an animated image.
///
/// It runs before the app delegate exists: no hook server, listeners, hotkeys, status item,
/// notifications or support folder, and it reads and writes no settings. The mood engine is
/// never attached to the store; the script sets its mood directly. So it can run next to the
/// real Relay without either noticing the other.
enum MascotRecording {
    static let scene = ProcessInfo.processInfo.environment["RELAY_MASCOT"]
    static var isOn: Bool { scene != nil }

    /// Points; the window is captured at twice this.
    static let side: CGFloat = 400
    static let mascotSize: CGFloat = 160
    static let fps = 30
    /// Recorded past the loop's end, so the encoder can fade the end into the start.
    static let tail = 0.6

    private static var window: NSWindow?
    private static var recorder: AnyObject?
    private static let stage = MascotStage()

    private static var outputDir: URL {
        let path = ProcessInfo.processInfo.environment["RELAY_MASCOT_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("relay-mascot").path
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func main() {
        guard let found = MascotScene(name: scene ?? "") else {
            print("Unknown mascot scene \"\(scene ?? "")\"; try one of: \(MascotScene.names.joined(separator: ", "))")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async { run(found) }
        app.run()
    }

    private static func run(_ scene: MascotScene) {
        guard #available(macOS 14.0, *) else {
            print("Mascot recording needs macOS 14 or later")
            exit(1)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { exit(1) }
        scene.start(stage)

        // Bottom-right corner of the screen, above other windows so it is never covered
        // (a covered cloud stops animating).
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - side - 20, y: vf.minY + 20, width: side, height: side)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.level = .statusBar
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        win.contentView = NSHostingView(rootView: MascotStageView(stage: stage))
        win.orderFrontRegardless()
        window = win

        let dir = outputDir
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info = "length=\(scene.length)\ntail=\(tail)\nfps=\(fps)\n"
        try? info.write(to: dir.appendingPathComponent("info.txt"), atomically: true, encoding: .utf8)

        let rec = MascotRecorder(dir: dir, fps: fps, pixels: Int(side * 2))
        recorder = rec
        // Give the window a moment to reach the window server and the springs to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            rec.start(windowID: CGWindowID(win.windowNumber)) { ok in
                guard ok else { exit(1) }
                scene.play(stage)
                DispatchQueue.main.asyncAfter(deadline: .now() + scene.length + tail) {
                    rec.stop(frames: Int((scene.length + tail) * Double(fps))) { count in
                        print("Mascot: wrote \(count) frames to \(dir.path)")
                        exit(count > 0 ? 0 : 1)
                    }
                }
            }
        }
    }
}

// MARK: - Scenes

/// Where the cloud looks; its mood lives in the mood engine.
final class MascotStage: ObservableObject {
    @Published var glance: CGFloat = 0

    func set(_ mood: Mood, working: Int = 0) { MoodEngine.shared.demoSet(mood, working: working) }

    func look(_ x: CGFloat) { glance = x }
}

/// A short script that ends where it starts, so it loops.
struct MascotScene {
    let length: Double
    let start: (MascotStage) -> Void
    let beats: [(Double, (MascotStage) -> Void)]

    static let names = ["idle", "reel", "busy"]

    init?(name: String) {
        switch name {
        case "idle":
            // Relaxed, breathing and blinking, glancing one way and then the other.
            length = 6
            start = { $0.set(.relaxed); $0.look(0) }
            beats = [
                (0.9, { $0.look(-0.85) }),
                (2.3, { $0.look(0.9) }),
                (3.7, { $0.look(0.3) }),
                (4.6, { $0.look(0) }),
            ]
        case "reel":
            // Through its moods, from asleep and back to sleep.
            length = 8
            start = { $0.set(.asleep); $0.look(0) }
            beats = [
                (1.0, { $0.set(.relaxed) }),
                (1.4, { $0.look(-0.6) }),
                (2.0, { $0.set(.busy, working: 3); $0.look(0.4) }),
                (3.6, { $0.set(.asking); $0.look(0.8) }),
                (4.8, { $0.set(.angry); $0.look(0) }),
                (6.0, { $0.set(.happy) }),
                (7.2, { $0.set(.asleep) }),
            ]
        case "busy":
            // Three agents at work; one finishes, a happy beat, and another starts.
            length = 7
            start = { $0.set(.busy, working: 3); $0.look(0) }
            beats = [
                (0.7, { $0.look(-0.8) }),
                (1.9, { $0.look(0.85) }),
                (3.0, { $0.look(0) }),
                (3.6, { $0.set(.happy, working: 2) }),
                (5.6, { $0.set(.busy, working: 3) }),
            ]
        default:
            return nil
        }
    }

    func play(_ stage: MascotStage) {
        for (t, beat) in beats {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { beat(stage) }
        }
    }
}

private struct MascotStageView: View {
    @ObservedObject var stage: MascotStage

    var body: some View {
        Mascot(size: MascotRecording.mascotSize, glance: stage.glance, followsCursor: false)
            .frame(width: MascotRecording.side, height: MascotRecording.side)
    }
}

// MARK: - Recording

/// Captures one window with its transparency and writes numbered PNGs at a steady frame rate.
@available(macOS 14.0, *)
private final class MascotRecorder: NSObject, SCStreamDelegate {
    private let sink: FrameSink
    private let pixels: Int
    private let fps: Int
    private var stream: SCStream?

    init(dir: URL, fps: Int, pixels: Int) {
        sink = FrameSink(dir: dir, fps: fps)
        self.fps = fps
        self.pixels = pixels
    }

    func start(windowID: CGWindowID, started: @escaping (Bool) -> Void) {
        sink.onFirstFrame = { DispatchQueue.main.async { started(true) } }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
            DispatchQueue.main.async {
                guard let window = content?.windows.first(where: { $0.windowID == windowID }) else {
                    print("Mascot: couldn't find its window in ScreenCaptureKit: \(error?.localizedDescription ?? "not listed")")
                    started(false); return
                }
                let cfg = SCStreamConfiguration()
                cfg.width = self.pixels
                cfg.height = self.pixels
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.colorSpaceName = CGColorSpace.sRGB
                cfg.backgroundColor = .clear
                cfg.shouldBeOpaque = false
                cfg.ignoreShadowsSingleWindow = true
                cfg.showsCursor = false
                cfg.queueDepth = 6
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
                do {
                    try stream.addStreamOutput(self.sink, type: .screen, sampleHandlerQueue: self.sink.queue)
                } catch {
                    print("Mascot: recording failed to start: \(error.localizedDescription)")
                    started(false); return
                }
                self.stream = stream
                stream.startCapture { error in
                    if let error {
                        print("Mascot: recording failed to start: \(error.localizedDescription)")
                        DispatchQueue.main.async { started(false) }
                    }
                }
            }
        }
    }

    /// Stops, pads the end to exactly `frames` frames, and reports how many were written.
    func stop(frames: Int, done: @escaping (Int) -> Void) {
        let sink = self.sink
        stream?.stopCapture { _ in
            sink.finish(frames: frames) { count in DispatchQueue.main.async { done(count) } }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Mascot: stream stopped: \(error.localizedDescription)")
    }
}

/// Receives frames on its own queue and writes them out on another, so a slow PNG never
/// holds up capture. A frame lands at the slot its timestamp falls in; slots the window server
/// skipped (nothing changed) repeat the previous frame.
@available(macOS 14.0, *)
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "relay.mascot.capture")
    private let writer = DispatchQueue(label: "relay.mascot.write", attributes: .concurrent)
    private let writes = DispatchGroup()
    private let dir: URL
    private let fps: Int
    var onFirstFrame: (() -> Void)?

    // Touched only on `queue`.
    private var t0: Double?
    private var next = 0
    private var last: CGImage?

    init(dir: URL, fps: Int) {
        self.dir = dir
        self.fps = fps
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let infos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = infos.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sb.imageBuffer, let image = Self.image(buffer) else { return }
        let t = sb.presentationTimeStamp.seconds
        if t0 == nil {
            t0 = t
            onFirstFrame?()
        }
        let slot = Int(((t - (t0 ?? t)) * Double(fps)).rounded())
        // Repeat the previous frame for slots that got none.
        while next < slot, let last { write(last, at: next); next += 1 }
        if slot >= next { write(image, at: slot); next = slot + 1 }
        last = image
    }

    func finish(frames: Int, done: @escaping (Int) -> Void) {
        queue.async {
            while self.next < frames, let last = self.last { self.write(last, at: self.next); self.next += 1 }
            let count = self.next
            self.writes.notify(queue: self.queue) { done(count) }
        }
    }

    private func write(_ image: CGImage, at index: Int) {
        let url = dir.appendingPathComponent(String(format: "f%05d.png", index))
        writer.async(group: writes) {
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Copies a premultiplied BGRA frame into an image that keeps its alpha.
    private static func image(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        return ctx.makeImage()
    }
}
