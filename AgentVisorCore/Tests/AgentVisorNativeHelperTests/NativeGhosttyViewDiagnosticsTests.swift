@testable import AgentVisorNativeHelper
import XCTest

final class NativeGhosttyViewDiagnosticsTests: XCTestCase {
    func testReadFailuresAreDistinguishableWithoutSavingTerminalContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ghostty-view-read.json")
        let diagnostics = NativeGhosttyViewDiagnostics(fileURL: file)
        let report = NativeGhosttyViewReadReport(reason: .windowNotFound, windows: 2)
        diagnostics.record(report)
        let first = try Data(contentsOf: file)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(value["reason"] as? String, "window_not_found")
        XCTAssertEqual(value["windows"] as? Int, 2)
        XCTAssertEqual(Set(value.keys), ["observedAt", "reason", "windows", "matchingWindows", "elements", "textAreas"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        diagnostics.record(report)
        XCTAssertEqual(try Data(contentsOf: file), first)
        diagnostics.record(.init(reason: .unsupportedFooter, windows: 2, matchingWindows: 1, elements: 8, textAreas: 1))
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(next["reason"] as? String, "unsupported_footer")
        XCTAssertLessThan(try Data(contentsOf: file).count, 1_024)
    }
}
