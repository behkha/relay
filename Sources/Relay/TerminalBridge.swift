import Foundation
import AppKit

/// Types text into the terminal that hosts an agent, and brings that terminal forward.
enum TerminalBridge {
    enum Outcome {
        case sent
        case copied          // could not deliver; text is on the clipboard
        case failed(String)

        var ok: Bool {
            if case .sent = self { return true }; return false
        }

        var message: String {
            switch self {
            case .sent: return "Sent"
            case .copied: return "Copied — paste it where the agent runs"
            case .failed(let why): return why
            }
        }
    }

    /// Sends a line of text followed by Return. Call off the main thread.
    static func send(_ text: String, to loc: TerminalLocation) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Nothing to send") }

        if let pane = loc.herdrPane, !pane.isEmpty, let herdr = Proc.which("herdr") {
            var env: [String: String] = [:]
            if let sock = loc.herdrSocket, !sock.isEmpty { env["HERDR_SOCKET_PATH"] = sock }
            let r1 = Proc.run(herdr, ["pane", "send-text", pane, trimmed], env: env, timeout: 10)
            if r1.status == 0 {
                Thread.sleep(forTimeInterval: 0.15)
                let r2 = Proc.run(herdr, ["pane", "send-keys", pane, "enter"], env: env, timeout: 10)
                if r2.status == 0 { return .sent }
            }
            // Never fall through to pasting into some other window.
            return copyOnly(trimmed, why: "Couldn't reach the herdr pane")
        }

        if let pane = loc.tmuxPane, !pane.isEmpty, let tmux = Proc.which("tmux") {
            var base: [String] = []
            if let t = loc.tmux, let sock = t.split(separator: ",").first, !sock.isEmpty {
                base = ["-S", String(sock)]
            }
            let r1 = Proc.run(tmux, base + ["send-keys", "-t", pane, "-l", "--", trimmed], timeout: 10)
            if r1.status == 0 {
                Thread.sleep(forTimeInterval: 0.15)
                let r2 = Proc.run(tmux, base + ["send-keys", "-t", pane, "Enter"], timeout: 10)
                if r2.status == 0 { return .sent }
            }
            return copyOnly(trimmed, why: "Couldn't reach the tmux pane")
        }

        // Agents inside the Claude desktop app or an IDE have no terminal to type into.
        if loc.isAppHosted {
            DispatchQueue.main.sync {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(trimmed, forType: .string)
            }
            _ = activateHostApp(loc)
            return .copied
        }

