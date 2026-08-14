import XCTest
@testable import AgentVisorCore

/// Decision table for what a global mouseDown should do based on the
/// current notch state. Closed: only notch-region clicks open. Opened:
/// outside-clicks are *always ignored* (persistence parity across
/// content types — chat, sessions list, menu); only the notch-shape
/// click dismisses, alongside out-of-band paths (Esc, double-shift
/// hotkey, back-arrow button).
final class NotchClickPolicyTests: XCTestCase {

    // MARK: - Closed state

    func test_closed_clickOnNotch_opens() {
        XCTAssertEqual(
            NotchClickPolicy.action(status: .closed, inNotch: true, inVisiblePanel: false, hasPhysicalNotch: true),
            .open
        )
    }

    func test_closed_clickOutsideNotch_doesNothing() {
        XCTAssertEqual(
            NotchClickPolicy.action(status: .closed, inNotch: false, inVisiblePanel: false, hasPhysicalNotch: true),
            .ignore
        )
    }

    func test_popping_clickOnNotch_opens() {
        // Status during the open animation. Treat like closed.
        XCTAssertEqual(
            NotchClickPolicy.action(status: .popping, inNotch: true, inVisiblePanel: false, hasPhysicalNotch: true),
            .open
        )
    }

    // MARK: - No physical notch (external display)

    func test_noPhysicalNotch_clickInNotchRegion_isIgnored() {
        // On an external display there is no synthetic notch and no
        // click-to-open target. A click that geometry still classifies
        // as "in notch" (the vestigial center hit region) must not open
        // the main window — that was the empty-menu-bar-space bug.
        XCTAssertEqual(
            NotchClickPolicy.action(status: .closed, inNotch: true, inVisiblePanel: false, hasPhysicalNotch: false),
            .ignore
        )
    }

    func test_noPhysicalNotch_neverOpensOrCloses_acrossStates() {
        for status in [NotchStatusInput.closed, .popping, .opened] {
            for inNotch in [true, false] {
                for inVisiblePanel in [true, false] {
                    XCTAssertEqual(
                        NotchClickPolicy.action(
                            status: status,
                            inNotch: inNotch,
                            inVisiblePanel: inVisiblePanel,
                            hasPhysicalNotch: false
                        ),
                        .ignore,
                        "status=\(status) inNotch=\(inNotch) inVisiblePanel=\(inVisiblePanel) should ignore without a physical notch"
                    )
                }
            }
        }
    }

    // MARK: - Opened — uniform persistence

    func test_opened_clickOutsidePanel_isIgnored() {
        // Outside clicks must NOT close the panel, regardless of
        // content type. Users need to operate in another app while
        // keeping the panel visible.
        XCTAssertEqual(
            NotchClickPolicy.action(status: .opened, inNotch: false, inVisiblePanel: false, hasPhysicalNotch: true),
            .ignore
        )
    }

    func test_opened_clickInsidePanel_isIgnored() {
        // Inside-panel clicks are handled by SwiftUI; the policy stays
        // out of the way.
        XCTAssertEqual(
            NotchClickPolicy.action(status: .opened, inNotch: false, inVisiblePanel: true, hasPhysicalNotch: true),
            .ignore
        )
    }

    func test_opened_clickOnNotchShape_closes() {
        // The dismissal gesture: spatially symmetric with the open
        // gesture (click the notch). Notch shape sits inside the
        // visible panel when opened.
        XCTAssertEqual(
            NotchClickPolicy.action(status: .opened, inNotch: true, inVisiblePanel: true, hasPhysicalNotch: true),
            .close
        )
    }

    func test_opened_clickOnNotchOutsideVisiblePanel_closes() {
        // Notch hit-region without visible-panel overlap is also a
        // valid close gesture (defensive — covers the closed→opened
        // race where panel geometry hasn't expanded yet).
        XCTAssertEqual(
            NotchClickPolicy.action(status: .opened, inNotch: true, inVisiblePanel: false, hasPhysicalNotch: true),
            .close
        )
    }
}
