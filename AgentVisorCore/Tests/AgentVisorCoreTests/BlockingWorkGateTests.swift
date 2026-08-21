import XCTest
@testable import AgentVisorCore

/// The gate exists to stop one fan-out from holding every worker thread in the
/// app. These tests pin the three facts that makes it work: it bounds how many
/// run at once, it serves waiters in the order they arrived, and it never loses
/// a permit.
final class BlockingWorkGateTests: XCTestCase {
    func testNeverRunsMoreThanItsPermits() async {
        let gate = BlockingWorkGate(permits: 3)
        let counter = PeakCounter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await gate.withPermit {
                        await counter.enter()
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await counter.leave()
                    }
                }
            }
        }

        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 3, "The gate let \(peak) run at once with 3 permits.")
        XCTAssertGreaterThan(peak, 1, "With 40 callers and 3 permits, more than one should overlap.")
    }

    func testAPermitAlwaysComesBack() async {
        let gate = BlockingWorkGate(permits: 2)
        for _ in 0..<20 {
            await gate.withPermit { }
        }
        let busy = await gate.busy
        XCTAssertEqual(busy, 0, "Permits leaked: \(busy) still in use after every call returned.")
    }

    func testAFailedReadReturnsItsPermit() async {
        struct ReadFailed: Error {}
        let gate = BlockingWorkGate(permits: 1)

        for _ in 0..<5 {
            do {
                try await gate.withPermit { throw ReadFailed() }
                XCTFail("The error should reach the caller.")
            } catch is ReadFailed {
                // expected
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // If a failure leaked the single permit, this call would never return.
        await gate.withPermit { }
        let busy = await gate.busy
        XCTAssertEqual(busy, 0)
    }

    func testWaitersAreServedInTheOrderTheyArrived() async {
        let gate = BlockingWorkGate(permits: 1)
        let order = OrderLog()

        // Hold the only permit, so everything after this must queue.
        await gate.acquire()

        var tasks: [Task<Void, Never>] = []
        for index in 0..<5 {
            // Ask in order, and wait until each caller is really queued before
            // the next one asks. Otherwise the test would race, not measure.
            let task = Task {
                await gate.acquire()
                await order.record(index)
                await gate.release()
            }
            tasks.append(task)
            while await gate.queued < index + 1 {
                await Task.yield()
            }
        }

        await gate.release()
        for task in tasks { await task.value }

        let recorded = await order.entries
        XCTAssertEqual(recorded, [0, 1, 2, 3, 4], "A later caller was served before an earlier one.")
    }

    func testWaitingCostsNoPermit() async {
        let gate = BlockingWorkGate(permits: 2)
        await gate.acquire()
        await gate.acquire()

        let waiter = Task { await gate.acquire() }
        while await gate.queued < 1 { await Task.yield() }

        let busy = await gate.busy
        XCTAssertEqual(busy, 2, "A waiting caller must not count as running.")

        await gate.release()
        await waiter.value
        await gate.release()
        await gate.release()
    }

    func testOnePermitIsTheFloor() async {
        // A gate of zero would stop the app dead. Asking for it gets one.
        let gate = BlockingWorkGate(permits: 0)
        await gate.withPermit { }
        let busy = await gate.busy
        XCTAssertEqual(busy, 0)
    }
}

private actor PeakCounter {
    private(set) var peak = 0
    private var current = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

private actor OrderLog {
    private(set) var entries: [Int] = []

    func record(_ value: Int) {
        entries.append(value)
    }
}
