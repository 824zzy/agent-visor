import XCTest
@testable import AgentVisorCore

final class UpdateNotificationPolicyTests: XCTestCase {
    func testAutomaticDiscoveryNotifiesWhenVersionHasNotBeenSeen() {
        XCTAssertTrue(UpdateNotificationPolicy.shouldNotify(
            version: "2.3.1",
            lastNotifiedVersion: nil,
            isUserInitiated: false
        ))
    }

    func testSameVersionDoesNotNotifyAgain() {
        XCTAssertFalse(UpdateNotificationPolicy.shouldNotify(
            version: "2.3.1",
            lastNotifiedVersion: "2.3.1",
            isUserInitiated: false
        ))
    }

    func testNewVersionNotifiesAfterAnOlderVersion() {
        XCTAssertTrue(UpdateNotificationPolicy.shouldNotify(
            version: "2.3.2",
            lastNotifiedVersion: "2.3.1",
            isUserInitiated: false
        ))
    }

    func testUserInitiatedCheckDoesNotEmitANotification() {
        XCTAssertFalse(UpdateNotificationPolicy.shouldNotify(
            version: "2.3.1",
            lastNotifiedVersion: nil,
            isUserInitiated: true
        ))
    }

    func testVersionComparisonIgnoresWhitespaceAndVPrefix() {
        XCTAssertFalse(UpdateNotificationPolicy.shouldNotify(
            version: " v2.3.1 ",
            lastNotifiedVersion: "2.3.1",
            isUserInitiated: false
        ))
    }

    func testEmptyVersionDoesNotNotify() {
        XCTAssertFalse(UpdateNotificationPolicy.shouldNotify(
            version: "   ",
            lastNotifiedVersion: nil,
            isUserInitiated: false
        ))
    }

    func testDescriptorUsesStableRouteAndHumanReadableVersion() throws {
        let descriptor = try XCTUnwrap(UpdateNotificationPolicy.descriptor(version: "2.3.1"))
        XCTAssertEqual(descriptor.identifier, "cv.update.2.3.1")
        XCTAssertEqual(descriptor.route, "update-details")
        XCTAssertEqual(descriptor.title, "Agent Visor v2.3.1 is available")
        XCTAssertEqual(descriptor.body, "Open update details to review and install it.")
    }
}
