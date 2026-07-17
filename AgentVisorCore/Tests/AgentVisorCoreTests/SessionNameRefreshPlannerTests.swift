import Foundation
import XCTest
@testable import AgentVisorCore

final class SessionNameRefreshPlannerTests: XCTestCase {
    func testTranscriptTitleDoesNotReplaceResolvedProcessName() {
        XCTAssertEqual(
            SessionTranscriptTitlePolicy.preferredName(
                sessionId: "624474f4-65e3-4f9a-88d4-1fa1e2461617",
                currentName: "codes-58",
                transcriptTitle: "claude-code-desktop"
            ),
            "codes-58"
        )
    }

    func testSessionStoreUsesTranscriptTitlePrecedencePolicy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        XCTAssertTrue(source.contains("SessionTranscriptTitlePolicy.preferredName("))
    }

    func testChangedResolvedNameProducesUpdate() {
        let changes = SessionNameRefreshPlanner.changes(
            candidates: [
                .init(sessionId: "codex-1", currentName: "Old name")
            ],
            resolvedNames: [
                "codex-1": "New name"
            ]
        )

        XCTAssertEqual(changes, [
            .init(sessionId: "codex-1", name: "New name")
        ])
    }

    func testMissingEmptyAndUnchangedNamesDoNotProduceUpdates() {
        let changes = SessionNameRefreshPlanner.changes(
            candidates: [
                .init(sessionId: "missing", currentName: "Keep me"),
                .init(sessionId: "empty", currentName: "Keep me too"),
                .init(sessionId: "spaces", currentName: "Also keep me"),
                .init(sessionId: "same", currentName: "Same name")
            ],
            resolvedNames: [
                "empty": "",
                "spaces": "   ",
                "same": "Same name"
            ]
        )

        XCTAssertEqual(changes, [])
    }
}
