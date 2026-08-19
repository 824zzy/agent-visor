import XCTest
@testable import AgentVisorCore

final class PiSessionNameBootstrapWiringAuditTests: XCTestCase {
    func testDiscoveryPrewarmsPiNamesAndBootstrapReadsTheCache() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let provider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"
        ))

        XCTAssertTrue(provider.contains("func prewarmMetadata(sessionIds: [String])"))
        XCTAssertTrue(provider.contains("PiTranscriptActiveNameReader.read(path:"))
        XCTAssertTrue(provider.contains("func resolveSessionName(sessionId: String, pid: Int?)"))
        XCTAssertTrue(provider.contains("cachedTranscriptName(sessionId: sessionId)"))
    }
}
