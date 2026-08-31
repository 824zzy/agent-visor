import XCTest
@testable import AgentVisorCore

final class TerminalTransportSerializerTests: XCTestCase {
    func testSerializesOneSessionButAllowsUnrelatedSession() async {
        let serializer = TerminalTransportSerializer()
        let firstStarted = expectation(description: "first started")
        let releaseFirst = expectation(description: "release first")
        let sameSessionStarted = expectation(description: "same session started")
        let unrelatedStarted = expectation(description: "unrelated started")
        let firstFinished = expectation(description: "first finished")
        let secondFinished = expectation(description: "second finished")

        let first = Task {
            await serializer.run(sessionID: "session-a") {
                firstStarted.fulfill()
                await self.fulfillment(of: [releaseFirst], timeout: 1)
                firstFinished.fulfill()
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let blockedSameSession = Task {
            await serializer.run(sessionID: "session-a") {
                sameSessionStarted.fulfill()
                secondFinished.fulfill()
            }
        }
        let unrelated = Task {
            await serializer.run(sessionID: "session-b") {
                unrelatedStarted.fulfill()
            }
        }

        await fulfillment(of: [unrelatedStarted], timeout: 1)
        XCTAssertFalse(blockedSameSession.isCancelled)
        releaseFirst.fulfill()
        await fulfillment(of: [firstFinished, sameSessionStarted, secondFinished], timeout: 1)
        _ = await first.value
        _ = await blockedSameSession.value
        _ = await unrelated.value
    }

    func testRepeatedReleaseCannotOpenASecondLane() async {
        let serializer = TerminalTransportSerializer()
        await serializer.acquire(sessionID: "session")
        await serializer.release(sessionID: "session")
        await serializer.release(sessionID: "session")
        await serializer.acquire(sessionID: "session")
        await serializer.release(sessionID: "session")
    }

    func testAcquireTimeoutRemovesWaiterAndDoesNotRunItLater() async throws {
        let serializer = TerminalTransportSerializer()
        let owner = try await serializer.acquire(
            sessionID: "session",
            ownerID: "owner",
            acquisitionTimeout: 0.5
        )

        let waiter = Task {
            try await serializer.acquire(
                sessionID: "session",
                ownerID: "waiter",
                acquisitionTimeout: 0.02
            )
        }
        while await serializer.waiterCount(sessionID: "session") == 0 {
            await Task.yield()
        }

        do {
            _ = try await waiter.value
            XCTFail("The bounded acquisition should time out.")
        } catch TerminalTransportSerializerError.acquisitionTimedOut {
            // expected
        }
        let waiterCountAfterTimeout = await serializer.waiterCount(sessionID: "session")
        XCTAssertEqual(waiterCountAfterTimeout, 0)
        await serializer.release(owner)

        let next = try await serializer.acquire(
            sessionID: "session",
            ownerID: "next",
            acquisitionTimeout: 0.1
        )
        await serializer.release(next)
    }

    func testCancelledWaiterIsRemovedAndFIFOSurvivorAcquires() async throws {
        let serializer = TerminalTransportSerializer()
        let owner = try await serializer.acquire(
            sessionID: "session",
            ownerID: "owner",
            acquisitionTimeout: 0.1
        )
        let canceled = Task {
            try await serializer.acquire(
                sessionID: "session",
                ownerID: "canceled",
                acquisitionTimeout: 1
            )
        }
        while await serializer.waiterCount(sessionID: "session") == 0 {
            await Task.yield()
        }
        let survivor = Task {
            try await serializer.acquire(
                sessionID: "session",
                ownerID: "survivor",
                acquisitionTimeout: 1
            )
        }
        while await serializer.waiterCount(sessionID: "session") < 2 {
            await Task.yield()
        }

        canceled.cancel()
        do {
            _ = try await canceled.value
            XCTFail("A canceled waiter must not acquire the lane.")
        } catch is CancellationError {
            // expected
        }
        let waiterCountAfterCancel = await serializer.waiterCount(sessionID: "session")
        XCTAssertEqual(waiterCountAfterCancel, 1)

        await serializer.release(owner)
        let acquired = try await survivor.value
        XCTAssertEqual(acquired.ownerID, "survivor")
        await serializer.release(acquired)
    }

    func testDuplicateOwnerFailsFastInsteadOfDeadlocking() async throws {
        let serializer = TerminalTransportSerializer()
        let first = try await serializer.acquire(
            sessionID: "session",
            ownerID: "same-owner",
            acquisitionTimeout: 0.1
        )
        do {
            _ = try await serializer.acquire(
                sessionID: "session",
                ownerID: "same-owner",
                acquisitionTimeout: 0.1
            )
            XCTFail("Nested ownership must fail fast.")
        } catch TerminalTransportSerializerError.reentrantOwnership {
            // expected
        }
        await serializer.release(first)
    }

    func testTimedOutOperationWaitsForTerminationBeforeNextWrite() async throws {
        let serializer = TerminalTransportSerializer()
        let harness = TimeoutHarness()

        do {
            _ = try await serializer.withLane(
                sessionID: "session",
                ownerID: "hung",
                acquisitionTimeout: 0.1,
                operationTimeout: 0.02,
                operation: {
                    await harness.markStarted()
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    } catch {
                        await harness.markTerminated()
                        throw error
                    }
                    await harness.markLateWrite()
                    return true
                },
                terminate: {
                    await harness.markTerminateRequested()
                }
            )
            XCTFail("The bounded operation should time out.")
        } catch TerminalTransportSerializerError.operationTimedOut {
            // expected
        }

        let terminationRequested = await harness.terminationRequested
        let terminated = await harness.terminated
        let lateWrite = await harness.lateWrite
        XCTAssertTrue(terminationRequested)
        XCTAssertTrue(terminated)
        XCTAssertFalse(lateWrite)

        let next = try await serializer.withLane(
            sessionID: "session",
            ownerID: "next",
            acquisitionTimeout: 0.1,
            operationTimeout: 0.1,
            operation: {
                await harness.markNextStarted()
                return true
            }
        )
        XCTAssertTrue(next)
        let nextStarted = await harness.nextStarted
        XCTAssertTrue(nextStarted)
    }

    func testUnrelatedSessionLanesRemainConcurrentUnderTimeout() async throws {
        let serializer = TerminalTransportSerializer()
        let started = ExpectationCounter()
        let first = Task {
            try await serializer.withLane(
                sessionID: "session-a",
                ownerID: "a",
                acquisitionTimeout: 0.1,
                operationTimeout: 0.2,
                operation: {
                    await started.increment()
                    try await Task.sleep(nanoseconds: 20_000_000)
                    return true
                }
            )
        }
        let second = Task {
            try await serializer.withLane(
                sessionID: "session-b",
                ownerID: "b",
                acquisitionTimeout: 0.1,
                operationTimeout: 0.2,
                operation: {
                    await started.increment()
                    return true
                }
            )
        }
        _ = try await first.value
        _ = try await second.value
        let startCount = await started.value
        XCTAssertEqual(startCount, 2)
    }

    func testCanceledOperationTerminatesBeforeFollowingSend() async throws {
        let serializer = TerminalTransportSerializer()
        let harness = TimeoutHarness()
        let cancel = Task {
            try await serializer.withLane(
                sessionID: "session",
                ownerID: "cancel",
                acquisitionTimeout: 0.1,
                operationTimeout: 1,
                operation: {
                    await harness.markStarted()
                    do {
                        while true {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                        }
                    } catch {
                        await harness.markTerminated()
                        throw error
                    }
                },
                terminate: {
                    await harness.markTerminateRequested()
                }
            )
        }
        while !(await harness.hasStarted) { await Task.yield() }
        cancel.cancel()
        do {
            _ = try await cancel.value
            XCTFail("A canceled transport operation must not report success.")
        } catch is CancellationError {
            // expected
        }

        let terminated = await harness.terminated
        let terminationRequested = await harness.terminationRequested
        XCTAssertTrue(terminated)
        XCTAssertTrue(terminationRequested)
        let next = try await serializer.withLane(
            sessionID: "session",
            ownerID: "following-send",
            acquisitionTimeout: 0.1,
            operationTimeout: 0.1,
            operation: { true }
        )
        XCTAssertTrue(next)
    }
}

private actor TimeoutHarness {
    private(set) var hasStarted = false
    private(set) var terminationRequested = false
    private(set) var terminated = false
    private(set) var lateWrite = false
    private(set) var nextStarted = false

    func markStarted() { hasStarted = true }
    func markTerminateRequested() { terminationRequested = true }
    func markTerminated() { terminated = true }
    func markLateWrite() { lateWrite = true }
    func markNextStarted() { nextStarted = true }
}

private actor ExpectationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
