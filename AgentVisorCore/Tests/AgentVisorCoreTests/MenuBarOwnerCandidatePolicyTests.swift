import XCTest
@testable import AgentVisorCore

final class MenuBarOwnerCandidatePolicyTests: XCTestCase {
    func testRegularBundleBackedWindowCanOwnTargetMenu() {
        XCTAssertTrue(MenuBarOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: true,
            hasBundleIdentifier: true
        ))
    }

    func testHelperWithoutBundleIdentifierCannotOwnTargetMenu() {
        XCTAssertFalse(MenuBarOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: true,
            hasBundleIdentifier: false
        ))
    }

    func testNonRegularHelperCannotOwnTargetMenu() {
        XCTAssertFalse(MenuBarOwnerCandidatePolicy.canOwnTargetMenu(
            windowLayer: 0,
            isOwnProcess: false,
            isOnTargetScreen: true,
            isRegularApplication: false,
            hasBundleIdentifier: true
        ))
    }
}
