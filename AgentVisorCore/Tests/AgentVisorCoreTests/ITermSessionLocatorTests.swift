import AppKit
import XCTest
@testable import AgentVisorCore

final class ITermSessionLocatorTests: XCTestCase {
    // MARK: - normalizeTTY

    func testNormalizeTTYStripsDevPrefix() {
        XCTAssertEqual(ITermSessionLocator.normalizeTTY("/dev/ttys012"), "ttys012")
    }

    func testNormalizeTTYLeavesBareNameUntouched() {
        XCTAssertEqual(ITermSessionLocator.normalizeTTY("ttys012"), "ttys012")
    }

    // MARK: - parseSelectOutput

    func testParseSelectOutputOkIsTrue() {
        XCTAssertTrue(ITermSessionLocator.parseSelectOutput("ok"))
    }

    func testParseSelectOutputTrimsWhitespace() {
        XCTAssertTrue(ITermSessionLocator.parseSelectOutput("ok\n"))
        XCTAssertTrue(ITermSessionLocator.parseSelectOutput("  ok  "))
    }

    func testParseSelectOutputNotFoundIsFalse() {
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput("not-found"))
    }

    func testParseSelectOutputEmptyIsFalse() {
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput(""))
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput("   "))
    }

    func testParseSelectOutputOtherStringsAreFalse() {
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput("OK"))  // case-sensitive
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput("okay"))
        XCTAssertFalse(ITermSessionLocator.parseSelectOutput("ok and more"))
    }

    // MARK: - selectScript

    func testSelectScriptEmbedsTTYName() {
        let script = ITermSessionLocator.selectScript(ttyName: "ttys042")
        XCTAssertTrue(script.contains("ttys042"))
    }

    func testSelectScriptEscapesQuotes() {
        let script = ITermSessionLocator.selectScript(ttyName: #"with"quote"#)
        XCTAssertTrue(script.contains(#"with\"quote"#))
    }

    func testSelectScriptHasIterm2Tell() {
        let script = ITermSessionLocator.selectScript(ttyName: "ttys001")
        XCTAssertTrue(script.contains(#"tell application "iTerm""#))
        XCTAssertTrue(script.contains("end tell"))
    }

    func testSelectScriptHasNotFoundBranch() {
        let script = ITermSessionLocator.selectScript(ttyName: "ttys001")
        XCTAssertTrue(script.contains(#"return "not-found""#))
        XCTAssertTrue(script.contains(#"return "ok""#))
    }

    // MARK: - Integration: AppleScript compile-check
    //
    // Regression guard against the `using {control down}` class of bug —
    // the script must osacompile cleanly even when iTerm2 isn't running.

    func testSelectScriptCompiles() throws {
        try Self.requireITerm()
        let script = ITermSessionLocator.selectScript(ttyName: "ttys999")
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    // MARK: - contentsScript

    func testContentsScriptEmbedsTTYName() {
        let script = ITermSessionLocator.contentsScript(ttyName: "ttys017")
        XCTAssertTrue(script.contains("ttys017"))
        XCTAssertTrue(script.contains("contents of s"))
    }

    func testContentsScriptHasFallbackEmptyReturn() {
        let script = ITermSessionLocator.contentsScript(ttyName: "ttys017")
        // Script returns "0\n" (rows=0, empty body) when no session matches.
        XCTAssertTrue(script.contains("return \"0\""))
    }

    func testContentsScriptEmitsRowCountThenContents() {
        let script = ITermSessionLocator.contentsScript(ttyName: "ttys017")
        XCTAssertTrue(script.contains("rows of s"))
        XCTAssertTrue(script.contains("contents of s"))
        XCTAssertTrue(script.contains("linefeed"))
    }

    func testContentsScriptCompiles() throws {
        try Self.requireITerm()
        let script = ITermSessionLocator.contentsScript(ttyName: "ttys017")
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    // MARK: - parseContentsOutput

    /// New envelope: "<rows>\n<contents>". `parseContentsOutput` slices
    /// the last `rows` lines so callers see only the live viewport.

    func testParseContentsReturnsLastNRowsFromEnvelope() {
        // 5 lines of "scrollback", rows=2 → only the last 2 lines.
        let input = "2\nscroll-1\nscroll-2\nscroll-3\nlive-row-1\nlive-row-2"
        XCTAssertEqual(
            ITermSessionLocator.parseContentsOutput(input),
            "live-row-1\nlive-row-2"
        )
    }

    func testParseContentsReturnsNilWhenScriptReportsNoSession() {
        // Script's "no session matched" sentinel: rows=0, empty body.
        XCTAssertNil(ITermSessionLocator.parseContentsOutput("0\n"))
        XCTAssertNil(ITermSessionLocator.parseContentsOutput("0\n   \n  "))
    }

    func testParseContentsLegacyFallbackForRawText() {
        // Old script (no rows envelope) — defensive path returns the
        // trimmed body, mirroring previous behavior so this remains a
        // safe upgrade.
        XCTAssertEqual(
            ITermSessionLocator.parseContentsOutput("hello world"),
            "hello world"
        )
        XCTAssertNil(ITermSessionLocator.parseContentsOutput(""))
    }

    func testParseContentsHandlesViewportSmallerThanBuffer() {
        // 38-row viewport (matches typical iTerm2 default), 50 lines
        // of buffer — only the last 38 should come back.
        let buffer = (1...50).map { "line-\($0)" }.joined(separator: "\n")
        let envelope = "38\n" + buffer
        let out = ITermSessionLocator.parseContentsOutput(envelope) ?? ""
        let outLines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(outLines.count, 38)
        XCTAssertEqual(outLines.first, "line-13")
        XCTAssertEqual(outLines.last, "line-50")
    }

    func testParseContentsHandlesBufferShorterThanViewport() {
        // Buffer has 5 lines, viewport claims 38 — return all 5.
        let envelope = "38\nline-1\nline-2\nline-3\nline-4\nline-5"
        XCTAssertEqual(
            ITermSessionLocator.parseContentsOutput(envelope),
            "line-1\nline-2\nline-3\nline-4\nline-5"
        )
    }

    // MARK: - bracketedPasteScript

    func testBracketedPasteEmbedsTTYAndPayload() {
        let script = ITermSessionLocator.bracketedPasteScript(
            ttyName: "ttys013",
            payload: "/tmp/av-image.png"
        )
        XCTAssertTrue(script.contains("ttys013"))
        XCTAssertTrue(script.contains("/tmp/av-image.png"))
    }

    func testBracketedPasteUsesCSI200And201Wrappers() {
        let script = ITermSessionLocator.bracketedPasteScript(ttyName: "ttys013", payload: "x")
        XCTAssertTrue(script.contains("[200~"))
        XCTAssertTrue(script.contains("[201~"))
        XCTAssertTrue(script.contains("ASCII character 27"))
    }

    func testBracketedPasteEscapesQuotesInPayload() {
        let script = ITermSessionLocator.bracketedPasteScript(
            ttyName: "ttys013",
            payload: #"path with "quote""#
        )
        XCTAssertTrue(script.contains(#"path with \"quote\""#))
    }

    func testBracketedPasteCompiles() throws {
        try Self.requireITerm()
        let script = ITermSessionLocator.bracketedPasteScript(
            ttyName: "ttys013",
            payload: "/tmp/av-image.png"
        )
        let result = Self.osacompile(script)
        XCTAssertEqual(result.exitCode, 0, "osacompile stderr: \(result.stderr)")
    }

    private static func requireITerm() throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil else {
            throw XCTSkip("iTerm2 is required to resolve its AppleScript dictionary")
        }
    }

    private struct CompileResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func osacompile(_ source: String) -> CompileResult {
        let tmp = "/tmp/av-iterm-locator-compile-\(UUID().uuidString).scpt"
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
