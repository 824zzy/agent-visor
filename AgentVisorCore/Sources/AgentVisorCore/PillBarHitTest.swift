import CoreGraphics
import Foundation

/// Resolves which pill (if any) lives at a given screen-X coordinate
/// inside one of the two pill bars flanking the notch.
///
/// Why this exists: the previous side-click path went through SwiftUI by
/// synthesizing an `NSEvent.mouseEvent` and calling `window.sendEvent`.
/// That was unreliable when the click handler hit the 50 ms `usleep`
/// activation delay — sessions could re-sort during that window and the
/// synthetic click would land on the pill that *replaced* the one the
/// user actually clicked. Computing the hit deterministically from
/// screen coordinates eliminates the race.
public enum PillBarHitTest {
    /// One renderable pill's contribution to the layout.
    public struct PillSlot: Equatable, Sendable {
        public let id: String
        public let width: CGFloat

        public init(id: String, width: CGFloat) {
            self.id = id
            self.width = width
        }
    }

    /// Outcome of `resolve`.
    public enum Hit: Equatable, Sendable {
        /// Click landed on a session pill with the given id.
        case session(id: String)
        /// Click landed on the +N overflow pill.
        case overflow
        /// Click landed on the fixed Codex usage utility pill.
        case usage
        /// Click was inside the bar's bounding box but missed every pill
        /// (e.g. landed in the gap between pills, or in the trailing
        /// padding region). Caller can choose to ignore or open the panel.
        case empty
        /// Click was outside the bar's bounding box entirely.
        case outside
    }

    /// Side of the notch the bar lives on. Drives alignment within
    /// `barWidth` (left bar is right-aligned to its trailing edge; right
    /// bar is left-aligned to its leading edge).
    public enum Side: Equatable, Sendable {
        case left
        case right
    }

    /// Resolve a click against one bar's layout.
    ///
    /// - Parameters:
    ///   - clickX: Click X in screen coordinates (origin at the screen's
    ///     left edge).
    ///   - side: Which bar this layout is for.
    ///   - sessionPills: Pills in render order (highest priority first).
    ///     For a left bar these render right-aligned, so `sessionPills[0]`
    ///     visually sits closest to the notch. For a right bar they render
    ///     left-aligned, so `sessionPills[0]` sits closest to the notch.
    ///   - overflowWidth: Width of the +N pill if one is rendered on this
    ///     side, otherwise nil.
    ///   - pillSpacing: Spacing inserted between adjacent pills.
    ///   - barAnchorX: Screen X where the bar abuts the notch — i.e. the
    ///     left bar's *right* edge or the right bar's *left* edge. The
    ///     bar's pills extend away from this anchor.
    ///   - barWidth: Maximum width of the bar (matches `leftSafeWidth` /
    ///     `rightSafeWidth` from `NotchView`).
    public static func resolve(
        clickX: CGFloat,
        side: Side,
        sessionPills: [PillSlot],
        overflowWidth: CGFloat?,
        usageWidth: CGFloat? = nil,
        pillSpacing: CGFloat,
        barAnchorX: CGFloat,
        barWidth: CGFloat
    ) -> Hit {
        if sessionPills.isEmpty && overflowWidth == nil && usageWidth == nil {
            return .outside
        }

        // Build the visual order of slots, walking from the anchor
        // outward. For the left bar that's right-to-left; for the right
        // bar that's left-to-right.
        //
        // The +N overflow pill, when present, is the *outermost* slot —
        // it always sits at the far end of the row, away from the notch.
        // (Matches the `HStack` layout in `NotchPillBar`, which places
        // the overflow button after all session pills.)
        enum SlotTarget {
            case session(String)
            case overflow
            case usage
        }
        var slots: [(target: SlotTarget, width: CGFloat)] = sessionPills.map {
            (.session($0.id), $0.width)
        }
        if let overflowWidth {
            slots.append((.overflow, overflowWidth))
        }
        if let usageWidth {
            slots.append((.usage, usageWidth))
        }

        // Compute each slot's [start, end] in screen coordinates.
        // For left bar: walk leftward from anchor.
        //   slot[0].end = anchor; slot[0].start = anchor - width
        //   slot[1].end = slot[0].start - spacing; ...
        // For right bar: walk rightward from anchor.
        //   slot[0].start = anchor; slot[0].end = anchor + width
        //   slot[1].start = slot[0].end + spacing; ...
        var ranges: [(target: SlotTarget, start: CGFloat, end: CGFloat)] = []
        var cursor = barAnchorX
        for slot in slots {
            switch side {
            case .left:
                let end = cursor
                let start = end - slot.width
                ranges.append((slot.target, start, end))
                cursor = start - pillSpacing
            case .right:
                let start = cursor
                let end = start + slot.width
                ranges.append((slot.target, start, end))
                cursor = end + pillSpacing
            }
        }

        // Outer bar bounds (used to distinguish .empty from .outside):
        // the bar spans `barWidth` from the anchor outward.
        let barStart: CGFloat
        let barEnd: CGFloat
        switch side {
        case .left:
            barEnd = barAnchorX
            barStart = barAnchorX - barWidth
        case .right:
            barStart = barAnchorX
            barEnd = barAnchorX + barWidth
        }

        let inBarBounds = clickX >= barStart && clickX <= barEnd
        if !inBarBounds {
            return .outside
        }

        // First match wins. Ranges don't overlap by construction.
        for range in ranges where clickX >= range.start && clickX <= range.end {
            switch range.target {
            case .session(let id):
                return .session(id: id)
            case .overflow:
                return .overflow
            case .usage:
                return .usage
            }
        }

        return .empty
    }

