import XCTest
@testable import AgentVisorCore

final class TransientPopoverDismissalPolicyTests: XCTestCase {
    func testOutsideClickDismissesTransientPopover() {
        XCTAssertEqual(
            TransientPopoverDismissalPolicy.action(for: .outsideClick),
            .dismiss
        )
    }

    func testClickInsidePopoverKeepsItOpen() {
        XCTAssertEqual(
            TransientPopoverDismissalPolicy.action(for: .insidePopover),
            .keepOpen
        )
    }

    func testClickPresentingControlDefersToItsToggle() {
        XCTAssertEqual(
            TransientPopoverDismissalPolicy.action(for: .presentingControl),
            .deferToPresenter
        )
    }

    func testEscapeDismissesTransientPopover() {
        XCTAssertEqual(
            TransientPopoverDismissalPolicy.action(for: .escapeKey),
            .dismiss
        )
    }

    func testOtherKeysDoNotDismissTransientPopover() {
        XCTAssertEqual(
            TransientPopoverDismissalPolicy.action(for: .otherKey),
            .keepOpen
        )
    }
}
