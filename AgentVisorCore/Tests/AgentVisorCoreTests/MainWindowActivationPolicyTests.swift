import XCTest
@testable import AgentVisorCore

final class MainWindowActivationPolicyTests: XCTestCase {
    func testAppLaunchIsPassive() {
        XCTAssertEqual(
            MainWindowActivationPolicy.action(for: .appLaunch),
            .ignore
        )
    }

    func testBackgroundPendingApprovalDoesNotOpenWindow() {
        XCTAssertEqual(
            MainWindowActivationPolicy.action(for: .pendingApprovalDetected),
            .ignore
        )
    }

    func testExplicitOpenReasonsShowWindow() {
        for reason in [
            MainWindowActivationReason.appReopen,
            .settings,
            .notchClick,
            .overflowPill,
            .approvalNotificationTap,
        ] {
            XCTAssertEqual(
                MainWindowActivationPolicy.action(for: reason),
                .show,
                "\(reason)"
            )
        }
    }

    func testHotkeyTogglesWindow() {
        XCTAssertEqual(
            MainWindowActivationPolicy.action(for: .hotkey),
            .toggle
        )
    }
}
