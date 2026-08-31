//
//  ITermAdapter.swift
//  AgentVisor
//
//  Sends input to and focuses iTerm2 session panes for a given Claude
//  Code session. Targets sessions by TTY: iTerm2 exposes the tty path
//  ("/dev/ttysNNN") as an AppleScript property on each session, so we
//  can walk windows -> tabs -> sessions and match without the OSC 7
//  marker dance Ghostty needs.
//
//  iTerm2's `write text` delivers in the background without stealing
//  focus, validated by scripts/probe-iterm-write.sh during Phase 1.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

struct ITermAdapter: TerminalAdapter {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ITermAdapter")
    /// Mirrors SessionNavigator's PillNav category so all
    /// navigation-decision lines stream together.
    private static let pillNavLog = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillNav")

    nonisolated init() {}

    func sendText(_ text: String, toSession session: SessionState) -> Bool {
        sendTextOutcome(
            text,
            toSession: session,
            operationID: ProcessExecutor.currentOperationID
        ).isDelivered
    }

    func sendTextOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalAttachmentDeliveryOutcome {
        guard TerminalProcessIdentityResolver.isVerified(session),
              TerminalTextPolicy.canSend(text) else {
            return .failedBeforeWrite(reason: "The iTerm2 message was rejected before write.")
        }
        let probeStart = Date()
        Self.logger.info("sendText: enter sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(session.tty ?? "?", privacy: .public) len=\(text.count, privacy: .public)")
        guard let ttyName = ttyName(for: session) else {
            Self.logger.error("sendText: no ttyName resolved for sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(session.tty ?? "nil", privacy: .public)")
            return .failedBeforeWrite(reason: "The iTerm2 session has no verified TTY.")
        }
        let escaped = AppleScriptEscaper.escape(text)

        // Two-step submission: first write text without newline to populate
        // the TUI input, then revalidate the process identity and send Enter
        // through a second AppleScript action. Keeping Enter separate is
        // important: a process/TTY replacement between these actions must
        // stop the transaction rather than submit into the new process.
        //
        // iTerm2's `write` verb requires the session as the `tell` receiver,
        // not a `to <session>` argument — the latter parses but silently
        // errors at runtime, which the surrounding `try` then swallows.
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    write text "\(escaped)" newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        let textDispatch = runAppleScriptOutcome(script, operationID: operationID)
        let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
        if textDispatch.isAccepted {
            Self.logger.info("sendText: ok tty=\(ttyName, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
        } else {
            Self.logger.error("sendText: script did not accept text for tty=\(ttyName, privacy: .public) outcome=\(String(describing: textDispatch), privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
        }
        guard textDispatch.isAccepted else {
            return TerminalAttachmentDeliveryPolicy.textDispatchOutcome(textDispatch)
        }
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
                textDispatch: .accepted,
                enterDispatch: .indeterminate(reason: "The iTerm2 target changed after text was accepted.")
            )
        }
        let enterDispatch = sendSingleStepOutcome(
            .key("enter"),
            ttyName: ttyName,
            session: session,
            operationID: operationID
        )
        return TerminalAttachmentDeliveryPolicy.textAndEnterOutcome(
            textDispatch: textDispatch,
            enterDispatch: enterDispatch
        )
    }

    /// Send the digit char `(index + 1)` to claude-code's TUI question UI,
    /// triggering the digit-shortcut select. iTerm2's `write text` is
    /// documented as "as though typed" (not a paste), so this should
    /// reach the program as a real keystroke and trigger the shortcut.
    func sendDigitShortcut(index: Int, toSession session: SessionState) -> Bool {
        let operationID = ProcessExecutor.currentOperationID
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let digit = String(index + 1)
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    write text "\(digit)" newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        return runAppleScriptOutcome(script, operationID: operationID).isAccepted
    }

