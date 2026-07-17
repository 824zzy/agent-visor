import Foundation
import XCTest
@testable import AgentVisorCore

final class SessionConversationBackfillPolicyTests: XCTestCase {
    func testAResolvedSessionNameDoesNotSuppressMissingConversationInfo() {
        XCTAssertTrue(SessionConversationBackfillPolicy.shouldLoad(
            sessionName: "codes-58",
            firstUserMessage: nil,
            lastMessage: nil
        ))
    }

    func testExistingConversationInfoDoesNotNeedBackfill() {
        XCTAssertFalse(SessionConversationBackfillPolicy.shouldLoad(
            sessionName: "codes-58",
            firstUserMessage: "hi",
            lastMessage: "Hi! What can I help you with today?"
        ))
    }

    func testSessionStoreUsesConversationStateRatherThanTitleAsTheBackfillGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(source.contains("SessionConversationBackfillPolicy.shouldLoad("))
    }
}
