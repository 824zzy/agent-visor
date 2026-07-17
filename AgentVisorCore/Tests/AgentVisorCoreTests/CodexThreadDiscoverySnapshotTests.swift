import XCTest
@testable import AgentVisorCore

final class CodexThreadDiscoverySnapshotTests: XCTestCase {
    private func thread(
        _ id: String,
        updatedAt: Int,
        archived: Bool = false,
        source: String = "vscode",
        cwd: String = "/repo",
        rolloutModifiedAt: Int? = nil,
        rolloutPath: String? = nil
    ) -> CodexThreadCandidate {
        CodexThreadCandidate(
            id: id,
            rolloutPath: rolloutPath ?? "/tmp/\(id).jsonl",
            cwd: cwd,
            title: id,
            updatedAt: updatedAt,
            archived: archived,
            source: source,
            rolloutModifiedAt: rolloutModifiedAt ?? updatedAt
        )
    }

    func testIgnoresUpdatedAtChangeForAlreadyActiveThread() {
        let old = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 900)],
            now: 1_000,
            windowSeconds: 200
        )
        let updated = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 999)],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertFalse(updated.requiresRediscovery(comparedTo: old))
    }

    func testRequiresRediscoveryWhenNewActiveThreadAppears() {
        let old = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 900)],
            now: 1_000,
            windowSeconds: 200
        )
        let updated = CodexThreadDiscoverySnapshot.make(
            candidates: [
                thread("a", updatedAt: 999),
                thread("b", updatedAt: 999),
            ],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertTrue(updated.requiresRediscovery(comparedTo: old))
    }

    func testRequiresRediscoveryWhenOldThreadBecomesActiveAgain() {
        let old = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 700)],
            now: 1_000,
            windowSeconds: 200
        )
        let updated = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 999)],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertTrue(updated.requiresRediscovery(comparedTo: old))
    }

    func testRequiresRediscoveryWhenCliThreadKeyChanges() {
        let old = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 900, source: "cli", cwd: "/repo")],
            now: 1_000,
            windowSeconds: 200
        )
        let updated = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 900, source: "cli", cwd: "/other")],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertTrue(updated.requiresRediscovery(comparedTo: old))
    }

    func testExplicitlyArchivedCliThreadIsNotDiscoverableDuringMetadataTransition() {
        let snapshot = CodexThreadDiscoverySnapshot.make(
            candidates: [thread(
                "archived-cli",
                updatedAt: 999,
                archived: false,
                source: "cli",
                rolloutPath: "/Users/me/.codex/archived_sessions/rollout-cli.jsonl"
            )],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertTrue(snapshot.discoverableThreadKeys.isEmpty)
    }

    func testObserverSessionThreadsDoNotTriggerRediscovery() {
        let old = CodexThreadDiscoverySnapshot.make(
            candidates: [thread("a", updatedAt: 900, cwd: "/repo")],
            now: 1_000,
            windowSeconds: 200
        )
        let updated = CodexThreadDiscoverySnapshot.make(
            candidates: [
                thread("a", updatedAt: 999, cwd: "/repo"),
                thread("observer", updatedAt: 999, cwd: "/Users/me/.claude-mem/observer-sessions"),
            ],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertFalse(updated.requiresRediscovery(comparedTo: old))
    }

    // A running-archived GUI thread (archived=1, but rollout freshly written)
    // must be both active AND discoverable — otherwise rediscovery never fires
    // for it and the row never appears.
    func testRunningArchivedGUIThreadIsDiscoverable() {
        let snapshot = CodexThreadDiscoverySnapshot.make(
            candidates: [
                thread("live", updatedAt: 900, rolloutModifiedAt: 980),
                thread("running-archived", updatedAt: 700, archived: true, rolloutModifiedAt: 980),
            ],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertTrue(snapshot.activeGUIThreadIds.contains("running-archived"))
        XCTAssertTrue(snapshot.discoverableThreadKeys.contains(
            CodexDiscoverableThreadKey(id: "running-archived", source: "vscode", cwd: "/repo")
        ))
    }

    // A genuinely-closed archived thread (stale rollout) stays out of both sets.
    func testStaleArchivedGUIThreadNotDiscoverable() {
        let snapshot = CodexThreadDiscoverySnapshot.make(
            candidates: [
                thread("closed-archived", updatedAt: 700, archived: true, rolloutModifiedAt: 500),
            ],
            now: 1_000,
            windowSeconds: 200
        )

        XCTAssertFalse(snapshot.activeGUIThreadIds.contains("closed-archived"))
        XCTAssertTrue(snapshot.discoverableThreadKeys.isEmpty)
    }
}
