import AppKit
import XCTest
@testable import AgentVisorCore

final class GhosttyMarkerLocatorTests: XCTestCase {
    // MARK: - parseLocatorOutput

    func testParsesValidWindowTerminalPair() {
        let loc = GhosttyMarkerLocator.parseLocatorOutput("2,3")
        XCTAssertEqual(loc, .init(windowIndex: 2, terminalIndex: 3))
    }

    func testParsesSingleDigitPair() {
        XCTAssertEqual(
            GhosttyMarkerLocator.parseLocatorOutput("1,1"),
            .init(windowIndex: 1, terminalIndex: 1)
        )
    }

    func testTrimsTrailingNewline() {
        XCTAssertEqual(
            GhosttyMarkerLocator.parseLocatorOutput("4,7\n"),
            .init(windowIndex: 4, terminalIndex: 7)
        )
    }

    func testReturnsNilForNotFoundSentinel() {
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("not-found"))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput(""))
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("   "))
    }

    func testReturnsNilForMalformed() {
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("garbage"))
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("2"))         // only one component
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("2,3,4"))     // too many
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("a,b"))       // non-numeric
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("0,1"))       // zero not valid (1-based)
        XCTAssertNil(GhosttyMarkerLocator.parseLocatorOutput("-1,2"))      // negative not valid
    }

    // MARK: - osc7Sequence

    func testOSC7SequenceFormat() {
        let seq = GhosttyMarkerLocator.osc7Sequence(cwd: "/tmp/av-cycle-42")
        XCTAssertEqual(seq, "\u{1b}]7;file://localhost/tmp/av-cycle-42\u{07}")
    }

    func testOSC7SequenceCustomHost() {
        let seq = GhosttyMarkerLocator.osc7Sequence(cwd: "/foo", host: "myhost")
        XCTAssertEqual(seq, "\u{1b}]7;file://myhost/foo\u{07}")
    }

    // MARK: - makeMarker

    func testMakeMarkerUsesExpectedPrefix() {
        let m = GhosttyMarkerLocator.makeMarker()
        XCTAssertTrue(m.hasPrefix("/tmp/av-cycle-"), "got: \(m)")
    }

    func testMakeMarkerWithSeedIsDeterministic() {
        XCTAssertEqual(
            GhosttyMarkerLocator.makeMarker(seed: 42),
            "/tmp/av-cycle-42"
        )
    }

    func testMakeMarkerSuccessiveCallsDiffer() {
        var seen = Set<String>()
        for _ in 0..<20 {
            seen.insert(GhosttyMarkerLocator.makeMarker())
        }
        // 20 random values from a 9-digit range should never collide.
        XCTAssertEqual(seen.count, 20)
    }

    // MARK: - locatorScript

    func testLocatorScriptContainsMarker() {
        let script = GhosttyMarkerLocator.locatorScript(marker: "/tmp/av-cycle-abc")
        XCTAssertTrue(script.contains("/tmp/av-cycle-abc"))
    }

    func testLocatorScriptEscapesQuotesInMarker() {
        let script = GhosttyMarkerLocator.locatorScript(marker: "/tmp/has\"quote")
        XCTAssertTrue(script.contains(#"/tmp/has\"quote"#))
        XCTAssertFalse(script.contains(#""/tmp/has"quote""#))
    }

    func testLocatorScriptHasTellApplicationGhostty() {
        let script = GhosttyMarkerLocator.locatorScript(marker: "/m")
        XCTAssertTrue(script.contains("tell application \"Ghostty\""))
        XCTAssertTrue(script.contains("end tell"))
    }

    func testLocatorScriptReturnsParseableFormatOnNotFound() {
        // The script's not-found branch must return literal "not-found"
        // so parseLocatorOutput recognises it.
        let script = GhosttyMarkerLocator.locatorScript(marker: "/m")
        XCTAssertTrue(script.contains("return \"not-found\""))
    }

    // MARK: - Integration: AppleScript compile-check
    //
    // Regression guard for the class of bug from the Ctrl+U/`using {control down}`
    // saga: AppleScript that LOOKS right but fails to compile silently. If
    // osacompile rejects the script, this test fails before we ship.

    func testLocatorScriptCompiles() throws {
        try Self.requireGhostty()
        let script = GhosttyMarkerLocator.locatorScript(marker: "/tmp/av-cycle-test")
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    func testFocusScriptCompilesAndVerifiesFocusedTerminal() throws {
        try Self.requireGhostty()
        let script = GhosttyMarkerLocator.focusScript(marker: "/tmp/av-focus-test")
        XCTAssertTrue(script.contains("focused terminal of selected tab"))
        XCTAssertTrue(script.contains("front window"))
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
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
        let tmp = "/tmp/av-locator-compile-\(UUID().uuidString).scpt"
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
