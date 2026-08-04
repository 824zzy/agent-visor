import AppKit
import XCTest
@testable import AgentVisorCore

final class PiGhosttyExistingSurfaceScriptTests: XCTestCase {
    func testOnlyMatchingSavedSurfacesReceiveExactResumeCommands() throws {
        let session = PiRestorableSession(
            sessionId: "session-a",
            sessionFile: "/tmp/session-a.jsonl",
            cwd: "/tmp/project-a",
            sessionName: nil,
            layout: .init(windowIndex: 2, tabIndex: 3, terminalIndex: 1),
            observedAt: Date(timeIntervalSince1970: 100)
        )

        let script = PiGhosttyExistingSurfaceScript.make(
            sessions: [session],
            piExecutable: "/opt/homebrew/bin/pi"
        )

        XCTAssertTrue(script.contains("window 2"))
        XCTAssertTrue(script.contains("tab 3"))
        XCTAssertTrue(script.contains("terminal 1"))
        XCTAssertTrue(script.contains("working directory of targetTerminal is \"/tmp/project-a\""))
        XCTAssertTrue(script.contains("--session"))
        XCTAssertFalse(script.contains("new window"))
        XCTAssertFalse(script.contains("new tab"))

        try Self.requireGhostty()
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    func testOutputParserReturnsOnlyKnownRestoredSessionIDs() {
        XCTAssertEqual(
            PiGhosttyExistingSurfaceScript.restoredSessionIDs(
                from: "session-b\nsession-a\nunknown\n",
                candidates: ["session-a", "session-b"]
            ),
            ["session-a", "session-b"]
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
        let tmp = "/tmp/av-pi-existing-compile-\(UUID().uuidString).scpt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", tmp, "-e", source]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return .init(exitCode: -1, stderr: "spawn: \(error)") }
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(
            exitCode: process.terminationStatus,
            stderr: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
