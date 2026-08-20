import XCTest
@testable import AgentVisorCore

final class SessionBrowserPrimaryActionPolicyTests: XCTestCase {
    func testFooterLabelsDescribeStableIntentWithoutNamingAProvider() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.footerLabel(for: .enterChat),
            "Open Chat"
        )
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.footerLabel(for: .openOriginal),
            "Open source app"
        )
        XCTAssertNil(SessionBrowserPrimaryActionPolicy.footerLabel(for: .none))
    }

    func testSourceAppIsTheRowActionWhenBothDestinationsAreAvailable() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: true
            ),
            .openOriginal
        )
    }

    func testShiftReturnOpensChatWhenBothDestinationsAreAvailable() {
        XCTAssertEqual(
            SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: true,
                alternate: true
            ),
            .enterChat
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
