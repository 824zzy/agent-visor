import XCTest
@testable import AgentVisorCore

final class ClaudeTranscriptRecordIdentityTests: XCTestCase {
    func testDistinctJSONLRowsRemainDistinctWhenProviderMessageIDIsShared() {
        let providerMessageID = "msg_shared"

        let thinking = ClaudeTranscriptRecordIdentity.resolve(
            recordUUID: "row-thinking",
            providerMessageID: providerMessageID
        )
        let toolUse = ClaudeTranscriptRecordIdentity.resolve(
            recordUUID: "row-tool-use",
            providerMessageID: providerMessageID
        )

        XCTAssertEqual(thinking, "row-thinking")
        XCTAssertEqual(toolUse, "row-tool-use")
        XCTAssertNotEqual(thinking, toolUse)
    }

    func testProviderMessageIDIsNeverUsedWhenRecordUUIDIsMissing() {
        XCTAssertNil(ClaudeTranscriptRecordIdentity.resolve(
            recordUUID: nil,
            providerMessageID: "msg_shared"
        ))
        XCTAssertNil(ClaudeTranscriptRecordIdentity.resolve(
            recordUUID: "  ",
            providerMessageID: "msg_shared"
        ))
    }

    func testConversationParserUsesTranscriptRecordIdentity() throws {
        let parser = try String(contentsOf: repositoryRoot(from: URL(fileURLWithPath: #filePath))
            .appendingPathComponent("AgentVisor/Services/Session/ConversationParser.swift"))

        XCTAssertTrue(parser.contains("ClaudeTranscriptRecordIdentity.resolve("))
        XCTAssertTrue(parser.contains("recordUUID: json[\"uuid\"] as? String"))
        XCTAssertTrue(parser.contains("providerMessageID: messageDict[\"id\"] as? String"))
        XCTAssertTrue(parser.contains("id: recordID"))
    }

    private func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
