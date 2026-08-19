import XCTest
@testable import AgentVisorCore

/// Discovery starts transcript watchers only when the owning provider needs
/// file evidence. Hook-driven sessions start one after their first event because
/// some transcript writes, such as compaction, arrive after the hook.
final class TranscriptWatcherOwnershipWiringAuditTests: XCTestCase {
    func testStartupDoesNotStartAWatcherForEveryDiscoveredSession() throws {
        let monitor = try source("AgentVisor/Services/Session/SessionMonitor.swift")
        guard let start = monitor.range(of: "await SessionStore.shared.bootstrapSessions(discovered)"),
              let end = monitor.range(of: "await PendingPermissionStore.replayOnStartup()", range: start.upperBound..<monitor.endIndex)
        else { return XCTFail("The startup sequence moved.") }
        let afterBootstrap = String(monitor[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(
            afterBootstrap.contains("SessionFileWatcherManager.shared.startWatching"),
            "Bootstrap already asks each provider; an unconditional second pass bypasses that answer."
        )
    }

    func testCursorWatchesEveryDiscoveredTranscriptBecauseItHasNoHooks() throws {
        let cursor = try source("AgentVisor/Services/Agents/CursorAgentProvider.swift")
        guard let start = cursor.range(of: "func watchesTranscriptOnDiscovery"),
              let end = cursor.range(of: "func deadSessionIDs", range: start.upperBound..<cursor.endIndex)
        else { return XCTFail("Cursor's discovery watcher answer is missing.") }
        XCTAssertTrue(String(cursor[start.lowerBound..<end.lowerBound]).contains("true"))
    }

    func testCodexWatchesOnlyHooklessDiscoveredRows() throws {
        let codex = try source("AgentVisor/Services/Agents/CodexAgentProvider.swift")
        guard let start = codex.range(of: "func watchesTranscriptOnDiscovery"),
              let end = codex.range(of: "func deadProcessAction", range: start.upperBound..<codex.endIndex)
        else { return XCTFail("Codex's discovery watcher answer moved.") }
        XCTAssertTrue(String(codex[start.lowerBound..<end.lowerBound]).contains("session.tty == nil"))
    }

    func testHookEventsStillStartAWatcherForDelayedTranscriptWrites() throws {
        let monitor = try source("AgentVisor/Services/Session/SessionMonitor.swift")
        guard let start = monitor.range(of: "HookSocketServer.shared.start("),
              let end = monitor.range(of: "// Restoration must not claim", range: start.upperBound..<monitor.endIndex)
        else { return XCTFail("The hook monitor boundaries moved.") }
        let hooks = String(monitor[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(hooks.contains("SessionFileWatcherManager.shared.startWatching"))
        XCTAssertTrue(hooks.contains("if event.isTerminalLifecycleStatus"))
        XCTAssertTrue(hooks.contains("SessionFileWatcherManager.shared.stopWatching"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }
}
