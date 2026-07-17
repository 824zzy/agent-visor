import XCTest
@testable import AgentVisorCore

/// Tests the policy that decides the trailing-slot reserved width for
/// the sidebar row. Bug context: the row swaps between a relative-
/// timestamp text ("1d"), a hover-only terminal-jump icon, a ⌘N
/// hotkey badge, and inline approval buttons in the SAME slot. Each
/// has a different intrinsic width, so the trailing-anchored HStack
/// reflows on hover, producing jitter — visible because the row's
/// `.animation(value: isHovered)` then animates the width swap.
///
/// Rule: the slot must reserve a fixed width that fits the WIDEST
/// non-approval variant. Approval buttons are wider but rare, and
/// only appear during a permission prompt — those are allowed to
/// expand the slot.
final class SidebarTrailingSlotMetricsTests: XCTestCase {

    private typealias Metrics = SidebarTrailingSlotMetrics

    func testTimestampSlotMatchesIconSlot() {
        // The two states the user mouses between hundreds of times a
        // day. They MUST be identical, or hover causes layout reflow.
        XCTAssertEqual(
            Metrics.reservedWidth(for: .timestamp),
            Metrics.reservedWidth(for: .terminalIcon)
        )
    }

    func testCommandBadgeSlotMatchesTimestampSlot() {
        // Holding ⌘ flips the timestamp to a "⌘N" badge. Same slot.
        XCTAssertEqual(
            Metrics.reservedWidth(for: .commandBadge),
            Metrics.reservedWidth(for: .timestamp)
        )
    }

    func testReservedWidthIsAtLeastWidestNonApprovalVariant() {
        // Width must accommodate the widest realistic timestamp text
        // ("23m", "10h", "365d") plus its padding. Empirically the
        // terminal icon button is ~22pt; widest timestamp text is
        // ~24pt. Slot must be >= 24pt to avoid clipping.
        let widths: [CGFloat] = [
            Metrics.reservedWidth(for: .timestamp),
            Metrics.reservedWidth(for: .terminalIcon),
            Metrics.reservedWidth(for: .commandBadge),
        ]
        for w in widths {
            XCTAssertGreaterThanOrEqual(
                w, 24,
                "Slot width \(w) too small to fit widest timestamp text"
            )
        }
    }

    func testReservedWidthIsStableAcrossVariants() {
        // Stronger property: any pair of the three swappable variants
        // must share an identical reserved width. Drives anti-jitter.
        let variants: [Metrics.Variant] = [.timestamp, .terminalIcon, .commandBadge]
        let widths = Set(variants.map { Metrics.reservedWidth(for: $0) })
        XCTAssertEqual(widths.count, 1, "Variants must share one slot width: \(widths)")
    }

    func testApprovalIsExempt() {
        // Approval buttons wrap two action chips and are intentionally
        // wider — appears only during a permission prompt and the row
        // is supposed to grow then. We assert it CAN be wider than the
        // baseline slot, not that it must be equal.
        let approval = Metrics.reservedWidth(for: .approvalButtons)
        let baseline = Metrics.reservedWidth(for: .timestamp)
        XCTAssertGreaterThanOrEqual(approval, baseline)
    }
}
