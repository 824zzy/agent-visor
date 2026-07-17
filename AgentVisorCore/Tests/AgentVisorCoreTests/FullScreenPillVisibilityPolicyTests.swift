import CoreGraphics
import XCTest
@testable import AgentVisorCore

final class FullScreenPillVisibilityPolicyTests: XCTestCase {
    func testWindowedStripIsVisibleForEveryPolicy() {
        for policy in FullScreenPillPolicy.allCases {
            XCTAssertTrue(isVisible(isFullScreen: false, policy: policy))
        }
    }

    func testOnDemandIsHiddenAtRestInFullScreen() {
        XCTAssertFalse(isVisible(isFullScreen: true, policy: .onDemand))
    }

    func testOnDemandRevealsForPointerOrShortcutIntent() {
        XCTAssertTrue(isVisible(
            isFullScreen: true,
            policy: .onDemand,
            pointerRevealActive: true
        ))
        XCTAssertTrue(isVisible(
            isFullScreen: true,
            policy: .onDemand,
            shortcutRevealActive: true
        ))
    }

    func testAlwaysHideIgnoresPassiveRevealIntent() {
        XCTAssertFalse(isVisible(
            isFullScreen: true,
            policy: .alwaysHide,
            pointerRevealActive: true,
            shortcutRevealActive: true
        ))
    }

    func testExplicitPopoverStaysUsableForEveryPolicy() {
        for policy in FullScreenPillPolicy.allCases {
            XCTAssertTrue(isVisible(
                isFullScreen: true,
                policy: policy,
                popoverPresented: true
            ))
        }
    }

    func testAlwaysShowRemainsVisibleInFullScreen() {
        XCTAssertTrue(isVisible(isFullScreen: true, policy: .alwaysShow))
    }

    func testPersistedLegacyPoliciesMigrateToNewSemantics() {
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue(nil), .onDemand)
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue("media"), .onDemand)
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue("never"), .onDemand)
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue("alwaysHide"), .alwaysHide)
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue("alwaysShow"), .alwaysShow)
        XCTAssertEqual(FullScreenPillPolicy.fromPersistedValue("unknown"), .onDemand)
    }

    func testPointerMustReachTargetScreensTopActivationEdge() {
        let screen = CGRect(x: -1200, y: -900, width: 1200, height: 900)

        XCTAssertTrue(FullScreenPillPointerZonePolicy.contains(
            pointer: CGPoint(x: -600, y: -2),
            screenRect: screen,
            isRevealed: false
        ))
        XCTAssertFalse(FullScreenPillPointerZonePolicy.contains(
            pointer: CGPoint(x: -600, y: -4),
            screenRect: screen,
            isRevealed: false
        ))
        XCTAssertFalse(FullScreenPillPointerZonePolicy.contains(
            pointer: CGPoint(x: 100, y: -1),
            screenRect: screen,
            isRevealed: false
        ))
    }

    func testRevealedPointerUsesTheFullRetentionBand() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertTrue(FullScreenPillPointerZonePolicy.contains(
            pointer: CGPoint(x: 720, y: 861),
            screenRect: screen,
            isRevealed: true
        ))
        XCTAssertFalse(FullScreenPillPointerZonePolicy.contains(
            pointer: CGPoint(x: 720, y: 859),
            screenRect: screen,
            isRevealed: true
        ))
    }

    private func isVisible(
        isFullScreen: Bool,
        policy: FullScreenPillPolicy,
        pointerRevealActive: Bool = false,
        shortcutRevealActive: Bool = false,
        popoverPresented: Bool = false
    ) -> Bool {
        FullScreenPillVisibilityPolicy.isVisible(
            isFullScreenActive: isFullScreen,
            policy: policy,
            pointerRevealActive: pointerRevealActive,
            shortcutRevealActive: shortcutRevealActive,
            popoverPresented: popoverPresented
        )
    }
}
