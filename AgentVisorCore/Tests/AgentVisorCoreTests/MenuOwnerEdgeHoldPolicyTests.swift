import XCTest
import CoreGraphics
@testable import AgentVisorCore

final class MenuOwnerEdgeHoldPolicyTests: XCTestCase {
    private let screen = "screen-1"

    func testBeginHoldsAReliableEdge() {
        let s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 500)
    }

    func testBeginIgnoresNonPositiveOrMissingEdge() {
        XCTAssertNil(MenuOwnerEdgeHoldPolicy.heldEdge(
            MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 0)
        ))
        XCTAssertNil(MenuOwnerEdgeHoldPolicy.heldEdge(
            MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: nil)
        ))
    }

    func testNilObservationHoldsLastReliableEdge() {
        var s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        s = apply(nil, at: 1, to: s)
        XCTAssertEqual(
            MenuOwnerEdgeHoldPolicy.heldEdge(s), 500,
            "a transient loss of ownership must not collapse the held edge"
        )
    }

    func testMoreRoomAppliesImmediately() {
        var s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        s = apply(460, at: 1, to: s) // smaller edge = more room
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 460)
    }

    func testLessRoomRequiresPersistence() {
        var s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        s = apply(560, at: 1.0, to: s) // larger edge = less room, first sighting
        XCTAssertEqual(
            MenuOwnerEdgeHoldPolicy.heldEdge(s), 500,
            "a single narrower observation is held, not applied"
        )
        s = apply(560, at: 1.5, to: s) // 0.5s < 0.75s
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 500)
        s = apply(560, at: 1.9, to: s) // 0.9s >= 0.75s → confirmed
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 560)
    }

    func testTransientNarrowerFlapDoesNotContract() {
        var s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        s = apply(560, at: 1.0, to: s) // less room appears
        s = apply(500, at: 1.1, to: s) // flaps back to more room before confirmation
        XCTAssertEqual(
            MenuOwnerEdgeHoldPolicy.heldEdge(s), 500,
            "an unconfirmed contraction must not stick"
        )
        s = apply(560, at: 1.2, to: s) // reappears; confirmation timer restarts
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 500)
    }

    func testScreenChangeResetsHold() {
        var s = MenuOwnerEdgeHoldPolicy.begin(targetScreenID: screen, observedEdge: 500)
        s = apply(700, at: 1, screen: "screen-2", to: s)
        XCTAssertEqual(MenuOwnerEdgeHoldPolicy.heldEdge(s), 700)
    }

    private func apply(
        _ edge: CGFloat?,
        at time: TimeInterval,
        screen overrideScreen: String? = nil,
        to snapshot: MenuOwnerEdgeHoldSnapshot
    ) -> MenuOwnerEdgeHoldSnapshot {
        MenuOwnerEdgeHoldPolicy.applying(
            observedEdge: edge,
            observedAt: time,
            targetScreenID: overrideScreen ?? screen,
            to: snapshot
        )
    }
}
