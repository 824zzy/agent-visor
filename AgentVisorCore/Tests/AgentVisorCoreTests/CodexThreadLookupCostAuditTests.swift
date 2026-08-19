import XCTest
@testable import AgentVisorCore

/// Pins the cost of a Codex bootstrap.
///
/// Looking a thread up by id costs a `sqlite3` subprocess whenever the cached
/// live list does not hold it. A bootstrap of a few hundred discovered
/// sessions therefore forked a few hundred times, and each fork blocked the
/// thread that ran it. The app kept accepting agent events and stopped
/// applying them, so every pill froze in its last state until a restart.
///
/// These are source checks, not behaviour checks: the store reads a real
/// database and forks a real process, so the package cannot run it. The rule
/// it applies is `CodexThreadLookupPlanPolicy`, which is tested directly.
final class CodexThreadLookupCostAuditTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath))
    }

    func testGroupLookupExistsAndUsesOneQuery() throws {
        let store = try source("AgentVisor/Services/Agents/CodexThreadStore.swift")
        XCTAssertTrue(
            store.contains("static func threads(ids: [String]) -> [String: CodexThreadCandidate]"),
            "A caller with many ids needs one group lookup; one query per id is what stalled the bootstrap."
        )
        XCTAssertTrue(
            store.contains("where id in (\\(list))"),
            "The group lookup must ask for every unresolved id in a single statement."
        )
        XCTAssertFalse(
            store.contains("where id = '\\(escaped)'"),
            "The per-id statement made the query text unique per id, so the query cache could never hit."
        )
    }

    func testAbsentIdsAreRememberedSoTheyAreNotQueriedAgain() throws {
        let store = try source("AgentVisor/Services/Agents/CodexThreadStore.swift")
        XCTAssertTrue(
            store.contains("CodexThreadLookupPlanPolicy.idsNeedingQuery"),
            "The store must apply the shared rule for which ids still need a read."
        )
        XCTAssertTrue(
            store.contains("CodexThreadLookupPlanPolicy.missingIDs"),
            "A completed read must record which ids it did not return."
        )
        XCTAssertTrue(
            store.contains("if isKnownMissing(id: id)"),
            "A single-id lookup must answer from the negative memory before it forks."
        )
    }

    func testInvalidateCacheClearsTheNegativeMemory() throws {
        let store = try source("AgentVisor/Services/Agents/CodexThreadStore.swift")
        guard let range = store.range(of: "static func invalidateCache()"),
              let end = store.range(of: "cacheLock.unlock()", range: range.upperBound..<store.endIndex) else {
            return XCTFail("invalidateCache not found")
        }
        XCTAssertTrue(
            store[range.upperBound..<end.upperBound].contains("missingIds = nil"),
            "A forced invalidation must drop remembered absences, or a thread that just appeared stays invisible."
        )
    }

    func testDiscoveryPreWarmsTheWholeGroupBeforeTheStoreMergesIt() throws {
        let monitor = try source("AgentVisor/Services/Session/ClaudeSessionMonitor.swift")
        XCTAssertTrue(
            monitor.contains("prewarmMetadata(for: results)"),
            "Discovery must read grouped metadata before the synchronous store merge asks per row."
        )
        XCTAssertTrue(
            monitor.contains(".prewarmMetadata(sessionIds: group.map(\\.sessionId))"),
            "Each provider must receive one grouped pre-read, not one read per row."
        )
        let store = try source("AgentVisor/Services/State/SessionStore.swift")
        XCTAssertFalse(
            store.contains("for (agentID, group) in Dictionary(grouping: discovered"),
            "A grouped database read inside the synchronous merge can hold SessionStore."
        )
        XCTAssertTrue(
            store.contains("provider.prewarmMetadata(sessionIds: discovered.map(\\.sessionId))"),
            "The Codex-only rediscovery path must pre-read its own group too."
        )
        let provider = try source("AgentVisor/Services/Agents/CodexAgentProvider.swift")
        XCTAssertTrue(
            provider.contains("CodexThreadStore.threads(ids: missing)"),
            "Codex must resolve the ids its bounded live list misses in one read."
        )
        XCTAssertTrue(
            provider.contains("CodexThreadStore.liveThreadCandidates()"),
            "The bounded live list stays the first source; the group read only covers what it misses."
        )
    }

    func testTranscriptPathAndWatcherAreProviderQuestions() throws {
        let store = try source("AgentVisor/Services/State/SessionStore.swift")
        XCTAssertFalse(
            store.contains("if info.agentID == .codex, let path = codexThread?.rolloutPath"),
            "Where a transcript lives is the provider's answer; Codex already reads its rollout path there."
        )
        XCTAssertTrue(
            store.contains("provider?.watchesTranscriptOnDiscovery(for: session) == true"),
            "Whether discovery starts a transcript watcher depends on the agent's process model, so the provider decides."
        )
        let provider = try source("AgentVisor/Services/Agents/CodexAgentProvider.swift")
        XCTAssertTrue(
            provider.contains("func watchesTranscriptOnDiscovery(for session: SessionState) -> Bool"),
            "Codex.app threads share one process and fire no per-thread hooks, so they need the watcher."
        )
    }
}
