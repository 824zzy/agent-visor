//
//  ITermModeProbe.swift
//  AgentVisor
//
//  iTerm2 counterpart of GhosttyModeProbe. Reads the visible-viewport
//  text of an iTerm2 session via AppleScript and decodes (a) Claude
//  Code's mode badge for the live chip refresh, or (b) the raw text
//  for the AskUserQuestion AX backfill.
//
//  Unlike Ghostty (which needs an AX-tree walk + frontmost-only AXText
//  reads), iTerm2 exposes `contents` directly on each session via
//  AppleScript — works regardless of frontmost status, doesn't
//  switch Space.
//

import AgentVisorCore
import Foundation
import os.log

enum ITermModeProbe {
    nonisolated private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ITermModeProbe")

    nonisolated static func currentMode(for session: SessionState) -> String? {
        guard let text = visibleContents(for: session) else {
            logger.info("probe: no match sid=\(session.sessionId.prefix(8), privacy: .public)")
            return nil
        }
        let mode = ModeBadgeParser.parse(text)
        let tailSample = text.suffix(160)
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\u{1B}", with: "⎋")
        logger.info("probe: mode=\(mode ?? "nil", privacy: .public) textLen=\(text.count, privacy: .public) tail=[\(tailSample, privacy: .public)] for \(session.sessionId.prefix(8), privacy: .public)")
        return mode
    }

    nonisolated static func readScrollback(for session: SessionState) -> String? {
        guard let text = visibleContents(for: session) else {
            logger.info("scrollback: no match sid=\(session.sessionId.prefix(8), privacy: .public)")
            return nil
        }
        logger.info("scrollback: read \(text.count, privacy: .public) chars for \(session.sessionId.prefix(8), privacy: .public)")
        return text
    }

    nonisolated private static func visibleContents(for session: SessionState) -> String? {
        guard let tty = session.tty, !tty.isEmpty else { return nil }
        let script = ITermSessionLocator.contentsScript(
            ttyName: ITermSessionLocator.normalizeTTY(tty)
        )
        let raw = runAppleScript(script)
        return ITermSessionLocator.parseContentsOutput(raw)
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
