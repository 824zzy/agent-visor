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

    func testEveryTranscriptSummaryReadIsBounded() throws {
        // The scan asks for one summary per row. Two hundred at once, each
        // reading a transcript and some also reading a database, is the fan-out
        // that stopped the app. Each provider owns its own read, so each states
        // the bound where the read lives.
        for provider in [
            "ClaudeCodeAgentProvider",
            "CodexAgentProvider",
            "CursorAgentProvider",
            "PiAgentProvider"
        ] {
            let src = try source("AgentVisor/Services/Agents/\(provider).swift")
            guard let range = src.range(of: "func loadConversationInfo") else {
                XCTFail("\(provider) no longer answers for its own summary read.")
                continue
            }
            let body = String(src[range.lowerBound...].prefix(700))
            XCTAssertTrue(
                body.contains("BlockingWork.limited"),
                "\(provider) reads a transcript with no bound on how many run at once."
            )
        }
    }

    func testBoundedReadsUseTheirOwnCounter() throws {
        let runner = try source("AgentVisor/Services/Shared/BlockingWork.swift")
        // Two counters, so a sweep of transcripts cannot starve a question about
        // who is alive, and so nesting one kind inside the other cannot stop both.
        XCTAssertTrue(runner.contains("private static let readGate = BlockingWorkGate()"))
        XCTAssertTrue(runner.contains("await readGate.withPermit(body)"))
    }

    func testTheSweepAsksItsLivenessQuestionThroughTheRunner() throws {
        let store = try source("AgentVisor/Services/State/SessionStore.swift")
        // This question runs every few seconds. Codex reads its thread database
        // and Cursor asks about a running app, so it blocks the thread it is on.
        XCTAssertTrue(store.contains("await BlockingWork.run(\"deadSessionIDs\")"))
        XCTAssertTrue(store.contains("await BlockingWork.run(\"findLiveAttachment\")"))
        // Waiting away from the actor lets other work run, so the answer must be
        // checked against the row before the sweep acts on it.
        XCTAssertEqual(
            store.components(separatedBy: "LivenessAnswerFreshnessPolicy.stillApplies").count - 1,
            2,
            "Each awaited answer in the sweep needs its own freshness check."
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
