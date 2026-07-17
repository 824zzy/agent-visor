//
//  GhosttyModeProbe.swift
//  AgentVisor
//
//  Reads the current Claude Code permission mode from Ghostty's terminal
//  text via Accessibility. Used to keep the mode chip in sync when the
//  user cycles modes via Shift+Tab in the terminal directly: Claude Code
//  doesn't write `permission-mode` to JSONL until the user submits a
//  prompt, but the mode label ("auto mode on", "accept edits on", etc.)
//  is rendered into the TUI immediately and is readable through the
//  Accessibility AXTextArea attribute.
//
//  Requires Accessibility permission (already granted for Shift+Tab
//  cycling). Polls on a per-session basis from `ChatView` while the
//  chat is open.
//

import AppKit
import ApplicationServices
import AgentVisorCore
import Foundation
import os.log

enum GhosttyModeProbe {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "GhosttyModeProbe")
    nonisolated private static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// Mode label patterns shown by Claude Code's TUI, anchored on the
    /// chevron/pause glyph that prefixes the status-line indicator. We
    /// use only the chevron + first word ("⏵⏵ accept", "⏵⏵ auto",
    /// "⏸ plan", "⏵⏵ bypass") because Ghostty's AX representation can
    /// truncate the indicator mid-word at the right edge of the
    /// visible viewport — observed in the wild as "accept edi",
    /// "plan mode o", "auto mode " — depending on terminal width and
    /// rendering state. The chevron prefix is distinctive enough to
    /// not false-match against regular chat text or scrollback that
    /// happens to contain words like "auto" or "accept".
    nonisolated private static let modePatterns: [(needle: String, mode: String)] = [
        ("⏵⏵ bypass", "bypassPermissions"),
        ("⏵⏵ accept", "acceptEdits"),
        ("⏸ plan",    "plan"),
        ("⏵⏵ auto",   "auto"),
        // Word-only fallback for bypass in case its actual chevron
        // format differs from what we guessed above.
        ("bypass permissions", "bypassPermissions"),
    ]

    /// Read the current mode from Ghostty's terminal text. Returns nil
    /// only when Ghostty isn't running or the matching terminal can't
    /// be found. When the matching pane is found but contains no
    /// recognised label, returns "default" — that's how Claude Code's
    /// TUI signals default mode (absence of any explicit indicator).
    /// Read the FULL AX text of the session's terminal pane (not the
    /// 2KB tail used by `currentMode`). Used by the AX backfill that
    /// bridges the JSONL buffering gap during a pending AskUserQuestion:
    /// claude-code holds streaming assistant text in memory until the
    /// question resolves, but the terminal has already rendered it.
    /// Returns nil if no pane matches the session or AX access fails.
    /// Cost: ~1s on a 2 MB buffer per the upstream note in `readValue`.
    /// Only call on PreToolUse for AskUserQuestion, not on every tick.
    nonisolated static func readScrollback(for session: SessionState) -> String? {
        guard let match = findMatchingTerminal(for: session),
              let text = readFullValue(of: match.area) else {
            logger.info("scrollback: no matching pane for \(session.sessionId.prefix(8), privacy: .public)")
            return nil
        }
        logger.info("scrollback: read \(text.count, privacy: .public) chars for \(session.sessionId.prefix(8), privacy: .public)")
        return text
    }

    /// Read just the trailing window of the terminal pane's AX text
    /// (the same fast path the mode probe uses, ~50 ms on a 2 MB
    /// buffer). Used by the clear-before-send check to see whether
    /// claude-code's TUI input box currently has leftover text in it.
    /// Returns nil if no matching pane is found or AX access fails.
    nonisolated static func readTailText(for session: SessionState) -> String? {
        guard let match = findMatchingTerminal(for: session),
              let text = readValue(of: match.area) else {
            return nil
        }
        return text
    }

    nonisolated static func currentMode(for session: SessionState) -> String? {
        guard let match = findMatchingTerminal(for: session),
              let text = readValue(of: match.area) else {
            logger.info("probe: no matching pane for \(session.sessionId.prefix(8), privacy: .public)")
            return nil
        }
        let mode = findLatestMode(in: text) ?? inferDefaultIfTUIActive(text)
        // Diagnostic: log the very tail of the AX text so we can see what
        // Claude Code's TUI is actually emitting for each mode. Helps
        // detect mismatched/changed mode-indicator strings.
        let tailSample = text.suffix(160)
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\u{1B}", with: "⎋")
        logger.info("probe: mode=\(mode ?? "nil", privacy: .public) textLen=\(text.count, privacy: .public) tail=[\(tailSample, privacy: .public)] for \(session.sessionId.prefix(8), privacy: .public)")
        return mode
    }

    /// Conclude default mode only when we can positively confirm
    /// Claude Code's TUI is rendering its input box. A bare text-length
    /// threshold (the previous heuristic) misclassifies "status line
    /// pushed out of the search window" as default — which surfaced as
    /// the chip getting stuck on "default" while Ghostty actually
    /// showed "⏸ plan mode on". Requiring a box-drawing char from the
    /// input box border means we say default only when we know we're
    /// looking at the active prompt area but no chevron was found.
    nonisolated private static func inferDefaultIfTUIActive(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = String(trimmed.suffix(1024))
        // Post-redesign TUI no longer draws a full box around the input
        // row — only a horizontal rule (`─`) and the prompt chevron
        // (`❯`). Keep the legacy corners/pipe for older Claude Code
        // versions still in use.
        let tuiMarkers: [Character] = ["│", "╭", "╮", "╰", "╯", "❯", "─"]
        return recent.contains(where: { tuiMarkers.contains($0) }) ? "default" : nil
    }

    /// Locate the Ghostty window + terminal pane that best matches the
    /// given Claude Code session. Used by both the mode probe (read the
    /// pane's AX text) and the cycler (raise/focus the pane before
    /// posting Shift+Tab). Pure Accessibility — no Apple Events, no
    /// authorization popup.
    nonisolated static func findMatchingTerminal(for session: SessionState) -> (window: AXUIElement, area: AXUIElement)? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == ghosttyBundleID
        }) else { return nil }

        let ghosttyAX = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ghosttyAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            logger.debug("findMatchingTerminal: no Ghostty windows")
            return nil
        }

        let markers = sessionMarkers(for: session)

        // Score each AXTextArea on how well its TAIL matches the session.
        // Match in the tail (recent context) is much stronger than a
        // match anywhere — tab/pane scrollback can contain stale CWDs
        // from prior commands.
        var bestWindow: AXUIElement?
        var bestArea: AXUIElement?
        var bestScore = 0
        var totalAreas = 0
        var totalNonEmpty = 0
        var areaSamples: [String] = []
        for window in windows {
            var areas: [AXUIElement] = []
            collectTextAreas(under: window, into: &areas)
            totalAreas += areas.count
            for area in areas {
                guard let text = readValue(of: area), !text.isEmpty else { continue }
                totalNonEmpty += 1
                let score = matchScore(text: text, markers: markers)
                if areaSamples.count < 4 {
                    let head = text.prefix(60).replacingOccurrences(of: "\n", with: "⏎")
                    let tail = text.suffix(60).replacingOccurrences(of: "\n", with: "⏎")
                    areaSamples.append("len=\(text.count) score=\(score) head=\(head) tail=\(tail)")
                }
                if score > bestScore {
                    bestScore = score
                    bestWindow = window
                    bestArea = area
                }
            }
        }
        if bestWindow == nil {
            let markerJoined = markers.joined(separator: "|")
            logger.info("findMatchingTerminal: no match windows=\(windows.count, privacy: .public) areas=\(totalAreas, privacy: .public) nonEmpty=\(totalNonEmpty, privacy: .public) markers=\(markerJoined, privacy: .public)")
            for sample in areaSamples {
                logger.info("  area: \(sample, privacy: .public)")
            }
        }
        guard let w = bestWindow, let a = bestArea else { return nil }
        return (w, a)
    }

    // MARK: - Helpers

    nonisolated private static func sessionMarkers(for session: SessionState) -> [String] {
        var out: [String] = []
        if let name = session.sessionName, !name.isEmpty {
            out.append(name)
        }
        if !session.cwd.isEmpty {
            out.append(session.cwd)
        }
        let last = (session.cwd as NSString).lastPathComponent
        if !last.isEmpty {
            out.append(last)
        }
        return out
    }

    /// Score an AXTextArea's content against the session's markers.
    /// Tail matches (last 1KB) outweigh anywhere matches because old
    /// scrollback can mention any cwd while the current prompt prefix
    /// reflects the active session.
    nonisolated private static func matchScore(text: String, markers: [String]) -> Int {
        let tailLen = min(text.count, 1024)
        let tail = String(text.suffix(tailLen))
        var score = 0
        for m in markers {
            if tail.contains(m) {
                score += 5
            } else if text.contains(m) {
                score += 1
            }
        }
        return score
    }

    /// Hard cap on AX nodes visited during the textarea walk. After sleep/
    /// wake, Ghostty's AX tree can return inconsistent state with cycles
    /// or pathological depth — observed in a real crash report where
    /// recursion went ~970 levels deep and blew the 8 MB stack with
    /// SIGBUS on the guard page. An iterative walk with a node cap is
    /// immune to both depth and cycles.
    nonisolated private static let maxAXNodesPerWalk = 5000

    /// Iteratively collects every AXTextArea descendant. Replaces the
    /// previous recursive implementation which could stack-overflow on
    /// pathological AX trees. The walk is depth-first to match the prior
    /// traversal order; `nextChildren` is appended to the front of the
    /// queue so siblings are visited left-to-right.
    nonisolated private static func collectTextAreas(under root: AXUIElement, into out: inout [AXUIElement]) {
        var stack: [AXUIElement] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < maxAXNodesPerWalk {
            visited += 1

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == kAXTextAreaRole {
                out.append(element)
                continue
            }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else {
                continue
            }
            // Reverse-append so popLast() yields children in original order.
            stack.append(contentsOf: children.reversed())
        }
        if visited >= maxAXNodesPerWalk {
            logger.warning("collectTextAreas hit node cap (\(maxAXNodesPerWalk, privacy: .public)); AX tree may have a cycle or pathological depth")
        }
    }

    /// Read the AX text of a terminal pane, but only the *tail* — the
    /// last `maxTailChars` characters. Ghostty's full AX value can be
    /// 2 MB+ for a long session; reading all of it over XPC takes
    /// ~1 second per pane, which drags the cycle's AX dance long
    /// enough that probe ticks during it cause jitter. The tail is all
    /// the probe and the cwd-match scoring actually look at.
    nonisolated private static let maxTailChars = 2048

    nonisolated private static func readValue(of element: AXUIElement) -> String? {
        // Total length first — small, cheap call.
        var lengthRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &lengthRef) == .success,
              let total = (lengthRef as? Int) ?? (lengthRef as? NSNumber)?.intValue else {
            // Fall back to full read if length isn't available.
            return readFullValue(of: element)
        }
        if total <= maxTailChars {
            return readFullValue(of: element)
        }
        let start = total - maxTailChars
        var range = CFRange(location: start, length: maxTailChars)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            return readFullValue(of: element)
        }
        var stringRef: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringRef
        )
        guard result == .success, let str = stringRef as? String else {
            return readFullValue(of: element)
        }
        return str
    }

    nonisolated private static func readFullValue(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let str = valueRef as? String else {
            return nil
        }
        return str
    }

    /// Scan from the end of the buffer for the most recent mode label.
    /// "default" mode shows no explicit label, so absence of any
    /// indicator near the end implies default (gated by the TUI-active
    /// check in `inferDefaultIfTUIActive`).
    ///
    /// We trim trailing whitespace before applying the window because
    /// Ghostty's AX text can include empty rows below the rendered
    /// status line (terminal padding, cursor parking position) that
    /// otherwise push the chevron out of view. The window itself is
    /// wide enough (1024) to cover Claude Code's two-line status
    /// display (model/usage line + mode indicator) on wide terminals,
    /// but not so wide that we'd reach into ancient scrollback —
    /// `readValue` already capped the input at 2048 chars.
    nonisolated private static func findLatestMode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let windowSize = min(trimmed.count, 1024)
        let tailStart = trimmed.index(trimmed.endIndex, offsetBy: -windowSize)
        let tail = String(trimmed[tailStart...])

        var best: (range: Range<String.Index>, mode: String)?
        for (needle, mode) in modePatterns {
            if let range = tail.range(of: needle, options: .backwards) {
                if best == nil || range.lowerBound > best!.range.lowerBound {
                    best = (range, mode)
                }
            }
        }
        if best == nil {
            // Aid debugging the default-mode case: show what's at the
            // end so we can spot whether Claude Code prints any
            // recognisable indicator we should pattern-match.
            let sample = tail.suffix(120).replacingOccurrences(of: "\n", with: "⏎")
            logger.debug("no mode label in tail; sample=\(sample, privacy: .public)")
        }
        return best?.mode
    }
}
