import XCTest
@testable import AgentVisorCore

final class CodexBrowsableThreadSelectorTests: XCTestCase {
    func testKeepsOldNavigableGUIThreadsWithoutApplyingObservedWindow() {
        let threads = CodexBrowsableThreadSelector.browsableThreads([
            thread("old", updatedAt: 1, rolloutModifiedAt: 1),
            thread("new", updatedAt: 10_000, rolloutModifiedAt: 10_000),
        ])

        XCTAssertEqual(threads.map(\.id), ["new", "old"])
    }

    func testDropsArchivedMissingRolloutAutomationAndObserverThreads() {
        let threads = CodexBrowsableThreadSelector.browsableThreads([
            thread("visible", updatedAt: 10, rolloutModifiedAt: 10),
            thread("archived", updatedAt: 9, archived: true, rolloutModifiedAt: 9),
            thread("missing", updatedAt: 8, rolloutModifiedAt: nil),
            thread("exec", updatedAt: 7, source: "exec", rolloutModifiedAt: 7),
            thread(
                "observer",
                updatedAt: 6,
                cwd: "/Users/me/.claude-mem/observer-sessions",
                rolloutModifiedAt: 6
            ),
        ])

        XCTAssertEqual(threads.map(\.id), ["visible"])
    }

    private func thread(
        _ id: String,
        updatedAt: Int,
        archived: Bool = false,
        source: String = "vscode",
        cwd: String = "/Users/me/Codes",
        rolloutModifiedAt: Int?
    ) -> CodexThreadCandidate {
        CodexThreadCandidate(
            id: id,
            rolloutPath: "/Users/me/.codex/sessions/rollout-\(id).jsonl",
            cwd: cwd,
            title: id,
            updatedAt: updatedAt,
            archived: archived,
            source: source,
            rolloutModifiedAt: rolloutModifiedAt
        )
    }
}
