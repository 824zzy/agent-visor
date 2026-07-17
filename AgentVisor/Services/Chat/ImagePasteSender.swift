//
//  ImagePasteSender.swift
//  AgentVisor
//
//  Writes user-pasted images to a temp file and delivers them to a Claude
//  Code session using the terminal's bracketed-paste protocol, matching
//  what Claude Code expects when a user pastes an image file path into its
//  input box.
//
//  Two transports:
//    - Tmux: `tmux load-buffer ... | tmux paste-buffer -p` so tmux itself
//      wraps the path with bracketed-paste markers the inner pane requested.
//    - Direct Ghostty/any pty: write `ESC[200~<path>ESC[201~` straight to
//      the session's /dev/ttysXXX. Claude Code has DECSET 2004 enabled so
//      it recognizes the sequence and reads the file from disk.
//
//  Bypassing AppleScript `input text` / keystroke simulation keeps the
//  user's clipboard untouched and avoids focus-stealing.
//

import AppKit
import AgentVisorCore
import Foundation
import os.log

enum ImagePasteSender {
    static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ImagePaste")

    /// Directory for transit PNG files. Claude Code reads from this path and
    /// caches the bytes under ~/.claude/image-cache, so the temp copy is only
    /// needed for the brief window between paste and Claude Code's file read.
    static let tempDir: URL = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(AppPaths.pasteTempDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Encode an NSImage as PNG and save to a uniquely-named temp file.
    /// Filenames use a UUID (no spaces) so Claude Code's path parser accepts them.
    static func savePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let url = tempDir.appendingPathComponent("av-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            logger.error("Failed to write PNG: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Remove temp files older than 5 minutes. Called on app launch.
    static func cleanupStaleFiles() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-5 * 60)
        guard let files = try? fm.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            if let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate,
               modDate < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Deliver a file path to the session as a bracketed paste, so Claude
    /// Code's paste handler picks it up and reads the image from disk.
    static func sendPaste(path: String, session: SessionState) async -> Bool {
        if session.isInTmux, let tty = session.tty,
           let target = await findTmuxTargetByTTY(tty) {
            logger.info("paste via tmux \(target.targetString, privacy: .public)")
            return await sendViaTmux(path: path, target: target)
        }
        // iTerm2: write the CSI 200~/201~ bracketed-paste envelope through
        // its raw `write text` channel — Claude Code's DECSET 2004 handler
        // reads the wrapped path as a file attachment, same as Ghostty's
        // `input text` produces auto-wrapped paste markers.
        if TerminalAdapterRegistry.adapter(for: session) is ITermAdapter {
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = ITermAdapter().sendBracketedPaste(path, toSession: session)
                    continuation.resume(returning: result)
                }
            }
            logger.info("paste via iTerm2 bracketed paste: \(ok, privacy: .public)")
            return ok
        }
        // Non-tmux, non-iTerm2 (Ghostty + unknown): Ghostty's `input text`
        // is documented as "Input text to a terminal as if it was pasted" —
        // it wraps with bracketed-paste markers itself. Send the raw path;
        // Claude Code sees the bracketed-paste, matches the .png extension,
        // and reads the file from disk.
        let ok = await sendViaGhosttyInput(text: path, session: session)
        logger.info("paste via Ghostty input text: \(ok, privacy: .public)")
        return ok
    }

    /// Send just an Enter keypress (used when an image-only message has no text).
    static func sendEnter(session: SessionState) async -> Bool {
        if session.isInTmux, let tty = session.tty,
           let target = await findTmuxTargetByTTY(tty) {
            guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
            do {
                _ = try await ProcessExecutor.shared.run(
                    tmuxPath,
                    arguments: ["send-keys", "-t", target.targetString, "Enter"]
                )
                return true
            } catch {
                return false
            }
        }
        if TerminalAdapterRegistry.adapter(for: session) is ITermAdapter {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = ITermAdapter().sendSteps([.key("enter")], toSession: session)
                    continuation.resume(returning: result)
                }
            }
        }
        return await sendGhosttyEnter(session: session)
    }

    // MARK: - Tmux

    private static func sendViaTmux(path: String, target: TmuxTarget) async -> Bool {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return false }
        let bufferName = "av-img-\(UUID().uuidString.prefix(8))"
        do {
            try await loadTmuxBuffer(tmuxPath: tmuxPath, bufferName: String(bufferName), data: path)
            _ = try await ProcessExecutor.shared.run(tmuxPath, arguments: [
                "paste-buffer", "-p", "-b", String(bufferName),
                "-t", target.targetString, "-d"
            ])
            return true
        } catch {
            logger.error("tmux paste failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// `tmux load-buffer -b <name> -` reads the buffer contents from stdin.
    /// We can't reuse ProcessExecutor because it doesn't expose stdin.
    private static func loadTmuxBuffer(tmuxPath: String, bufferName: String, data: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = Process()
            let stdinPipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["load-buffer", "-b", bufferName, "-"]
            proc.standardInput = stdinPipe
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                if let bytes = data.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(bytes)
                }
                try? stdinPipe.fileHandleForWriting.close()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ProcessExecutorError.executionFailed(
                        command: "tmux load-buffer",
                        exitCode: proc.terminationStatus,
                        stderr: nil
                    ))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func findTmuxTargetByTTY(_ tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else { return nil }
        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F",
                            "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )
            for line in output.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: " ")
                if parts.count >= 2 {
                    let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")
                    if paneTty == tty {
                        return TmuxTarget(from: parts[0])
                    }
                }
            }
        } catch { }
        return nil
    }

    // MARK: - Ghostty (non-tmux)

    /// Send plain text to the session's Ghostty terminal via `input text`,
    /// which wraps with bracketed-paste markers automatically (it's documented
    /// as "Input text to a terminal as if it was pasted"). Target the right
    /// pane using the same CWD + OSC 7 marker logic as GhosttyScripting.
    private static func sendViaGhosttyInput(text: String, session: SessionState) async -> Bool {
        guard let tty = session.tty else { return false }
        let ttyPath = "/dev/\(tty)"
        let cwd = session.cwd

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if pasteViaCWDMatch(text: text, cwd: cwd) {
                    continuation.resume(returning: true)
                    return
                }
                let ok = pasteViaOSC7Marker(text: text, ttyPath: ttyPath, originalCwd: cwd)
                continuation.resume(returning: ok)
            }
        }
    }

    private static func sendGhosttyEnter(session: SessionState) async -> Bool {
        guard let tty = session.tty else { return false }
        let ttyPath = "/dev/\(tty)"
        let cwd = session.cwd

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if enterViaCWDMatch(cwd: cwd) {
                    continuation.resume(returning: true)
                    return
                }
                let ok = enterViaOSC7Marker(ttyPath: ttyPath, originalCwd: cwd)
                continuation.resume(returning: ok)
            }
        }
    }

    private static func pasteViaCWDMatch(text: String, cwd: String) -> Bool {
        let escapedCwd = appleScriptEscape(cwd)
        let escapedText = appleScriptEscape(text)
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
                input text "\(escapedText)" to (terminal id targetId)
                return "ok"
            else
                return "fail"
            end if
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func pasteViaOSC7Marker(text: String, ttyPath: String, originalCwd: String) -> Bool {
        let marker = "/tmp/av_img_\(UInt32.random(in: 100000...999999))"
        let oscSet = "\u{1b}]7;file://localhost\(marker)\u{07}"
        guard let h = FileHandle(forWritingAtPath: ttyPath),
              let d = oscSet.data(using: .utf8) else {
            return false
        }
        h.write(d)
        h.closeFile()
        usleep(300000)

        let escapedText = appleScriptEscape(text)
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
        let result = runAppleScript(script)

        let oscRestore = "\u{1b}]7;file://localhost\(originalCwd)\u{07}"
        if let rh = FileHandle(forWritingAtPath: ttyPath),
           let rd = oscRestore.data(using: .utf8) {
            rh.write(rd)
            rh.closeFile()
        }
        return result == "ok"
    }

    private static func enterViaCWDMatch(cwd: String) -> Bool {
        let escapedCwd = appleScriptEscape(cwd)
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
                send key "enter" to (terminal id targetId)
                return "ok"
            else
                return "fail"
            end if
        end tell
        """
        return runAppleScript(script) == "ok"
    }

    private static func enterViaOSC7Marker(ttyPath: String, originalCwd: String) -> Bool {
        let marker = "/tmp/av_img_\(UInt32.random(in: 100000...999999))"
        let oscSet = "\u{1b}]7;file://localhost\(marker)\u{07}"
        guard let h = FileHandle(forWritingAtPath: ttyPath),
              let d = oscSet.data(using: .utf8) else {
            return false
        }
        h.write(d)
        h.closeFile()
        usleep(300000)

        let script = """
        tell application "Ghostty"
            repeat with w from 1 to (count windows)
                repeat with i from 1 to (count every terminal of window w)
                    set t to terminal i of window w
                    try
                        if working directory of t is "\(marker)" then
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

        let oscRestore = "\u{1b}]7;file://localhost\(originalCwd)\u{07}"
        if let rh = FileHandle(forWritingAtPath: ttyPath),
           let rd = oscRestore.data(using: .utf8) {
            rh.write(rd)
            rh.closeFile()
        }
        return result == "ok"
    }

    // MARK: - Helpers

    /// Escape a string for embedding in an AppleScript double-quoted literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

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
