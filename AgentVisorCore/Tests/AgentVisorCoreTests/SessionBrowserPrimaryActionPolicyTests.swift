import XCTest
@testable import AgentVisorCore

final class SessionBrowserPrimaryActionPolicyTests: XCTestCase {
    func testFooterLabelsDescribeStableIntentWithoutNamingAProvider() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.footerLabel(for: .enterChat),
            "Enter Chat"
        )
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.footerLabel(for: .openOriginal),
            "Continue in source app"
        )
        XCTAssertNil(SessionBrowserPrimaryActionPolicy.footerLabel(for: .none))
    }

    func testChatIsTheStableRowActionWhenBothDestinationsAreAvailable() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: true
            ),
            .enterChat
        )
    }

    func testShiftReturnOpensOriginalWhenBothDestinationsAreAvailable() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: true,
                alternate: true
            ),
            .openOriginal
        )
    }

    func testOriginalOwnerIsTheFallbackForMetadataOnlyRows() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: false,
                canOpenOriginal: true
            ),
            .openOriginal
        )
    }

    func testShiftReturnFallsBackToChatWhenOwnerRoutingIsUnavailable() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: false,
                alternate: true
            ),
            .enterChat
        )
    }

    func testRowHasNoInventedDestinationWhenNeitherCapabilityExists() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: false,
                canOpenOriginal: false
            ),
            .none
        )
    }
}
