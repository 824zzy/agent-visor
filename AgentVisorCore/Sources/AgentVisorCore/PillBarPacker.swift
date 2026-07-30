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
        /// Optional intermediate and minimum widths for recognizable compact
        /// and tight labels. The packer first uses stronger tiers to improve
        /// visibility, then restores any independently affordable label detail.
        public let compactWidth: CGFloat?
        public let minimumWidth: CGFloat?

        public init(
            id: String,
            pillWidth: CGFloat,
            compactWidth: CGFloat? = nil,
            minimumWidth: CGFloat? = nil
        ) {
            self.id = id
            self.pillWidth = pillWidth
            self.compactWidth = compactWidth
            self.minimumWidth = minimumWidth
        }
    }

    public enum OverflowSide: Equatable {
        case left
        case right
    }

    public enum Density: Equatable {
        case standard
        case pressure
    }

    public enum LabelTier: Int, Equatable, Sendable {
        case full = 0
        case compact = 1
        case tight = 2
    }

    public struct PackingProfile: Equatable {
        public let density: Density
        public let pillSpacing: CGFloat
        public let widthReduction: CGFloat

        public init(
            density: Density,
            pillSpacing: CGFloat,
            widthReduction: CGFloat
        ) {
            self.density = density
            self.pillSpacing = max(0, pillSpacing)
            self.widthReduction = max(0, widthReduction)
        }
    }

    public struct PackResult: Equatable {
        public let leftVisibleIds: [String]
        public let rightVisibleIds: [String]
        public let hiddenIds: [String]
        public var hiddenCount: Int { hiddenIds.count }
        /// Only meaningful when `hiddenCount > 0`. Defaults to `.right` when
        /// no overflow pill renders.
        public let overflowSide: OverflowSide
        public let compactedIds: Set<String>
        public let minimizedIds: Set<String>
        public var shortenedIds: Set<String> { compactedIds.union(minimizedIds) }
        public let density: Density

        public func labelTier(for id: String) -> LabelTier {
            if minimizedIds.contains(id) { return .tight }
            if compactedIds.contains(id) { return .compact }
            return .full
        }

        init(
            leftVisibleIds: [String],
            rightVisibleIds: [String],
            hiddenIds: [String],
            overflowSide: OverflowSide,
            compactedIds: Set<String> = [],
            minimizedIds: Set<String> = [],
            density: Density = .standard
        ) {
            self.leftVisibleIds = leftVisibleIds
            self.rightVisibleIds = rightVisibleIds
            self.hiddenIds = hiddenIds
            self.overflowSide = overflowSide
            self.compactedIds = compactedIds
            self.minimizedIds = minimizedIds
            self.density = density
        }

        fileprivate func assigningDensity(_ density: Density) -> PackResult {
            PackResult(
                leftVisibleIds: leftVisibleIds,
                rightVisibleIds: rightVisibleIds,
                hiddenIds: hiddenIds,
                overflowSide: overflowSide,
                compactedIds: compactedIds,
                minimizedIds: minimizedIds,
                density: density
            )
        }
    }

    public static func pack(
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        standardProfile: PackingProfile,
        pressureProfile: PackingProfile,
        currentDensity: Density = .standard,
        releaseHeadroom: CGFloat = 8,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        let standard = pack(
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            profile: standardProfile,
            overflowPillWidthFor: overflowPillWidthFor
        )
        let pressure = pack(
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            profile: pressureProfile,
            overflowPillWidthFor: overflowPillWidthFor
        )
        if pressure.hiddenCount < standard.hiddenCount {
            return pressure
        }
        guard currentDensity == .pressure,
              pressure.hiddenCount == standard.hiddenCount else {
            return standard
        }

        let margin = max(0, releaseHeadroom)
        let standardWithHeadroom = pack(
            candidates: candidates,
            leftMax: max(0, leftMax - margin),
            rightMax: max(0, rightMax - margin),
            profile: standardProfile,
            overflowPillWidthFor: overflowPillWidthFor
        )
        return standardWithHeadroom.hiddenCount <= pressure.hiddenCount
            ? standard
            : pressure
    }

    private static func pack(
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        profile: PackingProfile,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        let adjusted = candidates.map { candidate in
            Candidate(
                id: candidate.id,
                pillWidth: max(0, candidate.pillWidth - profile.widthReduction),
                compactWidth: candidate.compactWidth.map {
                    max(0, $0 - profile.widthReduction)
                },
                minimumWidth: candidate.minimumWidth.map {
                    max(0, $0 - profile.widthReduction)
                }
            )
        }
        let result = pack(
            candidates: adjusted,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: profile.pillSpacing,
            overflowPillWidthFor: { count in
                max(0, overflowPillWidthFor(count) - profile.widthReduction)
            }
        )
        return result.assigningDensity(profile.density)
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

        let selected: PackResult
        if initial.hiddenCount > 0,
           let compressed = bestVariantPack(
            initial: initial,
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
           ) {
            selected = compressed
        } else {
            selected = balanced(
                initial,
                candidates: candidates,
                compactedIds: [],
                minimizedIds: [],
                leftMax: leftMax,
                rightMax: rightMax,
                pillSpacing: pillSpacing,
                overflowPillWidthFor: overflowPillWidthFor
            )
        }

        return restoringAffordableLabelDetail(
            in: selected,
            candidates: candidates,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
        )
    }

    private static func bestVariantPack(
        initial: PackResult,
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult? {
        guard !candidates.isEmpty else { return nil }

        typealias VariantResult = (
            result: PackResult,
            compactedIds: Set<String>,
            minimizedIds: Set<String>
        )
        var best: VariantResult?

        func tier(
            for id: String,
            compactedIds: Set<String>,
            minimizedIds: Set<String>
        ) -> LabelTier {
            if minimizedIds.contains(id) { return .tight }
            if compactedIds.contains(id) { return .compact }
            return .full
        }

        func isBetter(_ candidate: VariantResult, than current: VariantResult) -> Bool {
            if candidate.result.hiddenCount != current.result.hiddenCount {
                return candidate.result.hiddenCount < current.result.hiddenCount
            }

            let visibleIds = candidate.result.leftVisibleIds + candidate.result.rightVisibleIds
            for id in visibleIds {
                let candidateTier = tier(
                    for: id,
                    compactedIds: candidate.compactedIds,
                    minimizedIds: candidate.minimizedIds
                )
                let currentTier = tier(
                    for: id,
                    compactedIds: current.compactedIds,
                    minimizedIds: current.minimizedIds
                )
                if candidateTier != currentTier {
                    return candidateTier.rawValue < currentTier.rawValue
                }
            }

            let candidateSeverity = visibleIds.reduce(0) { severity, id in
                severity + tier(
                    for: id,
                    compactedIds: candidate.compactedIds,
                    minimizedIds: candidate.minimizedIds
                ).rawValue
            }
            let currentSeverity = visibleIds.reduce(0) { severity, id in
                severity + tier(
                    for: id,
                    compactedIds: current.compactedIds,
                    minimizedIds: current.minimizedIds
                ).rawValue
            }
            return candidateSeverity < currentSeverity
        }

        let count = candidates.count
        for compactStart in stride(from: count, through: 0, by: -1) {
            for tightStart in stride(from: count, through: compactStart, by: -1) {
                var modified = candidates
                var compactedIds = Set<String>()
                var minimizedIds = Set<String>()

                if compactStart < count {
                    for index in compactStart..<count {
                        let candidate = candidates[index]
                        let compactWidth = candidate.compactWidth.flatMap {
                            $0 < candidate.pillWidth ? $0 : nil
                        }
                        let tightWidth = candidate.minimumWidth.flatMap {
                            $0 < (compactWidth ?? candidate.pillWidth) ? $0 : nil
                        }

                        if index >= tightStart, let tightWidth {
                            modified[index] = Candidate(
                                id: candidate.id,
                                pillWidth: tightWidth
                            )
                            minimizedIds.insert(candidate.id)
                        } else if let compactWidth {
                            modified[index] = Candidate(
                                id: candidate.id,
                                pillWidth: compactWidth
                            )
                            compactedIds.insert(candidate.id)
                        }
                    }
                }

                guard !compactedIds.isEmpty || !minimizedIds.isEmpty else { continue }

                let result = packStrict(
                    candidates: modified,
                    leftMax: leftMax,
                    rightMax: rightMax,
                    pillSpacing: pillSpacing,
                    overflowPillWidthFor: overflowPillWidthFor
                )
                let improvesHiddenCount = result.hiddenCount < initial.hiddenCount
                let fixesEmptyLeft = initial.leftVisibleIds.isEmpty
                    && !result.leftVisibleIds.isEmpty
                guard improvesHiddenCount || fixesEmptyLeft else { continue }

                let visibleIds = Set(result.leftVisibleIds + result.rightVisibleIds)
                let candidate: VariantResult = (
                    result,
                    compactedIds.intersection(visibleIds),
                    minimizedIds.intersection(visibleIds)
                )
                if best == nil || isBetter(candidate, than: best!) {
                    best = candidate
                }
            }
        }

        guard let best else { return nil }
        return balanced(
            best.result,
            candidates: candidates,
            compactedIds: best.compactedIds,
            minimizedIds: best.minimizedIds,
            leftMax: leftMax,
            rightMax: rightMax,
            pillSpacing: pillSpacing,
            overflowPillWidthFor: overflowPillWidthFor
        )
    }

    /// Re-split the already-chosen visible set into a capacity-balanced
    /// contiguous partition. The visible set, hidden count, and overflow
    /// side are preserved exactly — only WHICH side each visible pill lands
    /// on changes. Reading order is kept (left bar = higher-priority prefix,
    /// right bar = the rest), so the row still reads left-to-right across
    /// the notch.
    private static func balanced(
        _ result: PackResult,
        candidates: [Candidate],
        compactedIds: Set<String>,
        minimizedIds: Set<String>,
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        let visible = result.leftVisibleIds + result.rightVisibleIds
        guard !visible.isEmpty else { return result }

        // Rendered width per visible id at the selected label tier.
        var widthByID: [String: CGFloat] = [:]
        for candidate in candidates { widthByID[candidate.id] = candidate.pillWidth }
        for id in compactedIds {
            if let candidate = candidates.first(where: { $0.id == id }),
               let compactWidth = candidate.compactWidth {
                widthByID[id] = compactWidth
            }
        }
        for id in minimizedIds {
            if let candidate = candidates.first(where: { $0.id == id }),
               let minimumWidth = candidate.minimumWidth {
                widthByID[id] = minimumWidth
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

        // Search split points high→low. Safe capacities are often highly
        // asymmetric after app menus and the right-side usage slot are
        // reserved, so equal rendered bar widths are the wrong objective.
        // Minimize the largest unused safe region first, then the difference
        // between residuals. A complete tie keeps the earlier (larger-left)
        // split because the loop descends from the highest k.
        var best: (k: Int, largestResidual: CGFloat, residualImbalance: CGFloat)?
        for k in stride(from: visible.count, through: 0, by: -1) {
            let left = visible[0..<k]
            let right = visible[k...]
            let lw = barWidth(left, withOverflow: hasOverflow && result.overflowSide == .left)
            let rw = barWidth(right, withOverflow: hasOverflow && result.overflowSide == .right)
            guard lw <= leftMax, rw <= rightMax else { continue }

            let leftResidual = max(0, leftMax - lw)
            let rightResidual = max(0, rightMax - rw)
            let largestResidual = max(leftResidual, rightResidual)
            let residualImbalance = abs(leftResidual - rightResidual)
            if best == nil
                || largestResidual < best!.largestResidual
                || (largestResidual == best!.largestResidual
                    && residualImbalance < best!.residualImbalance) {
                best = (k, largestResidual, residualImbalance)
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
            compactedIds: compactedIds,
            minimizedIds: minimizedIds
        )
    }

    /// Restores label detail without changing the selected visible prefix or
    /// side split. Candidates are visited in global priority order. If a
    /// higher-priority label cannot afford its next tier, its unused fragment
    /// remains available to any lower-priority label on the same side.
    private static func restoringAffordableLabelDetail(
        in result: PackResult,
        candidates: [Candidate],
        leftMax: CGFloat,
        rightMax: CGFloat,
        pillSpacing: CGFloat,
        overflowPillWidthFor: (Int) -> CGFloat
    ) -> PackResult {
        let visibleIds = result.leftVisibleIds + result.rightVisibleIds
        guard !visibleIds.isEmpty else { return result }

        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var tierByID = Dictionary(uniqueKeysWithValues: visibleIds.map {
            ($0, result.labelTier(for: $0))
        })

        func variants(for candidate: Candidate) -> [(tier: LabelTier, width: CGFloat)] {
            var variants: [(LabelTier, CGFloat)] = [(.full, candidate.pillWidth)]
            if let compactWidth = candidate.compactWidth,
               compactWidth < candidate.pillWidth {
                variants.append((.compact, compactWidth))
            }
            if let minimumWidth = candidate.minimumWidth,
               minimumWidth < variants.last!.1 {
                variants.append((.tight, minimumWidth))
            }
            return variants
        }

        var widthByID: [String: CGFloat] = [:]
        for id in visibleIds {
            guard let candidate = candidateByID[id],
                  let tier = tierByID[id],
                  let variant = variants(for: candidate).first(where: { $0.tier == tier }) else {
                continue
            }
            widthByID[id] = variant.width
        }

        let hasOverflow = result.hiddenCount > 0
        let overflowWidth = hasOverflow ? overflowPillWidthFor(result.hiddenCount) : 0
        func usedWidth(_ ids: [String], overflowSide: OverflowSide) -> CGFloat {
            var width: CGFloat = 0
            for (index, id) in ids.enumerated() {
                width += (index == 0 ? 0 : pillSpacing) + (widthByID[id] ?? 0)
            }
            if hasOverflow && result.overflowSide == overflowSide {
                width += (ids.isEmpty ? 0 : pillSpacing) + overflowWidth
            }
            return width
        }

        let leftIDs = Set(result.leftVisibleIds)
        var leftUsed = usedWidth(result.leftVisibleIds, overflowSide: .left)
        var rightUsed = usedWidth(result.rightVisibleIds, overflowSide: .right)

        for id in visibleIds {
            guard let candidate = candidateByID[id],
                  let currentTier = tierByID[id],
                  let currentWidth = widthByID[id] else {
                continue
            }
            let available = variants(for: candidate)
            guard let currentIndex = available.firstIndex(where: { $0.tier == currentTier }),
                  currentIndex > 0 else {
                continue
            }

            let isLeft = leftIDs.contains(id)
            let maximum = isLeft ? leftMax : rightMax
            let used = isLeft ? leftUsed : rightUsed
            for improved in available[..<currentIndex] {
                let delta = improved.width - currentWidth
                guard used + delta <= maximum else { continue }
                tierByID[id] = improved.tier
                widthByID[id] = improved.width
                if isLeft {
                    leftUsed += delta
                } else {
                    rightUsed += delta
                }
                break
            }
        }

        let compactedIds = Set(visibleIds.filter { tierByID[$0] == .compact })
        let minimizedIds = Set(visibleIds.filter { tierByID[$0] == .tight })
        return PackResult(
            leftVisibleIds: result.leftVisibleIds,
            rightVisibleIds: result.rightVisibleIds,
            hiddenIds: result.hiddenIds,
            overflowSide: result.overflowSide,
            compactedIds: compactedIds,
            minimizedIds: minimizedIds,
            density: result.density
        )
    }

    /// Greedy left-then-right pass with no rebalancing. Internal — the public
    /// `pack` wraps this with adaptive label variants and capacity balancing.
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
            compactedIds: [],
            minimizedIds: []
        )
    }
}
