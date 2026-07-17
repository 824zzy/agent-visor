import XCTest
@testable import AgentVisorCore

final class NotchMenuOwnerCandidatePolicyTests: XCTestCase {
    func testRegularBundleBackedWindowCanOwnTargetMenu() {
        XCTAssertTrue(NotchMenuOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: true,
            hasBundleIdentifier: true
        ))
    }

    func testHelperWithoutBundleIdentifierCannotOwnTargetMenu() {
        XCTAssertFalse(NotchMenuOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: true,
            hasBundleIdentifier: false
        ))
    }

    func testNonRegularHelperCannotOwnTargetMenu() {
        XCTAssertFalse(NotchMenuOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: false,
            hasBundleIdentifier: true
        ))
    }
}
