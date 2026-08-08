import AppKit
import XCTest
@testable import AgentVisorCore

final class PiGhosttyRestorationScriptTests: XCTestCase {
    func testScriptLaunchesOnlyExactSessionsAndPreservesKnownGrouping() throws {
        let sessions = [
            session("a", file: "/tmp/a's session.jsonl", window: 1, tab: 1, terminal: 1),
            session("b", file: "/tmp/b.jsonl", window: 1, tab: 1, terminal: 2),
            session("c", file: "/tmp/c.jsonl", window: 1, tab: 2, terminal: 1),
            session("d", file: "/tmp/d.jsonl", window: 2, tab: 1, terminal: 1),
        ]

        let script = PiGhosttyRestorationScript.make(
            sessions: sessions,
            piExecutable: "/opt/homebrew/bin/pi"
        )

        XCTAssertEqual(script.components(separatedBy: "new window with configuration").count - 1, 3)
        XCTAssertFalse(script.contains("new tab"))
        XCTAssertEqual(script.components(separatedBy: "split ").count - 1, 1)
        XCTAssertEqual(script.components(separatedBy: "--session").count - 1, 4)
        XCTAssertTrue(script.contains("a'\\\\''s session.jsonl"))
        XCTAssertFalse(script.contains("pi -c"))
        XCTAssertFalse(script.contains("pi -r"))

        try Self.requireGhostty()
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    func testMissingLayoutUsesOneFallbackWindowPerSession() {
        let sessions = [
            session("a", file: "/tmp/a.jsonl"),
            session("b", file: "/tmp/b.jsonl"),
        ]

        let script = PiGhosttyRestorationScript.make(
            sessions: sessions,
            piExecutable: "/usr/local/bin/pi"
        )

        XCTAssertEqual(script.components(separatedBy: "new window with configuration").count - 1, 2)
        XCTAssertFalse(script.contains("new tab"))
        XCTAssertEqual(script.components(separatedBy: "--session").count - 1, 2)
    }

    private func session(
        _ id: String,
        file: String,
        window: Int? = nil,
        tab: Int? = nil,
        terminal: Int? = nil
    ) -> PiRestorableSession {
        let layout: PiGhosttyLayout?
        if let window, let tab, let terminal {
            layout = .init(
                windowIndex: window,
                tabIndex: tab,
                terminalIndex: terminal,
                windowID: "window-\(window)",
                tabID: "window-\(window)-tab-\(tab)",
                terminalID: "terminal-\(id)"
            )
        } else {
            layout = nil
        }
        return PiRestorableSession(
            sessionId: id,
            sessionFile: file,
            cwd: "/tmp/project-\(id)",
            sessionName: nil,
            layout: layout,
            observedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private static func requireGhostty() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil else {
            throw XCTSkip("Ghostty is required to resolve its AppleScript dictionary")
        }
    }

    private struct CompileResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func osacompile(_ source: String) -> CompileResult {
        let tmp = "/tmp/av-pi-restore-compile-\(UUID().uuidString).scpt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        proc.arguments = ["-o", tmp, "-e", source]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice
        do { try proc.run() } catch { return .init(exitCode: -1, stderr: "spawn: \(error)") }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return .init(
            exitCode: proc.terminationStatus,
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
