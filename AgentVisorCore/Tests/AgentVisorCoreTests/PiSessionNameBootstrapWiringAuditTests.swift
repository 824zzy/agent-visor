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
        XCTAssertEqual(
            provider.components(separatedBy: "BlockingWork.run(\"piSessionName\")").count - 1,
            2,
            "Hook restoration and successful file sync must refresh the same name cache off the shared threads."
        )
        XCTAssertTrue(provider.contains("if result.fileChange != nil"))
        XCTAssertTrue(
            provider.contains("guard transcriptNameSignature(url: url) == signature"),
            "A cache entry must use the same file version that produced its name."
        )

        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))
        guard let hookStart = store.range(of: "private func processHookEvent"),
              let hookEnd = store.range(of: "private func codexBackedHookEvent", range: hookStart.upperBound..<store.endIndex)
        else { return XCTFail("The hook handler moved.") }
        let hook = String(store[hookStart.lowerBound..<hookEnd.lowerBound])
        let notes = try XCTUnwrap(hook.range(of: "noteHookEvent(event, session: session)"))
        let name = try XCTUnwrap(hook.range(of: "resolveSessionName("))
        XCTAssertLessThan(
            hook.distance(from: hook.startIndex, to: notes.lowerBound),
            hook.distance(from: hook.startIndex, to: name.lowerBound),
            "Pi must refresh its cache before the store asks for the restored name."
        )
    }
}
