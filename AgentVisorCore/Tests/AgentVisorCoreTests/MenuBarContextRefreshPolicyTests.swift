import XCTest
@testable import AgentVisorCore

final class MenuBarContextRefreshPolicyTests: XCTestCase {
    func testMissingContextAlwaysResolvesOwner() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: false,
            contextFrontmostPid: nil,
            observedFrontmostPid: 100,
            contextTargetScreenID: nil,
            observedTargetScreenID: "screen-a"
        ))
    }

    func testWindowMoveResolvesOwnerWhenSameFrontmostAppNowOwnsTargetScreen() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerPid: 200,
            observedOwnerPid: 100,
            observedOwnerIsResolved: true
        ))
    }

    func testWindowMoveResolvesTopmostOwnerWhenSameFrontmostAppLeavesTargetScreen() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerPid: 100,
            observedOwnerPid: 200,
            observedOwnerIsResolved: true
        ))
    }

    func testTransientUnresolvedTopologyDoesNotReplaceReliableOwner() {
        XCTAssertFalse(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerPid: 200,
            observedOwnerPid: 100,
            observedOwnerIsResolved: false,
            contextOwnerIsResolved: true
        ))
    }

    func testStableResolvedTopologyDoesNotStartAnotherGeneration() {
        XCTAssertFalse(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerPid: 100,
            observedOwnerPid: 100,
            observedOwnerIsResolved: true,
            contextOwnerIsResolved: true
        ))
    }

    func testMissedActivationResolvesOwnerForDifferentFrontmostApp() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 200,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a"
        ))
    }

    func testTransientMissingFrontmostDoesNotDiscardCurrentOwner() {
        XCTAssertFalse(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: nil,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a"
        ))
    }

    func testTargetScreenChangeResolvesOwnerEvenWhenFrontmostAppIsUnchanged() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-b",
            contextOwnerIsResolved: true
        ))
    }

    func testUnresolvedOwnerRetriesWhenFrontmostAppAndScreenAreUnchanged() {
        XCTAssertTrue(MenuBarContextRefreshPolicy.shouldResolveOwner(
            hasContext: true,
            contextFrontmostPid: 100,
            observedFrontmostPid: 100,
            contextTargetScreenID: "screen-a",
            observedTargetScreenID: "screen-a",
            contextOwnerIsResolved: false
        ))
    }
}