        // Terminal.app and iTerm2 type the text into the exact tab, found by its tty.
        // The text is wrapped in bracketed-paste markers: without them Claude Code treats a long
        // burst of input as a paste and turns the trailing Return into a newline instead of sending.
        let pasted = "\u{1B}[200~" + trimmed.replacingOccurrences(of: "\u{1B}", with: "") + "\u{1B}[201~"
        if let tty = loc.tty, !tty.isEmpty, tty != "??" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            switch loc.termProgram {
            case "Apple_Terminal":
                if terminalApp(sendLine: pasted, tty: dev) { return .sent }
            case "iTerm.app":
                if iTerm(sendLine: pasted, tty: dev) { return .sent }
            default:
                // Unknown terminal reported; still try the scriptable ones by tty.
                if isRunning("com.apple.Terminal"), terminalApp(sendLine: pasted, tty: dev) { return .sent }
                if isRunning("com.googlecode.iterm2"), iTerm(sendLine: pasted, tty: dev) { return .sent }
            }
        }

        // Terminals without a scripting API (Ghostty, Warp, VS Code…), or a Terminal/iTerm tab that
        // can't be found: Relay can't target the exact tab, so it never types or presses Return blindly.
        // It copies the text and brings the terminal forward for you to paste.
        _ = activateTerminalApp(loc)
        return copyOnly(trimmed, why: nil)
    }

    /// Sends a single key (e.g. "1", "esc") — used only when no hook is waiting for a decision.
    static func sendKey(_ key: String, to loc: TerminalLocation) -> Outcome {
        if loc.isAppHosted { return .failed("Answer this one in the app") }
        if let pane = loc.herdrPane, !pane.isEmpty, let herdr = Proc.which("herdr") {
            var env: [String: String] = [:]
            if let sock = loc.herdrSocket, !sock.isEmpty { env["HERDR_SOCKET_PATH"] = sock }
            let r = key.count == 1
                ? Proc.run(herdr, ["pane", "send-text", pane, key], env: env, timeout: 10)
                : Proc.run(herdr, ["pane", "send-keys", pane, key], env: env, timeout: 10)
            if r.status == 0 { return .sent }
        }
        if let pane = loc.tmuxPane, !pane.isEmpty, let tmux = Proc.which("tmux") {
            var base: [String] = []
            if let t = loc.tmux, let sock = t.split(separator: ",").first, !sock.isEmpty { base = ["-S", String(sock)] }
            let tmuxKey = key == "esc" ? "Escape" : key
            let r = Proc.run(tmux, base + ["send-keys", "-t", pane] + (key.count == 1 ? ["-l", key] : [tmuxKey]), timeout: 10)
            if r.status == 0 { return .sent }
        }
        if let tty = loc.tty, !tty.isEmpty, tty != "??" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            let char = key == "esc" ? "character id 27" : "\"\(key)\""
            if loc.termProgram == "iTerm.app" || (loc.termProgram != "Apple_Terminal" && isRunning("com.googlecode.iterm2")) {
                let src = """
                on run argv
                  tell application "iTerm2"
                    repeat with w in windows
                      repeat with t in tabs of w
                        repeat with s in sessions of t
                          if tty of s is (item 1 of argv) then
                            tell s to write text (\(char)) newline no
                            return "ok"
                          end if
                        end repeat
                      end repeat
                    end repeat
                  end tell
                  return "missing"
                end run
                """
                if AppleScript.run(src, args: [dev]).stdout.contains("ok") { return .sent }
            }
        }
        return .failed("Answer this one in the terminal")
    }

    /// Brings the agent's terminal tab to the front.
    static func focus(_ loc: TerminalLocation) {
        if loc.isAppHosted { _ = activateHostApp(loc); return }
        if let pane = loc.herdrPane, !pane.isEmpty, let herdr = Proc.which("herdr") {
            var env: [String: String] = [:]
            if let sock = loc.herdrSocket, !sock.isEmpty { env["HERDR_SOCKET_PATH"] = sock }
            Proc.run(herdr, ["agent", "focus", pane], env: env, timeout: 10)
        }
        if let tty = loc.tty, !tty.isEmpty, tty != "??" {
            let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
            if loc.termProgram == "Apple_Terminal" || (loc.termProgram != "iTerm.app" && isRunning("com.apple.Terminal")) {
                let src = """
                on run argv
                  tell application "Terminal"
                    repeat with w in windows
                      repeat with t in tabs of w
                        if tty of t is (item 1 of argv) then
                          set selected of t to true
                          set index of w to 1
                          activate
                          return "ok"
                        end if
                      end repeat
                    end repeat
                  end tell
                  return "missing"
                end run
                """
                if AppleScript.run(src, args: [dev]).stdout.contains("ok") { return }
            }
            if loc.termProgram == "iTerm.app" || isRunning("com.googlecode.iterm2") {
                let src = """
                on run argv
                  tell application "iTerm2"
                    repeat with w in windows
                      repeat with t in tabs of w
                        repeat with s in sessions of t
                          if tty of s is (item 1 of argv) then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                          end if
                        end repeat
                      end repeat
                    end repeat
                  end tell
                  return "missing"
                end run
                """
                if AppleScript.run(src, args: [dev]).stdout.contains("ok") { return }
            }
        }
        _ = activateTerminalApp(loc)
    }

    // MARK: - Terminal.app

    private static func terminalApp(sendLine: String, tty: String) -> Bool {
        // `do script ... in <tab>` types the text into the running program, then sends Return (\\r).
        let src = """
        on run argv
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is (item 1 of argv) then
                  do script (item 2 of argv) in t
                  return "ok"
                end if
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        return AppleScript.run(src, args: [tty, sendLine]).stdout.contains("ok")
    }

    // MARK: - iTerm2

    private static func iTerm(sendLine: String, tty: String) -> Bool {
        let src = """
        on run argv
          tell application "iTerm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is (item 1 of argv) then
                    tell s to write text (item 2 of argv) newline no
                    delay 0.1
                    tell s to write text (character id 13) newline no
                    return "ok"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """
        return AppleScript.run(src, args: [tty, sendLine]).stdout.contains("ok")
    }

    // MARK: - Fallback

    private static func copyOnly(_ text: String, why: String?) -> Outcome {
        DispatchQueue.main.sync {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        return why.map { .failed("\($0). Copied your message instead.") } ?? .copied
    }

    /// Brings forward the app that launched the agent (from __CFBundleIdentifier).
    @discardableResult
    private static func activateHostApp(_ loc: TerminalLocation) -> Bool {
        guard let id = loc.bundleId, !id.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return false }
        DispatchQueue.main.sync { _ = app.activate(options: [.activateIgnoringOtherApps]) }
        return true
    }

    @discardableResult
    private static func activateTerminalApp(_ loc: TerminalLocation) -> Bool {
        // The bundle id of the launching app is more reliable than TERM_PROGRAM, which is inherited.
        if activateHostApp(loc) { return true }
        let ids: [String]
        switch loc.termProgram ?? "" {
        case "Apple_Terminal": ids = ["com.apple.Terminal"]
        case "iTerm.app": ids = ["com.googlecode.iterm2"]
        case "ghostty": ids = ["com.mitchellh.ghostty"]
        case "WarpTerminal": ids = ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case "vscode": ids = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf"]
        case "WezTerm": ids = ["com.github.wez.wezterm"]
        case "kitty": ids = ["net.kovidgoyal.kitty"]
        case "Hyper": ids = ["co.zeit.hyper"]
        case "alacritty": ids = ["org.alacritty"]
        default: ids = []
        }
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                DispatchQueue.main.sync { _ = app.activate(options: [.activateIgnoringOtherApps]) }
                return true
            }
        }
        return false
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

}
