import XCTest
@testable import AgentVisorCore

final class ClaudeHookSubscriptionPolicyTests: XCTestCase {
    func testFailureAndCompactionLifecycleEventsAreSubscribed() {
        let names = Set(ClaudeHookSubscriptionPolicy.subscriptions.map(\.event))

        XCTAssertTrue(names.contains("PostToolUseFailure"))
        XCTAssertTrue(names.contains("StopFailure"))
        XCTAssertTrue(names.contains("PostCompact"))
    }

    func testSubscriptionsAreUniqueAndUseTheExpectedMatchers() {
        let subscriptions = ClaudeHookSubscriptionPolicy.subscriptions
        XCTAssertEqual(Set(subscriptions.map(\.event)).count, subscriptions.count)

        let byName = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.event, $0) })
        XCTAssertEqual(byName["PostToolUseFailure"]?.matcher, .wildcard)
        XCTAssertEqual(byName["StopFailure"]?.matcher, ClaudeHookMatcher.none)
        XCTAssertEqual(byName["PreCompact"]?.matcher, .compaction)
        XCTAssertEqual(byName["PostCompact"]?.matcher, .compaction)
        XCTAssertEqual(byName["PermissionRequest"]?.timeoutSeconds, 86_400)
    }
}