    /// Send a sequence of named-key + literal-text + delay steps to the
    /// session. Each irreversible write is its own bounded AppleScript
    /// action and is preceded by a fresh process/TTY identity check. This
    /// intentionally does not coalesce steps: a process swap between two
    /// keys must stop the remainder rather than write into a reused pane.
    func sendSteps(
        _ steps: [KeystrokeStep],
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        let probeStart = Date()
        let summary = steps.map { step -> String in
            switch step {
            case .key(let k):    return "K(\(k))"
            case .text(let t):   return "T(\(t.count))"
            case .delay(let d):  return "d\(d)"
            }
        }.joined(separator: ",")
        Self.logger.info("sendSteps: enter sid=\(session.sessionId.prefix(8), privacy: .public) tty=\(session.tty ?? "?", privacy: .public) count=\(steps.count, privacy: .public) seq=[\(summary, privacy: .public)]")
        guard ttyName(for: session) != nil, !steps.isEmpty else {
            Self.logger.error("sendSteps: bail — ttyName=\(self.ttyName(for: session) ?? "nil", privacy: .public) empty=\(steps.isEmpty, privacy: .public)")
            return false
        }
        let tty = ttyName(for: session)!
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
                default:
                    switch sendSingleStepOutcome(
                        step,
                        ttyName: tty,
                        session: session,
                        operationID: operationID
                    ) {
                    case .accepted:
                        return .succeeded(step: "terminal-step")
                    case .provenRejected(let reason):
                        return .failedBeforeWrite(
                            step: "terminal-step",
                            reason: reason
                        )
                    case .indeterminate(let reason):
                        return .failedAfterWrite(
                            step: "terminal-step",
                            reason: reason
                        )
                    }
                }
            }
        )
        let elapsedMs = Int(Date().timeIntervalSince(probeStart) * 1000)
        Self.logger.info("sendSteps: result=\(outcome.isDelivered, privacy: .public) tty=\(tty, privacy: .public) cmdCount=\(steps.count, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
        return outcome.isDelivered
    }

    private func sendSingleStep(
        _ step: KeystrokeStep,
        ttyName: String,
        session: SessionState,
        operationID: String?
    ) -> Bool {
        sendSingleStepOutcome(
            step,
            ttyName: ttyName,
            session: session,
            operationID: operationID
        ).isAccepted
    }

    private func sendSingleStepOutcome(
        _ step: KeystrokeStep,
        ttyName: String,
        session: SessionState,
        operationID: String?
    ) -> TerminalTextDispatchResult {
        let command: String
        switch step {
        case .key(let name) where name.lowercased() == "enter" || name.lowercased() == "return":
            command = "write text \"\" newline true"
        case .key, .text:
            let bytes = Self.iTermBytes(for: step)
            guard !bytes.isEmpty else {
                return .provenRejected(reason: "The iTerm2 step was empty.")
            }
            let escaped = AppleScriptEscaper.escape(bytes)
            command = "write text \"\(escaped)\" newline false"
        case .delay:
            return .accepted
        }
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    \(command)
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        guard TerminalProcessIdentityResolver.isVerified(session) else {
            return .provenRejected(reason: "The iTerm2 target was not verified before the step.")
        }
        return runAppleScriptOutcome(script, operationID: operationID)
    }

    /// Map a step to the bytes iTerm2's `write text` will deliver as that
    /// keystroke. Arrow keys use VT/CSI sequences that Ink reads as the
    /// equivalent named keys.
    private static func iTermBytes(for step: KeystrokeStep) -> String {
        switch step {
        case .text(let raw):
            return raw
        case .key(let name):
            switch name.lowercased() {
            case "up", "arrowup":       return "\u{1b}[A"
            case "down", "arrowdown":   return "\u{1b}[B"
            case "right", "arrowright": return "\u{1b}[C"
            case "left", "arrowleft":   return "\u{1b}[D"
            case "enter", "return":     return "\r"
            case "tab":                 return "\t"
            case "space":               return " "
            case "escape", "esc":       return "\u{1b}"
            case "backspace":           return "\u{7f}"
            default:                    return ""
            }
        case .delay:
            // Delays don't contribute to the byte stream; sendSteps
            // splits the run into separate `write text` calls around
            // them. Routed here only when called directly on a non-
            // delay step elsewhere; harmless empty contribution here.
            return ""
        }
    }

    /// Send the ESC key to cancel claude-code's TUI question UI.
    /// `write text ""` writes the ESC character, treated as a real
    /// keypress by Ink-based TUIs.
    func sendEscape(
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    write text (ASCII character 27) newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        return runAppleScriptOutcome(script, operationID: operationID).isAccepted
    }

    /// Deliver `payload` as a bracketed paste to the matching iTerm2
    /// session — wraps the payload in CSI 200~ / 201~ markers and
    /// writes through iTerm2's raw `write text` channel. Used for
    /// image paste: claude-code's DECSET 2004 handler recognizes the
    /// markers and reads the path as a file attachment instead of
    /// typed text.
    func sendBracketedPaste(
        _ payload: String,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              TerminalTextPolicy.canSend(payload) else { return false }
        guard let ttyName = ttyName(for: session) else { return false }
        let script = ITermSessionLocator.bracketedPasteScript(
            ttyName: ttyName,
            payload: payload
        )
        return ITermSessionLocator.parseSelectOutput(
            runAppleScriptOutput(script, operationID: operationID)
        )
    }

    /// Send Ctrl+U (NAK, 0x15) to clear Claude Code's TUI input buffer in
    /// one keystroke. Note: empirically (2026-05-30) this does NOT
    /// reach Claude Code's Ink-based input field — iTerm's `write text`
    /// is user-input emulation, not a raw PTY write, and Claude Code's
    /// TUI doesn't interpret NAK as kill-to-start-of-line. Kept for
    /// callers that still expect this method, but `sendBackspaces`
    /// is the path that actually clears the buffer.
    func sendCtrlU(
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let escaped = AppleScriptEscaper.escape("\u{15}")
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    write text "\(escaped)" newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        return runAppleScriptOutcome(script, operationID: operationID).isAccepted
    }

    /// Send `count` DEL bytes (0x7F) via iTerm's `write text` to
    /// delete leftover input from Claude Code's TUI buffer after an
    /// ESC-cancel. macOS terminals classically map the user's
    /// "delete-left" key to DEL (0x7F), not backspace (0x08). Ink's
    /// input field listens for DEL — empirical: 0x08 is silently
    /// dropped, 0x7F deletes one char.
    func sendBackspaces(
        count: Int,
        toSession session: SessionState,
        operationID: String? = nil
    ) -> Bool {
        guard count > 0,
              TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else { return false }
        let payload = String(repeating: "\u{7F}", count: count)
        let escaped = AppleScriptEscaper.escape(payload)
        let script = """
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s ends with "\(ttyName)" then
                                tell s
                                    write text "\(escaped)" newline false
                                end tell
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            return "fail"
        end tell
        """
        return runAppleScriptOutcome(script, operationID: operationID).isAccepted
    }

    func focusSession(_ session: SessionState) -> Bool {
        let sid4 = String(session.sessionId.prefix(4))
        guard TerminalProcessIdentityResolver.isVerified(session),
              let ttyName = ttyName(for: session) else {
            Self.pillNavLog.notice("iterm focus sid=\(sid4, privacy: .public) result=fail reason=noTTYName rawTTY=\(session.tty ?? "nil", privacy: .public)")
            return false
        }
        guard let app = TerminalHostActivator.activateAndWait(
            bundleIdentifier: "com.googlecode.iterm2"
        ) else {
            Self.pillNavLog.notice("iterm focus sid=\(sid4, privacy: .public) result=fail reason=activation")
            return false
        }
        Self.pillNavLog.notice("iterm focus sid=\(sid4, privacy: .public) ttyName=\(ttyName, privacy: .public) (matching against suffix of iTerm2 session.tty)")

        // Diagnostic: confirm the TTY is currently attached to the
        // expected PID (session.pid) and enumerate ALL iTerm2 panes'
        // TTYs so we can see suffix-collision (e.g. /dev/ttys005 vs
        // /dev/ttys1005 both end with "ttys005").
        Self.logTTYOwners(for: ttyName, expectedPID: session.pid, sid4: sid4)
        Self.logAllItermPaneTTYs(matching: ttyName, sid4: sid4)

        // Two-pass: enumerate via numeric indices to capture
        // (window-id, tab-index, session-id), then re-resolve those
        // ids in fresh `whose id is …` specifiers and dispatch
        // `select` through them.
        //
        // Why two passes: `repeat with s in sessions of t` binds `s`
        // to a *partial enumeration descriptor* (something AppleScript
        // resolves on each access as "item N of every session of every
        // tab of every window"). Telling that descriptor to `select`
        // intermittently dispatches at the wrong receiver level — on
        // tabs with split panes the tab's `select` handler swallows
        // the call and split focus stays on whichever pane was
        // already active. Re-resolving each id with `first … whose
        // id is …` produces a *direct* specifier that AppleScript
        // dispatches unambiguously to the SESSION handler, which is
        // the one that actually moves visual split-pane focus.
        // Confirmed at REPL with a tab containing 8 splits across
        // a window switch: `current session` reports the target tty
        // post-chain. The pre-fix loop-variable form passed the same
        // probe roughly half the time.
        let script = """
        tell application "iTerm"
            set foundWid to missing value
            set foundTidx to 0
            set foundSid to ""
            set wCount to count of windows
            repeat with wi from 1 to wCount
                set w to window wi
                set tCount to count of tabs of w
                repeat with ti from 1 to tCount
                    set t to tab ti of w
                    set sCount to count of sessions of t
                    repeat with si from 1 to sCount
                        set s to session si of t
                        try
                            if (tty of s as string) ends with "\(ttyName)" then
                                set foundWid to id of w
                                set foundTidx to ti
                                set foundSid to id of s
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            if foundWid is missing value then return "fail"
            set targetW to first window whose id is foundWid
            set targetT to tab foundTidx of targetW
            set targetS to first session of targetT whose id is foundSid
            select targetW
            tell targetW to select targetT
            tell targetS to select
            return "ok"
        end tell
        """
        let result = runAppleScriptOutput(script)
        let selectedTargetMatches = result == "ok"
            && Self.currentItermSessionMatches(expectedTTY: ttyName, sid4: sid4)
        let hostIsFrontmost = TerminalHostActivator.isFrontmost(app)
        let success = TerminalFocusVerificationPolicy.isSuccessful(
            selectedTargetMatches: selectedTargetMatches,
            hostIsFrontmost: hostIsFrontmost
        )
        Self.pillNavLog.notice("iterm focus sid=\(sid4, privacy: .public) ttyName=\(ttyName, privacy: .public) selected=\(selectedTargetMatches) frontmost=\(hostIsFrontmost) result=\(success ? "ok" : "fail", privacy: .public)")
        if !success {
            Self.logger.info("focusSession: focus verification failed for tty=\(ttyName, privacy: .public)")
        }
        return success
    }

    // MARK: - Helpers

    /// Strip the "/dev/" prefix so the AppleScript suffix-match works for
    /// both "ttys012" (raw) and "/dev/ttys012" (full path).
    private func ttyName(for session: SessionState) -> String? {
        guard let tty = session.tty, !tty.isEmpty else { return nil }
        if tty.hasPrefix("/dev/") {
            return String(tty.dropFirst("/dev/".count))
        }
        return tty
    }

    // MARK: - Diagnostic helpers (PillNav)

    /// Log the PIDs currently attached to /dev/<ttyName>. If
    /// expectedPID isn't in the list, the session record's TTY is
    /// stale (the original process exited; pty reused). If the list
    /// has multiple unrelated PIDs, something else is wrong.
    private static func logTTYOwners(for ttyName: String, expectedPID: Int?, sid4: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-t", "--", "/dev/\(ttyName)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let pids = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").map(String.init)
            let expectedDesc = expectedPID.map(String.init) ?? "nil"
            let attached = pids.joined(separator: ",")
            let match = expectedPID.map { pids.contains(String($0)) } ?? false
            pillNavLog.notice("iterm tty-owner sid=\(sid4, privacy: .public) tty=\(ttyName, privacy: .public) expectedPID=\(expectedDesc, privacy: .public) attachedPIDs=[\(attached, privacy: .public)] expectedAttached=\(match, privacy: .public)")
        } catch {
            pillNavLog.notice("iterm tty-owner sid=\(sid4, privacy: .public) tty=\(ttyName, privacy: .public) lsofError=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Enumerate every iTerm2 pane's tty AND its visible name/title,
    /// so we can detect cases where iTerm2's `tty` property has gone
    /// stale (the pane visually displays one project but reports
    /// another tty, or vice versa).
    private static func logAllItermPaneTTYs(matching ttyName: String, sid4: String) {
        let script = """
        tell application "iTerm"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sName to ""
                            try
                                set sName to (name of s)
                            end try
                            set out to out & (tty of s) & "::" & sName & "|"
                        end try
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // entries are "<tty>::<name>" separated by "|"
            let allEntries = raw.split(separator: "|").map(String.init)
            // Filter on tty suffix. Each entry's tty is everything
            // before the "::" separator.
            let matching = allEntries.filter { entry in
                let tty = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? entry
                return tty.hasSuffix(ttyName)
            }
            pillNavLog.notice("iterm panes sid=\(sid4, privacy: .public) all=[\(allEntries.joined(separator: " | "), privacy: .public)] matchingSuffix=\(ttyName, privacy: .public) -> [\(matching.joined(separator: " | "), privacy: .public)] (matchCount=\(matching.count, privacy: .public))")
        } catch {
            pillNavLog.notice("iterm panes sid=\(sid4, privacy: .public) ascriptError=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask iTerm2 what its actual "current session" is after our
    /// `select` ran. If iTerm reports a tty/name different from what
    /// we selected, `select s` was overridden — most likely by split
    /// panes (the tab's selected session ≠ the visually dominant
    /// pane) or a tmux-mirrored layout.
    private static func currentItermSessionMatches(expectedTTY: String, sid4: String) -> Bool {
        let script = """
        tell application "iTerm"
            try
                set w to current window
                set t to current tab of w
                set s to current session of t
                set sName to ""
                try
                    set sName to (name of s)
                end try
                set sTTY to ""
                try
                    set sTTY to (tty of s)
                end try
                -- count siblings: how many sessions in this tab?
                set sibCount to 0
                try
                    set sibCount to (count of sessions of t)
                end try
                return sTTY & "::" & sName & "::sib=" & sibCount
            on error eMsg
                return "error::" & eMsg
            end try
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // iTerm reports its "current session" as the user-visible
            // active pane. If `expectedTTY` (what we tried to focus)
            // doesn't match the tty in `raw`, the select was
            // overridden by a parallel pane in the same tab.
            let matches = raw.contains(expectedTTY)
            pillNavLog.notice("iterm post-select sid=\(sid4, privacy: .public) expectedTTY=\(expectedTTY, privacy: .public) currentSession=\(raw, privacy: .public) match=\(matches, privacy: .public)")
            return matches
        } catch {
            pillNavLog.notice("iterm post-select sid=\(sid4, privacy: .public) expectedTTY=\(expectedTTY, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func executeAppleScript(
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
    private func runAppleScriptOutcome(
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
                return .provenRejected(reason: "The iTerm2 script rejected the target before write.")
            default:
                return .indeterminate(
                    reason: output.isEmpty
                        ? "The iTerm2 script returned no dispatch result."
                        : "The iTerm2 script returned an unexpected dispatch result."
                )
            }
        case .failure(let error):
            return .indeterminate(reason: error.localizedDescription)
        }
    }

    /// Compatibility output used only by focus/diagnostic scripts whose
    /// result is not a text-dispatch acknowledgement.
    private func runAppleScriptOutput(
        _ source: String,
        operationID: String? = nil
    ) -> String {
        switch executeAppleScript(source, operationID: operationID) {
        case .success(let result):
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .failure:
            return ""
        }
    }
}
