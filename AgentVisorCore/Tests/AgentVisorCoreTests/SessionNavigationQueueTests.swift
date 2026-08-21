import XCTest
@testable import AgentVisorCore

final class SessionNavigationQueueTests: XCTestCase {
    func testRunsOneRequestAtATimeAndSkipsStalePendingRequests() {
        let firstStarted = expectation(description: "first request started")
        let latestFinished = expectation(description: "latest request finished")
        let releaseFirst = DispatchSemaphore(value: 0)
        let recorder = NavigationRecorder()
        let queue = SessionNavigationQueue { session in
            recorder.start(session.sessionId)
            if session.sessionId == "A" {
                firstStarted.fulfill()
                releaseFirst.wait()
            }
            recorder.finish(session.sessionId)
            if session.sessionId == "C" {
                latestFinished.fulfill()
            }
        }

        queue.submit(SessionStateFixture.make(sessionId: "A"))
        wait(for: [firstStarted], timeout: 1)
        queue.submit(SessionStateFixture.make(sessionId: "B"))
        queue.submit(SessionStateFixture.make(sessionId: "C"))
        releaseFirst.signal()
        wait(for: [latestFinished], timeout: 1)

        XCTAssertEqual(recorder.events, ["start A", "end A", "start C", "end C"])
        XCTAssertEqual(recorder.maximumConcurrency, 1)
    }
}

private final class NavigationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var running = 0
    private var maximumRunning = 0

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    var maximumConcurrency: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumRunning
    }

    func start(_ id: String) {
        lock.lock()
        running += 1
        maximumRunning = max(maximumRunning, running)
        storedEvents.append("start \(id)")
        lock.unlock()
    }

    func finish(_ id: String) {
        lock.lock()
        storedEvents.append("end \(id)")
        running -= 1
        lock.unlock()
    }
}
