import Foundation
import CoreGraphics

/// Packs session pills across two pill bars (left of notch, right of notch)
/// while respecting each side's available width.
///
/// Pure logic. The caller is responsible for sorting candidates by priority
/// before packing, and for mapping the returned IDs back to renderable
/// session objects.
///
/// **Failure mode:** when both `leftMax` and `rightMax` are 0, the packer
/// returns an empty result and the caller renders nothing. This deliberately
/// breaks the "always show at least one pill" guarantee from the single-bar
/// design — overlapping system menus or tray icons is a worse experience
/// than briefly hiding pills until an AX probe succeeds.
public struct PillBarPacker {
    public struct Candidate: Equatable {
        public let id: String
        public let pillWidth: CGFloat
        /// Optional smaller width that the packer may try when full-width
        /// labels would hide sessions. The packer shortens lower-priority
        /// suffixes first, preserving higher-priority labels when possible.
        /// When `nil`, this candidate is never shortened.
        public let minimumWidth: CGFloat?

        public init(id: String, pillWidth: CGFloat, minimumWidth: CGFloat? = nil) {
            self.id = id
            self.pillWidth = pillWidth
            self.minimumWidth = minimumWidth
        }
    }

    public enum OverflowSide: Equatable {
        case left
        case right
    }

    public struct PackResult: Equatable {
        public let leftVisibleIds: [String]
        public let rightVisibleIds: [String]
        public let hiddenIds: [String]
        public var hiddenCount: Int { hiddenIds.count }
        /// Only meaningful when `hiddenCount > 0`. Defaults to `.right` when
        /// no overflow pill renders.
        public let overflowSide: OverflowSide
        /// IDs the packer placed using their `minimumWidth` instead of the
        /// default `pillWidth`. The caller is expected to render these with
        /// a shorter label so the visual width matches.
        public let shortenedIds: Set<String>
    }

    public static func pack(
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        // First pass: pack at standard widths.
        let initial = packStrict(
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
        )

        if initial.hiddenCount > 0,
           let compressed = bestCompressedPack(
            initial: initial,
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
           ) {
            return compressed
        }

        // No-empty-side rebalance. When the left bar ended up empty AND
        // sessions overflowed, try shrinking the highest-priority candidate
        // (index 0) to its `minimumWidth` and re-pack. Adopt only if the
        // retry actually puts something on the left — that's the symptom
        // we're trying to fix.
        if initial.leftVisibleIds.isEmpty,
           initial.hiddenCount > 0,
           let first = candidates.first,
           let minWidth = first.minimumWidth,
           minWidth <= leftMax
        {
            var modified = candidates
            modified[0] = Candidate(id: first.id, pillWidth: minWidth, minimumWidth: nil)
            let retried = packStrict(
                candidates: modified,
                leftMax: leftMax,
                rightMax: rightMax,
                pillSpacing: pillSpacing,
                overflowPillWidthFor: overflowPillWidthFor
            )
            if !retried.leftVisibleIds.isEmpty {
                return balanced(
                    retried,
                    candidates: candidates,
                    shortenedIds: [first.id],
                    leftMax: leftMax,
                    rightMax: rightMax,
                    pillSpacing: pillSpacing,
                    overflowPillWidthFor: overflowPillWidthFor
                )
            }
        }

        return balanced(
            initial,
            candidates: candidates,
            shortenedIds: [],
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
        )
    }

