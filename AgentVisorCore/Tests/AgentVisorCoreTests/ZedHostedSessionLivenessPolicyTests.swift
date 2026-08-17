import XCTest
@testable import AgentVisorCore

/// The Zed host rule decides liveness for any agent hosted inside Zed, and it
/// is asked before the agent's own rule.
final class ZedHostedSessionLivenessPolicyTests: XCTestCase {
    private let window: TimeInterval = 42 * 60 * 60

    func testZedNotRunningKillsEveryThread() {
        // Definitive: the host is gone, so no thread it hosted can be live,
        // whatever the transcript says.
        XCTAssertTrue(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: false,
                idleSeconds: 0,
                idleWindow: window
            )
        )
    }

    func testFreshThreadStaysAliveWhileZedRuns() {
        XCTAssertFalse(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: true,
                idleSeconds: 5,
                idleWindow: window
            )
        )
    }

    func testIdleButOpenThreadStaysAliveInsideTheWindow() {
        // The reported bug: a 30s window made an open thread vanish as soon as
        // the user stopped typing. Hours of silence must not prune it.
        XCTAssertFalse(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: true,
                idleSeconds: 6 * 60 * 60,
                idleWindow: window
            )
        )
    }

    func testThreadExactlyAtTheWindowStaysAlive() {
        XCTAssertFalse(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: true,
                idleSeconds: window,
                idleWindow: window
            )
        )
    }

    func testThreadPastTheWindowIsDead() {
        XCTAssertTrue(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: true,
                idleSeconds: window + 1,
                idleWindow: window
            )
        )
    }

    func testTheWindowIsTheCallersChoice() {
        // The store passes the observed-agent window, which the user can
        // change in settings. A short window must still be honoured.
        XCTAssertTrue(
            ZedHostedSessionLivenessPolicy.isDead(
                zedRunning: true,
                idleSeconds: 61,
                idleWindow: 60
            )
        )
    }
}
