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
    static func submitOption(
        index: Int,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        var keys = Array(repeating: "arrowDown", count: max(0, index))
        keys.append("enter")
        return sendNamedKeys(keys, toSession: session, operationID: operationID)
    }

    /// Send a single named control key (e.g. "escape") to the session's
    /// pane. Must be one of Ghostty's named-key vocabulary — printable
    /// chars don't reach the program through this verb.
    static func sendKeystroke(
        named keyName: String,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        sendNamedKeys([keyName], toSession: session, operationID: operationID)
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
    static func sendBackspaces(
        count: Int,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard count > 0 else { return false }
        return sendNamedKeys(
            Array(repeating: "backspace", count: count),
            toSession: session,
            operationID: operationID
        )
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
    static func clearInputBoxIfNeeded(
        session: SessionState,
        operationID: String? = nil
    ) {
        guard let tail = GhosttyModeProbe.readTailText(for: session) else { return }
        guard let existing = TUIInputBoxParser.currentInput(in: tail), !existing.isEmpty else {
            return
        }
        let count = existing.count
        _ = sendBackspaces(
            count: count,
            toSession: session,
            operationID: operationID
        )
        usleep(100_000)
    }

    private static func sendNamedKeys(
        _ keyNames: [String],
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        sendNamedKeysOutcome(
            keyNames,
            toSession: session,
            operationID: operationID
        ).isAccepted
    }

    private static func sendNamedKeysOutcome(
        _ keyNames: [String],
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        // Revalidate immediately before every named-key action, including
        // Escape and the chunked destructive clear. TTY/PID reuse must never
        // send a key to a new provider process.
        guard TerminalProcessIdentityResolver.isVerified(session),
              let tty = session.tty,
              !keyNames.isEmpty else {
            return .provenRejected(reason: "The Ghostty key dispatch was rejected before write.")
        }
        let escaped = keyNames.map { $0.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") }
        let cwdResult = sendNamedKeysViaCWDMatchOutcome(
            keyNames: escaped,
            cwd: session.cwd,
            session: session,
            operationID: operationID
        )
        switch cwdResult {
        case .accepted, .indeterminate:
            return cwdResult
        case .provenRejected:
            break
        }
        let ttyPath = "/dev/\(tty)"
        return sendNamedKeysViaOSC7MarkerOutcome(
            keyNames: escaped,
            ttyPath: ttyPath,
            originalCwd: session.cwd,
            session: session,
            operationID: operationID
        )
    }

    private static func keySendBlock(_ keyNames: [String], target: String) -> String {
        keyNames.map { "send key \"\($0)\" to \(target)" }.joined(separator: "\n            ")
    }

    private static func sendNamedKeysViaCWDMatchOutcome(
        keyNames: [String],
        cwd: String,
        session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before key dispatch.")
        }
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
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before key dispatch.")
        }
        return runAppleScriptOutcome(script, operationID: operationID)
    }

    private static func sendNamedKeysViaOSC7MarkerOutcome(
        keyNames: [String],
        ttyPath: String,
        originalCwd: String,
        session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before key dispatch.")
        }
        let marker = "/tmp/av_keys_\(UInt32.random(in: 100000...999999))"
        let oscSet = "\u{1b}]7;file://localhost\(marker)\u{07}"
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = oscSet.data(using: .utf8) else {
            return .provenRejected(reason: "The Ghostty marker could not be written before key dispatch.")
        }
        handle.write(data)
        handle.closeFile()
        usleep(300000)
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target changed before key dispatch.")
        }

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
        let result = runAppleScriptOutcome(script, operationID: operationID)

        let oscRestore = "\u{1b}]7;file://localhost\(originalCwd)\u{07}"
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            switch result {
            case .accepted, .indeterminate:
                return .indeterminate(reason: "The Ghostty target changed after key dispatch.")
            case .provenRejected:
                return result
            }
        }
        if let restoreHandle = FileHandle(forWritingAtPath: ttyPath),
           let restoreData = oscRestore.data(using: .utf8) {
            restoreHandle.write(restoreData)
            restoreHandle.closeFile()
        }
        return result
    }

    static func sendInput(
        _ text: String,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        sendInputOutcome(
            text,
            toSession: session,
            operationID: operationID
        ).isDelivered
    }

    static func sendInputOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> TerminalAttachmentDeliveryOutcome {
        guard TerminalProcessIdentityResolver.isVerified(session),
              TerminalTextPolicy.canSend(text) else {
            return .failedBeforeWrite(reason: "The Ghostty message was rejected before write.")
        }
        let probeStart = Date()
        logger.info("sendInput: enter sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(session.tty ?? "?", privacy: .public) cwd=\(session.cwd, privacy: .public) len=\(text.count, privacy: .public)")
        guard let tty = session.tty else {
            logger.error("sendInput: no tty for sid=\(session.sessionId.prefix(8), privacy: .public)")
            return .failedBeforeWrite(reason: "The Ghostty session has no verified TTY.")
        }

        // Burn down any leftover text in claude-code's TUI input box
        // before typing. Survives the cancel-clear race documented in
        // ChatView.cancelQuery (two AppleScript OSC-7 markers collide
        // when the user cancels + reopens chat quickly), plus any
        // other source of stale input. AX-scrape costs ~50ms when the
        // pane is reachable, returns nil silently otherwise.
        clearInputBoxIfNeeded(session: session, operationID: operationID)

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Tier 1: AppleScript CWD matching (zero app switch, fast)
        // Only works when the session's CWD is unique among Ghostty terminals.
        // An AppleScript error is not a proven rejection: input text may have
        // reached the pane before osascript timed out or failed. Only the
        // explicit `fail` sentinel may select the OSC 7 tier.
        let cwdResult = sendViaCWDMatchOutcome(
            escapedText: escapedText,
            cwd: session.cwd,
            session: session,
            operationID: operationID
        )
        let textDispatch: TerminalTextDispatchResult
        switch cwdResult {
        case .accepted:
            textDispatch = cwdResult
        case .indeterminate:
            return TerminalAttachmentDeliveryPolicy.textDispatchOutcome(cwdResult)
        case .provenRejected:
            textDispatch = sendViaOSC7MarkerOutcome(
                escapedText: escapedText,
                ttyPath: "/dev/\(tty)",
                originalCwd: session.cwd,
                session: session,
                operationID: operationID
            )
        }

        guard textDispatch.isAccepted else {
            return TerminalAttachmentDeliveryPolicy.textDispatchOutcome(textDispatch)
        }
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textDispatch: .accepted,
                enterDispatch: .indeterminate(reason: "The Ghostty target changed after text was accepted.")
            )
        }
        let enterDispatch = sendNamedKeysOutcome(
            ["enter"],
            toSession: session,
            operationID: operationID
        )
        let outcome = TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
            textDispatch: textDispatch,
            enterDispatch: enterDispatch
        )
        guard outcome.isDelivered else { return outcome }
        let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
        logger.info("sendInput: ok tier=\(cwdResult.isAccepted ? "cwdMatch" : "osc7", privacy: .public) sid=\(session.sessionId.prefix(8), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
        return outcome
    }

    // MARK: - Tier 1: CWD Matching

    private static func sendViaCWDMatchOutcome(
        escapedText: String,
        cwd: String,
        session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before text dispatch.")
        }
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
                return "ok"
            else
                return "fail"
            end if
        end tell
        """

        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before text dispatch.")
        }
        return runAppleScriptOutcome(script, operationID: operationID)
    }

    private static func sendViaCWDMatch(
        escapedText: String,
        cwd: String,
        session: SessionState,
        operationID: String?
    ) -> Bool {
        sendViaCWDMatchOutcome(
            escapedText: escapedText,
            cwd: cwd,
            session: session,
            operationID: operationID
        ).isAccepted
    }

    // MARK: - Tier 2: OSC 7 Marker Matching

    private static func sendViaOSC7MarkerOutcome(
        escapedText: String,
        ttyPath: String,
        originalCwd: String,
        session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target was not verified before text dispatch.")
        }
        let marker = "/tmp/av_send_\(UInt32.random(in: 100000...999999))"
        let hostname = "localhost"

        // Write OSC 7 to temporarily change the terminal's reported CWD
        let oscSet = "\u{1b}]7;file://\(hostname)\(marker)\u{07}"
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = oscSet.data(using: .utf8) else {
            return .provenRejected(reason: "The Ghostty marker could not be written before text dispatch.")
        }
        handle.write(data)
        handle.closeFile()

        // Wait for Ghostty to process the CWD change
        usleep(300000) // 300ms
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The Ghostty target changed before text dispatch.")
        }

        // Find terminal with marker CWD and send text via AppleScript
        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(marker)" then
                            input text "\(escapedText)" to t
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "fail"
        end tell
        """

        let result = runAppleScriptOutcome(script, operationID: operationID)

        // Restore original CWD via OSC 7
        let oscRestore = "\u{1b}]7;file://\(hostname)\(originalCwd)\u{07}"
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            switch result {
            case .accepted, .indeterminate:
                return .indeterminate(reason: "The Ghostty target changed after text dispatch.")
            case .provenRejected:
                return result
            }
        }
        if let restoreHandle = FileHandle(forWritingAtPath: ttyPath),
           let restoreData = oscRestore.data(using: .utf8) {
            restoreHandle.write(restoreData)
            restoreHandle.closeFile()
        }

        return result
    }

    private static func sendViaOSC7Marker(
        escapedText: String,
        ttyPath: String,
        originalCwd: String,
        session: SessionState,
        operationID: String?
    ) -> Bool {
        sendViaOSC7MarkerOutcome(
            escapedText: escapedText,
            ttyPath: ttyPath,
            originalCwd: originalCwd,
            session: session,
            operationID: operationID
        ).isAccepted
    }

    // MARK: - Multi-step Mixed Keystroke + Text Input
    //
    // Used by the multi-question AskUserQuestion flow, which needs named-key
    // navigation and literal text. Each irreversible step is dispatched
    // independently so the process identity can be revalidated before the
    // next write; this prevents a replacement process from receiving the
    // tail of a stale answer.

    static func sendSteps(
        _ steps: [KeystrokeStep],
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              !steps.isEmpty else { return false }
        let outcome = TerminalAttachmentDeliveryPolicy.run(
            steps: steps,
            verifyTarget: { TerminalProcessIdentityResolver.isVerified(session) },
            name: { step in
                switch step {
                case .key(let name): return "key:\(name)"
                case .text(let text): return "text:\(text.utf8.count)"
                case .delay: return "delay"
                }
            },
            perform: { step in
                switch step {
                case .delay(let seconds):
                    guard seconds.isFinite, seconds >= 0, seconds <= 5 else {
                        return .failedBeforeWrite(step: "delay", reason: "Invalid terminal delay.")
                    }
                    usleep(useconds_t(seconds * 1_000_000))
                    return .succeeded(step: "delay")
                case .key(let name):
                    switch sendNamedKeysOutcome(
                        [name],
                        toSession: session,
                        operationID: operationID
                    ) {
                    case .accepted:
                        return .succeeded(step: "key:\(name)")
                    case .provenRejected(let reason):
                        return .failedBeforeWrite(
                            step: "key:\(name)",
                            reason: reason
                        )
                    case .indeterminate(let reason):
                        return .failedAfterWrite(
                            step: "key:\(name)",
                            reason: reason
                        )
                    }
                case .text(let text):
                    guard TerminalTextPolicy.canSend(text) else {
                        return .failedBeforeWrite(
                            step: "text",
                            reason: "The terminal message exceeds the UTF-8 size limit."
                        )
                    }
                    switch sendLiteralTextOutcome(
                        text,
                        toSession: session,
                        operationID: operationID
                    ) {
                    case .accepted:
                        return .succeeded(step: "text")
                    case .provenRejected(let reason):
                        return .failedBeforeWrite(
                            step: "text",
                            reason: reason
                        )
                    case .indeterminate(let reason):
                        return .failedAfterWrite(
                            step: "text",
                            reason: reason
                        )
                    }
                }
            }
        )
        return outcome.isDelivered
    }

    private static func sendLiteralText(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> Bool {
        sendLiteralTextOutcome(
            text,
            toSession: session,
            operationID: operationID
        ).isAccepted
    }

    private static func sendLiteralTextOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        guard TerminalProcessIdentityResolver.isVerified(session),
              let tty = session.tty else {
            return .provenRejected(reason: "The Ghostty text dispatch was rejected before write.")
        }
        let escapedText = appleScriptEscape(text)
        let cwdResult = sendViaCWDMatchOutcome(
            escapedText: escapedText,
            cwd: session.cwd,
            session: session,
            operationID: operationID
        )
        switch cwdResult {
        case .accepted, .indeterminate:
            return cwdResult
        case .provenRejected:
            return sendViaOSC7MarkerOutcome(
                escapedText: escapedText,
                ttyPath: "/dev/\(tty)",
                originalCwd: session.cwd,
                session: session,
                operationID: operationID
            )
        }
    }

    // MARK: - Helpers

    private static func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func executeAppleScript(
        _ source: String,
        operationID: String?
    ) -> Result<ProcessResult, ProcessExecutorError> {
        let result: Result<ProcessResult, ProcessExecutorError>
        if let operationID {
            result = ProcessExecutor.shared.runSyncWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: SubprocessDeadlinePolicy.appCommand,
                operationID: operationID
            )
        } else {
            result = ProcessExecutor.shared.runSyncWithResult(
                "/usr/bin/osascript",
                arguments: ["-e", source],
                timeout: SubprocessDeadlinePolicy.appCommand
            )
        }
        return result
    }

    /// Rich dispatch result for text and submit actions. An osascript
    /// execution/launch/timeout error is indeterminate: the child may have
    /// delivered text before failing, so it must not select another tier.
    private static func runAppleScriptOutcome(
        _ source: String,
        operationID: String? = nil
    ) -> TerminalTextDispatchResult {
        switch executeAppleScript(source, operationID: operationID) {
        case .success(let result):
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            switch output {
            case "ok":
                return .accepted
            case "fail":
                return .provenRejected(reason: "The Ghostty script rejected the target before write.")
            default:
                return .indeterminate(
                    reason: output.isEmpty
                        ? "The Ghostty script returned no dispatch result."
                        : "The Ghostty script returned an unexpected dispatch result."
                )
            }
        case .failure(let error):
            return .indeterminate(reason: error.localizedDescription)
        }
    }
}

// `KeystrokeStep` lifted to AgentVisorCore so the AskUserQuestion
// keystroke builder (a pure value-only algorithm) can be unit-tested
// without dragging in AppKit / SwiftUI / AppleScript. See
// AgentVisorCore/Sources/AgentVisorCore/KeystrokeStep.swift.
