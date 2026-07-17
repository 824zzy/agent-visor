import XCTest
@testable import AgentVisorCore

final class NotchMenuContextRefreshPolicyTests: XCTestCase {
    func testMissingContextAlwaysResolvesOwner() {
        XCTAssertTrue(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: false,
            contextFrontmostPid: nil,
            observedFrontmostPid: 100,
            contextTargetScreenID: nil,
            observedTargetScreenID: "screen-a"
        ))
    }

    func testWindowMoveDoesNotResolveOwnerAgainForSameFrontmostApp() {
        XCTAssertFalse(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a"
        ))
    }

    func testMissedActivationResolvesOwnerForDifferentFrontmostApp() {
        XCTAssertTrue(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 200,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a"
        ))
    }

    func testTransientMissingFrontmostDoesNotDiscardCurrentOwner() {
        XCTAssertFalse(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: nil,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a"
        ))
    }

    func testTargetScreenChangeResolvesOwnerEvenWhenFrontmostAppIsUnchanged() {
        XCTAssertTrue(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-b",
            contextOwnerIsResolved: true
        ))
    }

    func testUnresolvedOwnerRetriesWhenFrontmostAppAndScreenAreUnchanged() {
        XCTAssertTrue(NotchMenuContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerIsResolved: false
        ))
    }
}
