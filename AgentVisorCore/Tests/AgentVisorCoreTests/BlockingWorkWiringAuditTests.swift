import XCTest
@testable import AgentVisorCore

/// The app froze once because reads that block a thread ran on the few threads
/// that serve every `await`. Two things keep that from coming back: a runner with
/// threads of its own, and a deadline on every child process. Both are easy to
/// undo by accident, so these checks read the source.
final class BlockingWorkWiringAuditTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }

    func testNoChildProcessWaitsWithoutADeadline() throws {
        let executor = try source("AgentVisor/Services/Shared/ProcessExecutor.swift")
        XCTAssertFalse(
            executor.contains("distantFuture"),
            "A wait with no deadline holds its thread for the life of the app."
        )
        XCTAssertTrue(
            executor.contains("SubprocessDeadlinePolicy.deadline(requested: timeout)"),
            "The deadline must come from the policy, so callers cannot opt out of having one."
        )
    }

    func testTheRunnerKeepsItsOwnThreadsAndBoundsThem() throws {
        let runner = try source("AgentVisor/Services/Shared/BlockingWork.swift")
        XCTAssertTrue(
            runner.contains("DispatchQueue("),
            "The point of the runner is threads that are not the ones serving await."
        )
        XCTAssertTrue(
            runner.contains("BlockingWorkGate()"),
            "Without the gate, a fan-out over hundreds of rows starts hundreds of children."
        )
        XCTAssertTrue(
            runner.contains("withCheckedContinuation"),
            "The caller must suspend, not hold a thread while it waits."
        )
    }

    func testTheDiscoveryScanRunsThroughTheRunner() throws {
        let store = try source("AgentVisor/Services/State/SessionStore.swift")
        // A process scan reads the whole process table with `ps` and `lsof`. It
        // used to hop off the actor with a hand-written continuation, once per
        // scan kind, with no bound and no report when it ran long.
        XCTAssertTrue(store.contains("await BlockingWork.run(\"discoverExistingSessions\")"))
        XCTAssertTrue(store.contains("await BlockingWork.run(\"discoverCodexSessions\")"))
        XCTAssertFalse(
            store.contains("DispatchQueue.global(qos: .utility).async"),
            "A hand-rolled hop skips the bound and the slow-read report."
        )
    }
}
