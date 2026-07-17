import XCTest
@testable import AgentVisorCore

final class CodexSessionRetentionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testKeepsGuiThreadWhenActiveSetContainsSession() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "active",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["active"],
            lastActivity: now.addingTimeInterval(-10_000),
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testKeepsRecentGuiThreadWhenActiveSetTemporarilyMisses() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "recent",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            lastActivity: now.addingTimeInterval(-899),
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testPrunesConfirmedArchivedGuiThreadEvenWhenRecent() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "archived",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            lastActivity: now.addingTimeInterval(-10),
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
            sessionId: "archived-active",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["archived-active"],
            lastActivity: now,
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true
        ))
    }

    func testExplicitArchiveWinsEvenWhenStaleActiveSetContainsSession() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "explicitly-archived",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: ["explicitly-archived"],
            lastActivity: now,
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true,
            isExplicitlyArchived: true
        ))
    }

    func testPrunesGuiThreadAfterObservedWindowWhenActiveSetMisses() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "stale",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            lastActivity: now.addingTimeInterval(-901),
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testPrunesConfirmedArchivedTerminalThreadEvenWhenPidIsAlive() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "archived-cli",
            tty: "ttys001",
            pid: 123,
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            lastActivity: now,
            now: now,
            observedWindowSeconds: 900,
            isKnownArchived: true
        ))
    }

    func testObservedWindowBoundaryIsInclusive() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "edge",
            tty: nil,
            pid: nil,
            codexAppPid: nil,
            isNonAppPidAlive: false,
            activeGUIThreadIds: [],
            lastActivity: now.addingTimeInterval(-900),
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testKeepsLiveTerminalCliCodexPid() {
        XCTAssertTrue(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "cli",
            tty: "ttys001",
            pid: 123,
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            lastActivity: now.addingTimeInterval(-10_000),
            now: now,
            observedWindowSeconds: 900
        ))
    }

    func testDoesNotKeepTerminalCliWhenPidIsTheSharedCodexAppPid() {
        XCTAssertFalse(CodexSessionRetentionPolicy.shouldKeep(
            sessionId: "cli",
            tty: "ttys001",
            pid: 456,
            codexAppPid: 456,
            isNonAppPidAlive: true,
            activeGUIThreadIds: [],
            lastActivity: now,
            now: now,
            observedWindowSeconds: 900
        ))
    }
}
