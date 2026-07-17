//
//  PermissionModeCycler.swift
//  AgentVisor
//
//  Cycles Claude Code's permission mode for a session by sending Shift+Tab.
//
//  Routing:
//    - Tmux sessions: `tmux send-keys -t <target> BTab`. Direct to pane,
//      no focus shift.
//    - Non-tmux Ghostty: AX-based focus + CGEvent keystroke. We raise
//      the matching Ghostty window and focus its terminal pane via the
//      Accessibility API, activate Ghostty as the frontmost app via
//      NSRunningApplication, then post Shift+Tab through CGEvent. No
//      AppleScript is involved, so macOS never asks the user for
//      "Agent Visor wants access to control Ghostty" or "control
//      System Events" — only Accessibility, which the user already
//      granted for this feature.
//
//  Cooldown: 400ms backstop against held-key auto-repeat that can
//  bypass `event.isARepeat` when focus changes reset the OS's repeat
//  tracker, and to keep two focus dances from overlapping their
//  activate/post sequences.
//

import AppKit
import ApplicationServices
import AgentVisorCore
import CoreGraphics
import Foundation
import os.log

enum PermissionModeCycler {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "PermissionModeCycler")
    private static let cooldownInterval: TimeInterval = 0.4
    private static var lastCycleAt: Date = .distantPast

    /// Tab and (left) Shift virtual key codes on Apple keyboards. We
    /// post Shift as its own keydown/keyup envelope around the tab so
    /// the modifier-state machine in the receiving app is consistent —
    /// Ghostty silently dropped tab-with-flag events that lacked the
    /// explicit shift envelope.
    private static let tabKey: CGKeyCode = 0x30
    private static let shiftKey: CGKeyCode = 0x38
    private static let ghosttyBundleID = "com.mitchellh.ghostty"
    private static let itermBundleID = "com.googlecode.iterm2"

    /// Send Shift+Tab to the session.
    @discardableResult
    static func cycle(session: SessionState) async -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastCycleAt) < cooldownInterval {
            return false
        }
        lastCycleAt = now

        // Optimistically update the chip with the predicted next mode so
        // the user sees feedback immediately. Claude Code's JSONL
        // snapshot can lag many seconds, so without this the chip looks
        // broken. The cycle table lives in `AgentVisorCore` (single
        // source of truth, unit-tested) and deliberately skips `auto`
        // because it's enterprise-gated — predicting `auto` after `plan`
        // mispredicts on Bedrock/Vertex/standard Anthropic API. See
        // `PermissionModeCycle.swift` for the full rationale.
        //
        // An observed-transitions map was tempting (it could "learn" the
        // user's config) but is unreliable: JSONL only writes a mode
        // line on prompt submission, so a sequence like plan → auto →
        // default → acceptEdits between two submissions looks like
        // "plan → acceptEdits" to the parser, which then poisons the
        // map and makes the chip flash through wrong intermediate
        // modes on subsequent cycles.
        if let current = session.permissionMode,
           let predicted = predictedNext(after: current) {
            await SessionStore.shared.applyOptimisticMode(sessionId: session.sessionId, mode: predicted)
        }

        if session.isInTmux, let pid = session.pid,
           let target = await TmuxTargetFinder.shared.findTarget(forClaudePid: pid) {
            return await sendTmuxBackTab(target: target)
        }

        if TerminalAdapterRegistry.adapter(for: session) is ITermAdapter {
            return await postShiftTabToIterm(session: session)
        }

        return await postShiftTabToGhosttyViaAX(session: session)
    }

    /// Forwarding seam onto `AgentVisorCore.PermissionModeCycle.next`.
    /// Exists as a named method (rather than calling Core inline in
    /// `cycle`) so a regression that reintroduces a local switch table
    /// has somewhere obvious to NOT go: the only correct change to
    /// prediction behavior is in Core, where the cycle is unit-tested
    /// across Bedrock/Vertex/standard-API and enterprise scenarios.
    /// Internal so the Core test suite can't reach it; the contract
    /// being guarded is "the cycler delegates to Core", not the cycle
    /// itself.
    static func predictedNext(after current: String) -> String? {
        PermissionModeCycle.next(after: current)
    }

    private static func sendTmuxBackTab(target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            logger.warning("No tmux executable")
            return false
        }
        do {
            _ = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["send-keys", "-t", target.targetString, "BTab"]
            )
            return true
        } catch {
            logger.error("tmux send-keys failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Deterministically locate the session's Ghostty pane via an OSC 7
    /// marker, silently focus it (Ghostty's `focus terminal` selects the
    /// pane without activating the app — verified, see memory
    /// `feedback_terminal_activate.md`), and post Shift+Tab through
    /// CGEvent.postToPid. No NSApp.deactivate, no app.activate, no
    /// AXRaise — the user's Space, frontmost app, and focused window
    /// stay exactly where they are.
    private static func postShiftTabToGhosttyViaAX(session: SessionState) async -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == ghosttyBundleID
        }) else {
            logger.warning("Ghostty not running")
            return false
        }

        let focused = await Task.detached(priority: .userInitiated) {
            focusSessionPane(session)
        }.value
        if !focused {
            logger.warning("could not locate/focus pane for session=\(session.sessionId.prefix(8), privacy: .public)")
            return false
        }

        // Brief settle for Ghostty to process the focus change before
        // we synthesise the keystroke.
        try? await Task.sleep(nanoseconds: 50_000_000)
        postShiftTabKeystrokes(to: app.processIdentifier)
        await SessionStore.shared.markCycleTimestamp(sessionId: session.sessionId)
        return true
    }

    /// iTerm2 counterpart: TTY suffix-match locates the session
    /// directly (iTerm2 exposes `tty` on its session object — no OSC 7
    /// trick needed), `select` silently focuses the pane without
    /// raising the app (verified, see `feedback_terminal_activate.md`),
    /// then postToPid delivers Shift+Tab to the focused pane.
    private static func postShiftTabToIterm(session: SessionState) async -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == itermBundleID
        }) else {
            logger.warning("iTerm2 not running")
            return false
        }

        let selected = await Task.detached(priority: .userInitiated) {
            selectItermSession(session)
        }.value
        if !selected {
            logger.warning("could not select iTerm2 session sid=\(session.sessionId.prefix(8), privacy: .public)")
            return false
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        postShiftTabKeystrokes(to: app.processIdentifier)
        await SessionStore.shared.markCycleTimestamp(sessionId: session.sessionId)
        return true
    }

    nonisolated private static func selectItermSession(_ session: SessionState) -> Bool {
        guard let tty = session.tty, !tty.isEmpty else { return false }
        let script = ITermSessionLocator.selectScript(
            ttyName: ITermSessionLocator.normalizeTTY(tty)
        )
        return ITermSessionLocator.parseSelectOutput(runAppleScript(script))
    }

    /// Post the four-event Shift+Tab envelope directly to the target
    /// process. `postToPid` bypasses the system event-tap routing,
    /// which Tahoe filters for synthetic events; sending directly to
    /// the process delivers the events regardless of tap-level filters
    /// and regardless of whether the app is frontmost. Explicit
    /// shift-down/up frame the tab keys because both Ghostty and
    /// iTerm2 drop tab-with-flag events that lack the envelope.
    private static func postShiftTabKeystrokes(to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let events: [(CGKeyCode, Bool, CGEventFlags)] = [
            (shiftKey, true,  []),
            (tabKey,   true,  .maskShift),
            (tabKey,   false, .maskShift),
            (shiftKey, false, []),
        ]
        for (key, down, flags) in events {
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            event.postToPid(pid)
        }
    }

    /// Set an OSC 7 marker on the session's TTY, ask Ghostty (via
    /// AppleScript) which terminal has that cwd, then `focus` that
    /// terminal in-place. Restores the original cwd on every return
    /// path so Ghostty's `working directory` property tracks reality
    /// for the user's next interaction. Returns true on a successful
    /// match + focus; false if any step fails (TTY missing, Ghostty
    /// can't find the marker, AppleScript fails).
    nonisolated private static func focusSessionPane(_ session: SessionState) -> Bool {
        guard let tty = session.tty, !tty.isEmpty else { return false }
        let ttyPath = "/dev/\(tty)"
        let originalCwd = session.cwd
        let marker = GhosttyMarkerLocator.makeMarker()

        guard writeOSC7(GhosttyMarkerLocator.osc7Sequence(cwd: marker), to: ttyPath) else {
            return false
        }
        // Restore on every exit so the user's terminal isn't left with
        // a `/tmp/av-cycle-…` cwd in Ghostty's internal state.
        defer { _ = writeOSC7(GhosttyMarkerLocator.osc7Sequence(cwd: originalCwd), to: ttyPath) }

        // Ghostty needs a tick to parse the OSC 7 bytes before the
        // AppleScript query reads the updated property.
        usleep(300_000)

        let escapedMarker = marker
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(escapedMarker)" then
                            focus t
                            return "ok"
                        end if
                    end try
                end repeat
            end repeat
            return "not-found"
        end tell
        """
        let result = runAppleScript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        if result != "ok" {
            logger.info("focusSessionPane: result=\(result, privacy: .public) sid=\(session.sessionId.prefix(8), privacy: .public)")
        }
        return result == "ok"
    }

    nonisolated private static func writeOSC7(_ sequence: String, to ttyPath: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: ttyPath),
              let data = sequence.data(using: .utf8) else { return false }
        handle.write(data)
        handle.closeFile()
        return true
    }

    nonisolated private static func runAppleScript(_ source: String) -> String {
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
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