    private static func bestCompressedPack(
        initial: PackResult,
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult? {
        guard !candidates.isEmpty else { return nil }

        var best: (result: PackResult, shortenedIds: Set<String>)?

        for start in stride(from: candidates.count - 1, through: 0, by: -1) {
            var modified = candidates
            var shortenedIds = Set<String>()

            for index in start..<candidates.count {
                let candidate = candidates[index]
                guard let minimumWidth = candidate.minimumWidth,
                      minimumWidth < candidate.pillWidth else {
                    continue
                }
                modified[index] = Candidate(
                    id: candidate.id,
                    pillWidth: minimumWidth,
                    minimumWidth: nil
                )
                shortenedIds.insert(candidate.id)
            }

            guard !shortenedIds.isEmpty else { continue }

            let result = packStrict(
                candidates: modified,
                leftMax: leftMax,
                rightMax: rightMax,
                pillSpacing: pillSpacing,
                overflowPillWidthFor: overflowPillWidthFor
            )

            let improvesHiddenCount = result.hiddenCount < initial.hiddenCount
            let fixesEmptyLeft = initial.leftVisibleIds.isEmpty && !result.leftVisibleIds.isEmpty
            guard improvesHiddenCount || fixesEmptyLeft else { continue }

            if let currentBest = best {
                if result.hiddenCount < currentBest.result.hiddenCount ||
                    (result.hiddenCount == currentBest.result.hiddenCount &&
                     shortenedIds.count < currentBest.shortenedIds.count) {
                    best = (result, shortenedIds)
                }
            } else {
                best = (result, shortenedIds)
            }
        }

        guard let best else { return nil }
        return balanced(
            best.result,
            candidates: candidates,
            shortenedIds: best.shortenedIds,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
        )
    }

    /// Re-split the already-chosen visible set into a width-balanced
    /// contiguous partition so the pills flank the notch on both sides
    /// instead of all clustering on the left. The visible set, hidden
    /// count, and overflow side are preserved exactly — only WHICH side
    /// each visible pill lands on changes. Reading order is kept
    /// (left bar = higher-priority prefix, right bar = the rest), so the
    /// row still reads left-to-right across the notch.
    private static func balanced(
        _ result: PackResult,
        candidates: [Candidate],
        shortenedIds: Set<String>,
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        let visible = result.leftVisibleIds + result.rightVisibleIds
        guard !visible.isEmpty else { return result }

        // Rendered width per visible id (shortened ids render narrower).
        var widthByID: [String: CGFloat] = [:]
        for c in candidates { widthByID[c.id] = c.pillWidth }
        for id in shortenedIds {
            if let c = candidates.first(where: { $0.id == id }), let mw = c.minimumWidth {
                widthByID[id] = mw
            }
        }

        let hasOverflow = result.hiddenCount > 0
        let overflowWidth = hasOverflow ? overflowPillWidthFor(result.hiddenCount) : 0

        func barWidth(_ ids: ArraySlice<String>, withOverflow: Bool) -> CGFloat {
            var w: CGFloat = 0
            var first = true
            for id in ids {
                w += (first ? 0 : pillSpacing) + (widthByID[id] ?? 0)
                first = false
            }
            if withOverflow {
                w += (ids.isEmpty ? 0 : pillSpacing) + overflowWidth
            }
            return w
        }

        // Search split points high→low so that on a width tie the bigger
        // left bar wins (a lone pill stays on the left, matching the
        // single-bar intuition). Pick the feasible split with the
        // smallest left/right width imbalance.
        var best: (k: Int, imbalance: CGFloat)?
        for k in stride(from: visible.count, through: 0, by: -1) {
            let left = visible[0..<k]
            let right = visible[k...]
            let lw = barWidth(left, withOverflow: hasOverflow && result.overflowSide == .left)
            let rw = barWidth(right, withOverflow: hasOverflow && result.overflowSide == .right)
            guard lw <= leftMax, rw <= rightMax else { continue }
            let imbalance = abs(lw - rw)
            if best == nil || imbalance < best!.imbalance {
                best = (k, imbalance)
            }
        }

        // The original split is always feasible, so `best` is non-nil; the
        // fallback just preserves the input if that ever changes.
        guard let split = best else { return result }
        return PackResult(
            leftVisibleIds: Array(visible[0..<split.k]),
            rightVisibleIds: Array(visible[split.k...]),
            hiddenIds: result.hiddenIds,
            overflowSide: result.overflowSide,
            shortenedIds: shortenedIds
        )
    }

    /// Greedy left-then-right pass with no rebalancing. Internal — the public
    /// `pack` wraps this with a no-empty-side retry.
    private static func packStrict(
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        // Decide which side the +N overflow pill will live on. If the right
        // bar can fit at least the overflow pill itself, default to .right
        // (puts +N at the natural reading-end of the row). Otherwise +N
        // falls back to the end of the left bar.
        let overflowSide: OverflowSide =
            rightMax >= overflowPillWidthFor(1) ? .right : .left

        var left: [String] = []
        var leftUsed: CGFloat = 0
        var i = 0
        while i < candidates.count {
            let c = candidates[i]
            let spacing: CGFloat = left.isEmpty ? 0 : pillSpacing
            let remainingAfter = candidates.count - i - 1
            let overflowReserve: CGFloat
            if overflowSide == .left && remainingAfter > 0 {
                overflowReserve = pillSpacing + overflowPillWidthFor(remainingAfter)
            } else {
                overflowReserve = 0
            }
            if leftUsed + spacing + c.pillWidth + overflowReserve <= leftMax {
                leftUsed += spacing + c.pillWidth
                left.append(c.id)
                i += 1
            } else {
                break
            }
        }

        var right: [String] = []
        var rightUsed: CGFloat = 0
        while i < candidates.count {
            let c = candidates[i]
            let spacing: CGFloat = right.isEmpty ? 0 : pillSpacing
            let remainingAfter = candidates.count - i - 1
            let overflowReserve: CGFloat
            if overflowSide == .right && remainingAfter > 0 {
                overflowReserve = pillSpacing + overflowPillWidthFor(remainingAfter)
            } else {
                overflowReserve = 0
            }
            if rightUsed + spacing + c.pillWidth + overflowReserve <= rightMax {
                rightUsed += spacing + c.pillWidth
                right.append(c.id)
                i += 1
            } else {
                break
            }
        }

        let hiddenIds = candidates[i...].map(\.id)

        return PackResult(
            leftVisibleIds: left,
            rightVisibleIds: right,
            hiddenIds: hiddenIds,
            overflowSide: overflowSide,
            shortenedIds: []
        )
    }
}
