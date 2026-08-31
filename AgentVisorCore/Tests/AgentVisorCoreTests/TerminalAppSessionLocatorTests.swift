import AppKit
import XCTest
@testable import AgentVisorCore

final class TerminalAppSessionLocatorTests: XCTestCase {
    func testFocusScriptCompilesAndTargetsExactTTY() throws {
        let script = TerminalAppSessionLocator.focusScript(ttyName: "ttys042")
        XCTAssertTrue(script.contains("tty of t ends with \"ttys042\""))
        XCTAssertTrue(script.contains("set selected of targetTab to true"))
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    func testEscapeScriptTargetsTerminalTabAndPostsNativeEscape() throws {
        let script = TerminalAppSessionLocator.escapeScript(ttyName: "ttys042")
        XCTAssertTrue(script.contains("tty of t ends with \"ttys042\""))
        XCTAssertTrue(script.contains("set selected of targetTab to true"))
        XCTAssertTrue(script.contains("key code 53"))
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    func testBackspaceScriptIsBoundedAndUsesTerminalHostRoute() throws {
        let script = TerminalAppSessionLocator.backspaceScript(
            ttyName: "ttys042",
            count: 99_999
        )
        XCTAssertTrue(script.contains("repeat 4096 times"))
        XCTAssertTrue(script.contains("key code 51"))
        XCTAssertFalse(script.contains("Ghostty"))
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    private struct CompileResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func osacompile(_ source: String) -> CompileResult {
        let tmp = "/tmp/av-terminal-focus-\(UUID().uuidString).scpt"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", tmp, "-e", source]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .init(exitCode: -1, stderr: "spawn: \(error)")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(
            exitCode: process.terminationStatus,
            stderr: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
