import XCTest

final class MainWindowViewModelFingerprintAuditTests: XCTestCase {
    func testBrowserFingerprintIncludesRenderedHostFields() throws {
        let source = try String(contentsOf: mainWindowViewModelURL(from: URL(fileURLWithPath: #filePath)))
        guard let fingerprintBody = source.slice(
            from: "private static func browserFingerprint",
            to: "private static func phaseTag"
        ) else {
            return XCTFail("Could not locate browserFingerprint implementation.")
        }

        XCTAssertTrue(
            fingerprintBody.contains("state.agentID.rawValue"),
            "Sidebar rows render the agent/source chip, so agent changes must invalidate the fingerprint."
        )
        XCTAssertTrue(
            fingerprintBody.contains("state.terminalHost?.rawValue"),
            "Sidebar rows render host-dependent labels/icons, so host changes must invalidate the fingerprint."
        )
        XCTAssertTrue(
            fingerprintBody.contains("state.tty ?? \"\""),
            "TTY presence affects host/navigation display and should invalidate the fingerprint."
        )
        XCTAssertTrue(
            fingerprintBody.contains("state.lastActivityDate"),
            "Sidebar rows sort and timestamp by lastActivityDate, so it must invalidate the fingerprint."
        )
        XCTAssertTrue(
            fingerprintBody.contains("state.lastUserMessageDate"),
            "Sidebar rows fall back to lastUserMessageDate for recency, so it must invalidate the fingerprint."
        )
    }

    private func mainWindowViewModelURL(from testFile: URL) -> URL {
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("MainWindowViewModel.swift")
    }
}

private extension String {
    func slice(from startMarker: String, to endMarker: String) -> String? {
        guard let start = range(of: startMarker)?.lowerBound,
              let end = self[start...].range(of: endMarker)?.lowerBound else {
            return nil
        }
        return String(self[start..<end])
    }
}
