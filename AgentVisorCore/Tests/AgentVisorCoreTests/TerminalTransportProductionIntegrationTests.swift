import Foundation
import XCTest
@testable import AgentVisorCore

/// These tests exercise the same registry and lane that the app's
/// ProcessExecutor uses. They deliberately use a real child process rather
/// than asserting that a source file contains an operationID argument.
final class TerminalTransportProductionIntegrationTests: XCTestCase {
    func testAttachmentChildIsTerminatedAndAwaitedBeforeFollowingAction() async throws {
        try await assertChildIsTerminatedBeforeFollowingAction(label: "attachment")
    }

    func testITermAndGhosttyClearChildrenAreTerminatedByTheirOwnOperation() async throws {
        try await assertChildIsTerminatedBeforeFollowingAction(label: "iterm-clear")
        try await assertChildIsTerminatedBeforeFollowingAction(label: "ghostty-clear")
    }

    func testApprovalFallbackQueuesBehindAComposerTransaction() async throws {
        let serializer = TerminalTransportSerializer()
        let composerStarted = expectation(description: "composer started")
        let approvalStarted = expectation(description: "approval started")
        approvalStarted.isInverted = true
        let releaseComposer = expectation(description: "release composer")

        let composer = Task {
            try await serializer.withLane(
                sessionID: "session",
                ownerID: "chat-send-operation",
                operationTimeout: 1,
                operation: {
                    composerStarted.fulfill()
                    await self.fulfillment(of: [releaseComposer], timeout: 1)
                    return true
                },
                terminate: {}
            )
        }
        await fulfillment(of: [composerStarted], timeout: 1)

        let approval = Task {
            try await serializer.withLane(
                sessionID: "session",
                ownerID: "approval-key-operation",
                operationTimeout: 1,
                operation: {
                    approvalStarted.fulfill()
                    return true
                },
                terminate: {}
            )
        }

        await fulfillment(of: [approvalStarted], timeout: 0.05)
        releaseComposer.fulfill()
        let composerResult = try await composer.value
        let approvalResult = try await approval.value
        XCTAssertTrue(composerResult)
        XCTAssertTrue(approvalResult)
    }

    func testBoundedPiProbeResultRejectsTimeoutAndMalformedOutput() {
        XCTAssertEqual(
            PiTtyBackfillPolicy.tty(from: " ttys007\n", succeeded: true),
            "ttys007"
        )
        XCTAssertNil(PiTtyBackfillPolicy.tty(from: " ttys007\n", succeeded: false))
        XCTAssertNil(PiTtyBackfillPolicy.tty(from: "??\n", succeeded: true))
        XCTAssertNil(PiTtyBackfillPolicy.tty(from: "", succeeded: true))
        XCTAssertNil(PiTtyBackfillPolicy.tty(from: nil, succeeded: true))
    }

    private func assertChildIsTerminatedBeforeFollowingAction(label: String) async throws {
        // Use the process-wide registry that ProcessExecutor uses in Chat.
        // The operation ID is unique so this test cannot terminate another
        // concurrently running transport action.
        let registry = TerminalProcessOperationRegistry.shared
        let serializer = TerminalTransportSerializer()
        let child = try LiveChild()
        let started = Flag()
        let operationID = "chat-\(label)-\(UUID().uuidString)-operation"
        let token = registry.register(
            operationID: operationID,
            process: child.process,
            termination: child.termination
        )
        XCTAssertNotNil(token)

        let action = Task {
            try await serializer.withLane(
                sessionID: "session-\(label)",
                ownerID: operationID,
                operationTimeout: 1,
                operation: {
                    await started.set()
                    while child.isRunning {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    return true
                },
                terminate: {
                    registry.terminateAndWait(operationID: operationID)
                }
            )
        }

        while !(await started.value) { await Task.yield() }
        action.cancel()
        do {
            _ = try await action.value
            XCTFail("A canceled \(label) action must not succeed.")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(registry.liveCount(operationID: operationID), 1)

        let next = try await serializer.withLane(
            sessionID: "session-\(label)",
            ownerID: "next-\(label)",
            operationTimeout: 1,
            operation: {
                XCTAssertFalse(child.isRunning)
                return true
            },
            terminate: {}
        )
        XCTAssertTrue(next)
        registry.unregister(token)
        XCTAssertEqual(registry.liveCount(operationID: operationID), 0)
    }
}

private final class LiveChild: @unchecked Sendable {
    let process: Process
    let termination: DispatchSemaphore

    init() throws {
        process = Process()
        termination = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let termination = self.termination
        process.terminationHandler = { _ in termination.signal() }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
}

private actor Flag {
    private(set) var value = false

    func set() { value = true }
}
