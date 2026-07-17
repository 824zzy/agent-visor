//
//  GhosttyScripting.swift
//  AgentVisor
//
//  Sends input to the correct Ghostty terminal pane for a session.
//  Uses a multi-tier approach:
//    Tier 1: AppleScript CWD matching (zero switch, works for unique CWDs)
//    Tier 2: OSC 7 marker matching (always finds the right pane, works cross-monitor)
//  Both tiers use Ghostty's `input text` AppleScript API, which delivers text
//  via Apple Events regardless of which monitor the terminal is on.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

struct GhosttyScripting {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "GhosttyScripting")

    /// Submit option `index` (0-based) in claude-code's TUI question UI.
    /// Sends `index` arrowDown keypresses then enter, all in one
    /// AppleScript call. Why arrow-nav instead of the digit shortcut:
    /// Ghostty's `send key "digit3"` returns ok but never writes "3"
    /// to the program's stdin (verified empirically), and `input text`
    /// uses bracketed-paste mode which claude-code's TUI distinguishes
    /// from real keystrokes — pasted "1" lands as text content, not as
    /// the digit-as-shortcut select. Named keys (arrowDown, enter, etc.)
    /// are the only reliable channel.
    static func submitOption(index: Int, toSession session: SessionState) -> Bool {
        var keys = Array(repeating: "arrowDown", count: max(0, index))
        keys.append("enter")
        return sendNamedKeys(keys, toSession: session)
    }

    /// Send a single named control key (e.g. "escape") to the session's
    /// pane. Must be one of Ghostty's named-key vocabulary — printable
    /// chars don't reach the program through this verb.
    static func sendKeystroke(named keyName: String, toSession session: SessionState) -> Bool {
        sendNamedKeys([keyName], toSession: session)
    }

    /// Send `count` backspace keystrokes to the session's pane,
    /// batched into one AppleScript call. Used to clear Claude Code's
    /// TUI input buffer after an ESC-cancel restores the just-canceled
    /// prompt text. Slow on long buffers — Ghostty processes each
    /// `send key` serially and Ink re-renders between each — but no
    /// faster channel exists: empirically (xxd-traced 2026-05-12),
    /// Ghostty's AppleScript layer filters/consumes control bytes
    /// across `send key`-with-modifier, `input text`, and
    /// `perform action text:`, so Ctrl+U cannot be injected into the
    /// PTY child via AppleScript.
    static func sendBackspaces(count: Int, toSession session: SessionState) -> Bool {
        guard count > 0 else { return false }
        return sendNamedKeys(Array(repeating: "backspace", count: count), toSession: session)
    }

    /// AX-scrape Ghostty's TUI input box; if it contains leftover text,
    /// send enough backspaces to clear it before the next text injection.
    /// No-op when the input box is empty, absent, or unreadable — those
    /// cases fall through to the normal send path so we never block a
    /// legitimate prompt over a probe failure.
    ///
    /// The 100 ms tail-sleep gives Ghostty time to fully apply the
    /// backspace burst before we start typing on top. Without it, the
    /// first chars of the new prompt occasionally render interleaved
    /// with trailing backspace-induced redraws on Ink.
    static func clearInputBoxIfNeeded(session: SessionState) {
        guard let tail = GhosttyModeProbe.readTailText(for: session) else { return }
        guard let existing = TUIInputBoxParser.currentInput(in: tail), !existing.isEmpty else {
            return
        }
        let count = existing.count
        _ = sendBackspaces(count: count, toSession: session)
        usleep(100_000)
    }

    private static func sendNamedKeys(_ keyNames: [String], toSession session: SessionState) -> Bool {
        guard let tty = session.tty, !keyNames.isEmpty else { return false }
        let escaped = keyNames.map { $0.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") }
        if sendNamedKeysViaCWDMatch(keyNames: escaped, cwd: session.cwd) { return true }
        let ttyPath = "/dev/\(tty)"
        return sendNamedKeysViaOSC7Marker(keyNames: escaped, ttyPath: ttyPath, originalCwd: session.cwd)
    }

    private static func keySendBlock(_ keyNames: [String], target: String) -> String {
        keyNames.map { "send key \"\($0)\" to \(target)" }.joined(separator: "\n            ")
    }

    private static func sendNamedKeysViaCWDMatch(keyNames: [String], cwd: String) -> Bool {
        let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let block = keySendBlock(keyNames, target: "target")
        let script = """
        tell application "Ghostty"
            set matchCount to 0
            set targetId to missing value
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    if working directory of t is "\(escapedCwd)" then
                        set matchCount to matchCount + 1
                        set targetId to id of t
                    end if
                end repeat
            end repeat
            if matchCount is 1 and targetId is not missing value then
                set target to terminal id targetId
                \(block)
                return "ok"
            else
                return "fail"
            end if
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func sendNamedKeysViaOSC7Marker(keyNames: [String], ttyPath: String, originalCwd: String) -> Bool {
        let marker = "/tmp/av_keys_\(UInt32.random(in: 100000...999999))"
        let oscSet = "\u{1b}]7;file://localhost\(marker)\u{07}"
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = oscSet.data(using: .utf8) else { return false }
        handle.write(data)
        handle.closeFile()
        usleep(300000)

        let block = keySendBlock(keyNames, target: "t")
        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(marker)" then
                            \(block)
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "fail"
        end tell
        """
        let result = runAppleScript(script)

        let oscRestore = "\u{1b}]7;file://localhost\(originalCwd)\u{07}"
        if let restoreHandle = FileHandle(forWritingAtPath: ttyPath),
           let restoreData = oscRestore.data(using: .utf8) {
            restoreHandle.write(restoreData)
            restoreHandle.closeFile()
        }
        return result == "ok"
    }

    static func sendInput(_ text: String, toSession session: SessionState) -> Bool {
        let probeStart = Date()
        logger.info("sendInput: enter sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(session.tty ?? "?", privacy: .public) cwd=\(session.cwd, privacy: .public) len=\(text.count, privacy: .public)")
        guard let tty = session.tty else {
            logger.error("sendInput: no tty for sid=\(session.sessionId.prefix(8), privacy: .public)")
            return false
        }

        // Burn down any leftover text in claude-code's TUI input box
        // before typing. Survives the cancel-clear race documented in
        // ChatView.cancelQuery (two AppleScript OSC-7 markers collide
        // when the user cancels + reopens chat quickly), plus any
        // other source of stale input. AX-scrape costs ~50ms when the
        // pane is reachable, returns nil silently otherwise.
        clearInputBoxIfNeeded(session: session)

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Tier 1: AppleScript CWD matching (zero app switch, fast)
        // Only works when the session's CWD is unique among Ghostty terminals
        if sendViaCWDMatch(escapedText: escapedText, cwd: session.cwd) {
            let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
            logger.info("sendInput: ok tier=cwdMatch sid=\(session.sessionId.prefix(8), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
            return true
        }

        // Tier 2: OSC 7 marker matching (always correct, works cross-monitor)
        // Temporarily changes the terminal's reported CWD to a unique marker,
        // then sends text via AppleScript `input text` to that specific terminal.
        let ttyPath = "/dev/\(tty)"
        if sendViaOSC7Marker(escapedText: escapedText, ttyPath: ttyPath, originalCwd: session.cwd) {
            let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
            logger.info("sendInput: ok tier=osc7 sid=\(session.sessionId.prefix(8), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
            return true
        }

        let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
        logger.error("sendInput: BOTH TIERS FAILED sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(tty, privacy: .public) cwd=\(session.cwd, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
        return false
    }

    // MARK: - Tier 1: CWD Matching

    private static func sendViaCWDMatch(escapedText: String, cwd: String) -> Bool {
        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Ghostty"
            set matchCount to 0
            set targetId to missing value
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    if working directory of t is "\(escapedCwd)" then
                        set matchCount to matchCount + 1
                        set targetId to id of t
                    end if
                end repeat
            end repeat
            if matchCount is 1 and targetId is not missing value then
                set target to terminal id targetId
                input text "\(escapedText)" to target
                delay 0.5
                send key "enter" to target
                return "ok"
            else
                return "fail"
            end if
        end tell
        """

        return runAppleScript(script) == "ok"
    }

    // MARK: - Tier 2: OSC 7 Marker Matching

    private static func sendViaOSC7Marker(escapedText: String, ttyPath: String, originalCwd: String) -> Bool {
        let marker = "/tmp/av_send_\(UInt32.random(in: 100000...999999))"
        let hostname = "localhost"

        // Write OSC 7 to temporarily change the terminal's reported CWD
        let oscSet = "\u{1b}]7;file://\(hostname)\(marker)\u{07}"
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = oscSet.data(using: .utf8) else {
            return false
        }
        handle.write(data)
        handle.closeFile()

        // Wait for Ghostty to process the CWD change
        usleep(300000) // 300ms

        // Find terminal with marker CWD and send text via AppleScript
        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(marker)" then
                            input text "\(escapedText)" to t
                            delay 0.5
                            send key "enter" to t
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "fail"
        end tell
        """

        let result = runAppleScript(script)

        // Restore original CWD via OSC 7
        let oscRestore = "\u{1b}]7;file://\(hostname)\(originalCwd)\u{07}"
        if let restoreHandle = FileHandle(forWritingAtPath: ttyPath),
           let restoreData = oscRestore.data(using: .utf8) {
            restoreHandle.write(restoreData)
            restoreHandle.closeFile()
        }

        return result == "ok"
    }


    // MARK: - Multi-step Mixed Keystroke + Text Input
    //
    // Used by the multi-question AskUserQuestion flow, which needs to
    // batch named-key navigation (arrow keys, enter, space, tab) together
    // with literal text typing (the "Other" free-form answer). Both run
    // inside one AppleScript `tell` block so the whole sequence delivers
    // atomically and any per-key delay is the AppleScript runtime's, not
    // process-spawn overhead per step.

    static func sendSteps(_ steps: [KeystrokeStep], toSession session: SessionState) -> Bool {
        guard let tty = session.tty, !steps.isEmpty else { return false }
        if sendStepsViaCWDMatch(steps: steps, cwd: session.cwd) { return true }
        let ttyPath = "/dev/\(tty)"
        return sendStepsViaOSC7Marker(steps: steps, ttyPath: ttyPath, originalCwd: session.cwd)
    }

    private static func stepsBlock(_ steps: [KeystrokeStep], target: String) -> String {
        steps.map { step -> String in
            switch step {
            case .key(let name):
                let escaped = name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "send key \"\(escaped)\" to \(target)"
            case .text(let raw):
                let escaped = raw
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "input text \"\(escaped)\" to \(target)"
            case .delay(let seconds):
                return "delay \(seconds)"
            }
        }.joined(separator: "\n            ")
    }

    private static func sendStepsViaCWDMatch(steps: [KeystrokeStep], cwd: String) -> Bool {
        let escapedCwd = cwd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let block = stepsBlock(steps, target: "target")
        let script = """
        tell application "Ghostty"
            set matchCount to 0
            set targetId to missing value
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    if working directory of t is "\(escapedCwd)" then
                        set matchCount to matchCount + 1
                        set targetId to id of t
                    end if
                end repeat
            end repeat
            if matchCount is 1 and targetId is not missing value then
                set target to terminal id targetId
                \(block)
                return "ok"
            else
                return "fail"
            end if
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func sendStepsViaOSC7Marker(steps: [KeystrokeStep], ttyPath: String, originalCwd: String) -> Bool {
        let marker = "/tmp/av_steps_\(UInt32.random(in: 100000...999999))"
        let oscSet = "\u{1b}]7;file://localhost\(marker)\u{07}"
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = oscSet.data(using: .utf8) else { return false }
        handle.write(data)
        handle.closeFile()
        usleep(300000)

        let block = stepsBlock(steps, target: "t")
        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(marker)" then
                            \(block)
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "fail"
        end tell
        """
        let result = runAppleScript(script)

        let oscRestore = "\u{1b}]7;file://localhost\(originalCwd)\u{07}"
        if let restoreHandle = FileHandle(forWritingAtPath: ttyPath),
           let restoreData = oscRestore.data(using: .utf8) {
            restoreHandle.write(restoreData)
            restoreHandle.closeFile()
        }
        return result == "ok"
    }

    // MARK: - Helpers

    private static func runAppleScript(_ source: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}

// `KeystrokeStep` lifted to AgentVisorCore so the AskUserQuestion
// keystroke builder (a pure value-only algorithm) can be unit-tested
// without dragging in AppKit / SwiftUI / AppleScript. See
// AgentVisorCore/Sources/AgentVisorCore/KeystrokeStep.swift.
