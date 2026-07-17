import XCTest

final class WindowChatViewModelFingerprintAuditTests: XCTestCase {
    func testChatPresentationTracksControlRoutingMetadata() throws {
        let source = try String(contentsOf: windowChatViewURL(from: URL(fileURLWithPath: #filePath)))
        guard let refreshBody = source.slice(
            from: "private func refreshSessionMeta",
            to: "private func phaseTag"
        ) else {
            return XCTFail("Could not locate WindowChatViewModel.refreshSessionMeta.")
        }

        XCTAssertTrue(
            refreshBody.contains("WindowChatSessionPresentationFingerprint("),
            "The detail pane should use the typed presentation fingerprint."
        )
        XCTAssertTrue(
            refreshBody.contains("codexControlCapability: next.codexControlCapability"),
            "Observed-to-connected transitions must refresh the chat control surface."
        )
        XCTAssertTrue(refreshBody.contains("agentID: next.agentID"))
        XCTAssertTrue(refreshBody.contains("originTag: next.origin.rawValue"))
        XCTAssertTrue(refreshBody.contains("tty: next.tty"))
        XCTAssertTrue(refreshBody.contains("terminalHost: next.terminalHost"))
    }

    private func windowChatViewURL(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentVisor")
            .appendingPathComponent("UI")
            .appendingPathComponent("Window")
            .appendingPathComponent("WindowChatView.swift")
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
