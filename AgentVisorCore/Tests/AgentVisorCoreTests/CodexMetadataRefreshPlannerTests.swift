import XCTest
@testable import AgentVisorCore

final class CodexMetadataRefreshPlannerTests: XCTestCase {
    func testFirstMetadataChangeRefreshesKnownSessionsThenRediscoversNewOnes() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            CodexMetadataRefreshPlanner.actionsForMetadataChange(
                now: now,
                lastRediscoveryAt: nil,
                hasScheduledRediscovery: false,
                requiresRediscovery: true,
                rediscoveryCooldownSeconds: 10
            ),
            [.refreshKnownSessions, .rediscoverSessions]
        )
    }

    func testMetadataChangeWithinCooldownRefreshesKnownSessionsAndSchedulesTrailingRediscovery() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let last = Date(timeIntervalSinceReferenceDate: 995)

        XCTAssertEqual(
            CodexMetadataRefreshPlanner.actionsForMetadataChange(
                now: now,
                lastRediscoveryAt: last,
                hasScheduledRediscovery: false,
                requiresRediscovery: true,
                rediscoveryCooldownSeconds: 10
            ),
            [.refreshKnownSessions, .scheduleRediscovery(after: 5)]
        )
    }

    func testMetadataChangeWithinCooldownDoesNotScheduleDuplicateTrailingRediscovery() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let last = Date(timeIntervalSinceReferenceDate: 995)

        XCTAssertEqual(
            CodexMetadataRefreshPlanner.actionsForMetadataChange(
                now: now,
                lastRediscoveryAt: last,
                hasScheduledRediscovery: true,
                requiresRediscovery: true,
                rediscoveryCooldownSeconds: 10
            ),
            [.refreshKnownSessions]
        )
    }

    func testMetadataChangeAfterCooldownRediscoversImmediately() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let last = Date(timeIntervalSinceReferenceDate: 989)

        XCTAssertEqual(
            CodexMetadataRefreshPlanner.actionsForMetadataChange(
                now: now,
                lastRediscoveryAt: last,
                hasScheduledRediscovery: false,
                requiresRediscovery: true,
                rediscoveryCooldownSeconds: 10
            ),
            [.refreshKnownSessions, .rediscoverSessions]
        )
    }

    func testMetadataChangeWithoutDiscoverySetChangeOnlyRefreshesKnownSessions() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            CodexMetadataRefreshPlanner.actionsForMetadataChange(
                now: now,
                lastRediscoveryAt: nil,
                hasScheduledRediscovery: false,
                requiresRediscovery: false,
                rediscoveryCooldownSeconds: 10
            ),
            [.refreshKnownSessions]
        )
    }
}
