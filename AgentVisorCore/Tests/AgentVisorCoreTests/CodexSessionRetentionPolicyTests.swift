import XCTest
@testable import AgentVisorCore

/// Covers the Codex pruning rule through whole sessions.
///
/// Each case builds the session it prunes or keeps. The world outside the session — the Codex
/// app pid, the active thread set, the clock — stays in the arguments, because a session cannot
/// know any of it.
final class CodexSessionRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func guiThread(id: String, lastActivity: Date) -> SessionState {
        SessionStateFixture.make(sessionId: id, agentID: .codex, lastActivity: lastActivity)
    }

    private func terminalThread(id: String, pid: Int, lastActivity: Date) -> SessionState {
        SessionStateFixture.make(
            sessionId: id,
            agentID: .codex,
            pid: pid,
            tty: "ttys001",
            lastActivity: lastActivity
        )
    }

    func testKeepsGuiThreadWhenActiveSetContainsSession() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "active", lastActivity: now.addingTimeInterval(-10_000)),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["active"],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testKeepsRecentGuiThreadWhenActiveSetTemporarilyMisses() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "recent", lastActivity: now.addingTimeInterval(-899)),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testPrunesConfirmedArchivedGuiThreadEvenWhenRecent() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "archived", lastActivity: now.addingTimeInterval(-10)),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true
        ))
    }

    // A running-archived GUI thread (archived=1 but still in the active set
    // because its rollout is fresh) is genuinely running — keep it. Archive
    // alone no longer prunes a thread the selector just surfaced.
    func testKeepsArchivedGuiThreadWhenActiveSetContainsSession() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "archived-active", lastActivity: now),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["archived-active"],
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true
        ))
    }

    func testExplicitArchiveWinsEvenWhenStaleActiveSetContainsSession() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "explicitly-archived", lastActivity: now),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["explicitly-archived"],
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true,
            isExplicitlyArchived: true
        ))
    }

    func testPrunesGuiThreadAfterObservedWindowWhenActiveSetMisses() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "stale", lastActivity: now.addingTimeInterval(-901)),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testPrunesConfirmedArchivedTerminalThreadEvenWhenPidIsAlive() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: terminalThread(id: "archived-cli", pid: 123, lastActivity: now),
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true
        ))
    }

    func testObservedWindowBoundaryIsInclusive() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            session: guiThread(id: "edge", lastActivity: now.addingTimeInterval(-900)),
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testKeepsLiveTerminalCliCodexPid() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            session: terminalThread(id: "cli", pid: 123, lastActivity: now.addingTimeInterval(-10_000)),
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testDoesNotKeepTerminalCliWhenPidIsTheSharedCodexAppPid() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: terminalThread(id: "cli", pid: 456, lastActivity: now),
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }

    // MARK: - Cases the field-based tests could not reach

    func testDoesNotKeepTerminalThreadWithoutPid() {
        let session = SessionStateFixture.make(
            sessionId: "no-pid",
            agentID: .codex,
            tty: "ttys002",
            lastActivity: now
        )
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: session,
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: ["no-pid"],
            now: now,
            observedWindowSeconds: 900
        ), "A tty session is judged by its process, so the active GUI set cannot save it.")
    }

    func testDoesNotKeepTerminalThreadWhenProcessIsGone() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            session: terminalThread(id: "dead", pid: 123, lastActivity: now),
            codexAppPid: 456,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            now: now,
            observedWindowSeconds: 900
        ))
    }
}