    /// A frozen description of both pill bars at a single render frame.
    /// Captured by the view at body time and held by the click handler;
    /// `resolve(clickX:snapshot:)` is then a pure function of (clickX,
    /// snapshot) with no dependence on live state.
    ///
    /// Why this exists: see the off-by-one bug pinned by
    /// `PillBarHitTestTests.test_resolveAgainstSnapshot_renderedAndLiveDiverge`.
    /// Recomputing the pack inside the click handler reads
    /// `sessionMonitor.instances` which `lastActivity`-bumps re-sort
    /// dozens of times per second — so a click queued before SwiftUI's
    /// next layout pass landed on the pill that *replaced* the one the
    /// user saw.
    public struct PillBarSnapshot: Equatable, Sendable {
        public let leftSlots: [PillSlot]
        public let rightSlots: [PillSlot]
        public let leftOverflowWidth: CGFloat?
        public let rightOverflowWidth: CGFloat?
        public let leftUsageWidth: CGFloat?
        public let rightUsageWidth: CGFloat?
        public let leftAnchorX: CGFloat
        public let rightAnchorX: CGFloat
        public let leftBarWidth: CGFloat
        public let rightBarWidth: CGFloat
        public let pillSpacing: CGFloat
        public let minY: CGFloat?
        public let maxY: CGFloat?

        public init(
            leftSlots: [PillSlot],
            rightSlots: [PillSlot],
            leftOverflowWidth: CGFloat?,
            rightOverflowWidth: CGFloat?,
            leftUsageWidth: CGFloat? = nil,
            rightUsageWidth: CGFloat? = nil,
            leftAnchorX: CGFloat,
            rightAnchorX: CGFloat,
            leftBarWidth: CGFloat,
            rightBarWidth: CGFloat,
            pillSpacing: CGFloat,
            minY: CGFloat? = nil,
            maxY: CGFloat? = nil
        ) {
            self.leftSlots = leftSlots
            self.rightSlots = rightSlots
            self.leftOverflowWidth = leftOverflowWidth
            self.rightOverflowWidth = rightOverflowWidth
            self.leftUsageWidth = leftUsageWidth
            self.rightUsageWidth = rightUsageWidth
            self.leftAnchorX = leftAnchorX
            self.rightAnchorX = rightAnchorX
            self.leftBarWidth = leftBarWidth
            self.rightBarWidth = rightBarWidth
            self.pillSpacing = pillSpacing
            self.minY = minY
            self.maxY = maxY
        }
    }

    /// Resolve a click against a captured snapshot. Tries the left bar
    /// first, then the right; returns the first non-`.outside` hit. If
    /// both bars report `.outside`, returns `.outside`.
    ///
    /// This is the only correct shape for the click handler to call:
    /// any code that builds a snapshot inline at click time has
    /// reintroduced the live-state race this seam exists to prevent.
    public static func resolve(clickX: CGFloat, snapshot: PillBarSnapshot) -> Hit {
        let leftHit = resolve(
            clickX: clickX,
            side: .left,
            sessionPills: snapshot.leftSlots,
            overflowWidth: snapshot.leftOverflowWidth,
            usageWidth: snapshot.leftUsageWidth,
            pillSpacing: snapshot.pillSpacing,
            barAnchorX: snapshot.leftAnchorX,
            barWidth: snapshot.leftBarWidth
        )
        if leftHit != .outside {
            return leftHit
        }
        return resolve(
            clickX: clickX,
            side: .right,
            sessionPills: snapshot.rightSlots,
            overflowWidth: snapshot.rightOverflowWidth,
            usageWidth: snapshot.rightUsageWidth,
            pillSpacing: snapshot.pillSpacing,
            barAnchorX: snapshot.rightAnchorX,
            barWidth: snapshot.rightBarWidth
        )
    }

    public static func resolve(click: CGPoint, snapshot: PillBarSnapshot) -> Hit {
        if let minY = snapshot.minY, click.y < minY {
            return .outside
        }
        if let maxY = snapshot.maxY, click.y > maxY {
            return .outside
        }
        return resolve(clickX: click.x, snapshot: snapshot)
    }
}
