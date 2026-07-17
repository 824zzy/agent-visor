import XCTest
@testable import AgentVisorCore

final class PillHoverContextMenuPolicyTests: XCTestCase {
    func testContextMenuSuppressesHoverUntilPointerLeavesAndReenters() {
        var state = PillHoverContextMenuState()

        state = PillHoverContextMenuPolicy.applying(.pointerEntered, to: state)
        XCTAssertTrue(state.canPresentHover)

        state = PillHoverContextMenuPolicy.applying(.contextMenuOpened, to: state)
        XCTAssertFalse(state.canPresentHover)

        state = PillHoverContextMenuPolicy.applying(.contextMenuClosed, to: state)
        XCTAssertFalse(state.canPresentHover)

        state = PillHoverContextMenuPolicy.applying(.pointerEntered, to: state)
        XCTAssertFalse(state.canPresentHover)

        state = PillHoverContextMenuPolicy.applying(.pointerExited, to: state)
        state = PillHoverContextMenuPolicy.applying(.pointerEntered, to: state)
        XCTAssertTrue(state.canPresentHover)
    }

    func testPrimaryActionAlsoRequiresAFreshHover() {
        var state = PillHoverContextMenuState()
        state = PillHoverContextMenuPolicy.applying(.pointerEntered, to: state)

        state = PillHoverContextMenuPolicy.applying(.primaryActionTriggered, to: state)
        XCTAssertFalse(state.canPresentHover)

        state = PillHoverContextMenuPolicy.applying(.pointerExited, to: state)
        state = PillHoverContextMenuPolicy.applying(.pointerEntered, to: state)
        XCTAssertTrue(state.canPresentHover)
    }
}
