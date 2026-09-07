import Foundation
import CoreGraphics

/// Keeps interaction targets steady, then moves identified pills within safe menu-bar lanes.
public struct NativeMenuLayoutTransition {
    public struct Placement: Equatable {
        public let contentFrame: CGRect
        public let clippingFrame: CGRect
        public var frame: CGRect { contentFrame.intersection(clippingFrame) }
    }

    public struct Presentation {
        public let placements: [NativeMenuPanelTarget: Placement]
        /// Front to back, shared by native window stacking and fallback click routing.
        public let orderedTargets: [NativeMenuPanelTarget]
        public let overlappingTargets: Set<NativeMenuPanelTarget>
        public let isMoving: Bool
        public let nextUpdateDelay: TimeInterval?
        public var frames: [NativeMenuPanelTarget: CGRect] { placements.mapValues(\.frame) }
    }

    public static let settleDelay: TimeInterval = 0.12
    public static let slideDuration: TimeInterval = 0.24

    private struct Motion {
        var start: [NativeMenuPanelTarget: Placement]
        var end: [NativeMenuPanelTarget: Placement]
        let startedAt: TimeInterval
    }

    private var positions: [NativeMenuPanelTarget: Placement] = [:]
    private var initialized = false
    private var pointerEngaged = false
    private var idleSince: TimeInterval?
    private var motion: Motion?
    private var foregroundTarget: NativeMenuPanelTarget?

    public init() {}

    public mutating func update(
        proposedFrames: [NativeMenuPanelTarget: CGRect],
        availableTargets: Set<NativeMenuPanelTarget>,
        safeAreas: [CGRect],
        pointer: CGPoint?,
        mouseDown: Bool,
        shortcutsHeld: Bool,
        popoverOpen: Bool,
        reduceMotion: Bool,
        preferredTarget: NativeMenuPanelTarget? = nil,
        now: TimeInterval
    ) -> Presentation {
        positions = positions.filter { availableTargets.contains($0.key) }
        if var motion {
            motion.start = motion.start.filter { availableTargets.contains($0.key) }
            motion.end = motion.end.filter { availableTargets.contains($0.key) }
            self.motion = motion
        }
        var proposed: [NativeMenuPanelTarget: Placement] = [:]
        for (target, frame) in proposedFrames where availableTargets.contains(target) {
            if let area = safeAreas.first(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(frame) }) {
                proposed[target] = Placement(contentFrame: frame, clippingFrame: area)
            }
        }
        // A smaller lane can invalidate the remaining path even if today's frame still fits.
        let safe = [positions, motion?.end ?? [:]].allSatisfy { layout in
            layout.values.allSatisfy { placement in
                safeAreas.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(placement.clippingFrame) }
            }
        }
        if !initialized || !safe {
            initialized = true
            positions = proposed
            resetMotion()
            foregroundTarget = nil
        }

        let inside = pointer.map { point in
            safeAreas.contains { area in
                let visible = positions.values.map(\.frame).filter {
                    !$0.isNull && $0.width > 0 && area.insetBy(dx: -0.5, dy: -0.5).contains($0)
                }
                let strip = visible.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
                return strip?.insetBy(dx: -4, dy: -4).contains(point) == true
            }
        } ?? false
        pointerEngaged = inside || (mouseDown && pointerEngaged)
        if pointerEngaged || shortcutsHeld || popoverOpen {
            // Pause at the last displayed frames, including the foreground stacking order.
            resetMotion()
            return presentation(next: matches(proposed) ? nil : 0.05)
        }

        if let motion {
            if reduceMotion {
                positions = proposed
                resetMotion()
                foregroundTarget = nil
                return presentation()
            }
            let progress = min(1, max(0, (now - motion.startedAt) / Self.slideDuration))
            if progress < 1 - 0.000_001 {
                positions = interpolate(motion, progress: progress)
                return presentation(next: 1.0 / 60)
            }
            positions = motion.end
            resetMotion()
        }

        guard !matches(proposed) else {
            resetMotion()
            foregroundTarget = nil
            return presentation()
        }
        if idleSince == nil { idleSince = now }
        let remaining = Self.settleDelay - (now - (idleSince ?? now))
        if remaining > 0.000_001 { return presentation(next: remaining) }
        if reduceMotion || positions.isEmpty {
            positions = proposed
            resetMotion()
            foregroundTarget = nil
            return presentation()
        }
        let moving = Set(positions.keys).union(proposed.keys).filter {
            positions[$0]?.contentFrame != proposed[$0]?.contentFrame
        }
        foregroundTarget = preferredTarget.flatMap { moving.contains($0) ? $0 : nil }
            ?? moving.sorted {
                let lhs = travel($0, to: proposed), rhs = travel($1, to: proposed)
                return lhs == rhs ? key($0) < key($1) : lhs > rhs
            }.first
        motion = Motion(start: positions, end: proposed, startedAt: now)
        return presentation(next: 1.0 / 60)
    }

    private func matches(_ proposed: [NativeMenuPanelTarget: Placement]) -> Bool {
        positions.mapValues(\.contentFrame) == proposed.mapValues(\.contentFrame)
    }

    private func travel(_ target: NativeMenuPanelTarget, to end: [NativeMenuPanelTarget: Placement]) -> CGFloat {
        guard let a = positions[target], let b = end[target] else { return 10_000 }
        return abs(a.contentFrame.midX - b.contentFrame.midX)
    }

    private func interpolate(_ motion: Motion, progress: Double) -> [NativeMenuPanelTarget: Placement] {
        var result: [NativeMenuPanelTarget: Placement] = [:]
        for target in Set(motion.start.keys).union(motion.end.keys) {
            let start = motion.start[target], end = motion.end[target]
            switch (start, end) {
            case let (start?, end?) where start.clippingFrame.intersects(end.clippingFrame):
                result[target] = Placement(
                    contentFrame: lerp(start.contentFrame, end.contentFrame, progress),
                    clippingFrame: start.clippingFrame.union(end.clippingFrame)
                )
            case let (start?, end?):
                // Exit one lane, then enter the other. Never interpolate through the notch.
                let movingRight = end.clippingFrame.midX > start.clippingFrame.midX
                if progress < 0.5 {
                    result[target] = Placement(
                        contentFrame: lerp(start.contentFrame, outside(start, right: movingRight), progress * 2),
                        clippingFrame: start.clippingFrame
                    )
                } else {
                    result[target] = Placement(
                        contentFrame: lerp(outside(end, right: !movingRight), end.contentFrame, progress * 2 - 1),
                        clippingFrame: end.clippingFrame
                    )
                }
            case let (start?, nil):
                result[target] = Placement(
                    contentFrame: lerp(start.contentFrame, outside(start, right: true), progress),
                    clippingFrame: start.clippingFrame
                )
            case let (nil, end?):
                result[target] = Placement(
                    contentFrame: lerp(outside(end, right: true), end.contentFrame, progress),
                    clippingFrame: end.clippingFrame
                )
            default: break
            }
        }
        return result
    }

    private func outside(_ placement: Placement, right: Bool) -> CGRect {
        CGRect(x: right ? placement.clippingFrame.maxX : placement.clippingFrame.minX - placement.contentFrame.width,
               y: placement.contentFrame.minY, width: placement.contentFrame.width, height: placement.contentFrame.height)
    }

    private func lerp(_ a: CGRect, _ b: CGRect, _ progress: Double) -> CGRect {
        let t = progress * progress * (3 - 2 * progress)
        return CGRect(x: a.minX + (b.minX - a.minX) * t,
                      y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t,
                      height: a.height + (b.height - a.height) * t)
    }

    private func presentation(next: TimeInterval? = nil) -> Presentation {
        let visible = positions.filter { !$0.value.frame.isNull && $0.value.frame.width > 0.5 }
        let ordered = visible.keys.sorted { lhs, rhs in
            if lhs == foregroundTarget { return rhs != foregroundTarget }
            if rhs == foregroundTarget { return false }
            let x = visible[lhs]!.frame.minX, y = visible[rhs]!.frame.minX
            return x == y ? key(lhs) < key(rhs) : x < y
        }
        var overlaps = Set<NativeMenuPanelTarget>()
        for (index, target) in ordered.enumerated() {
            for other in ordered.dropFirst(index + 1) where visible[target]!.frame.intersects(visible[other]!.frame) {
                overlaps.insert(target)
                overlaps.insert(other)
            }
        }
        return Presentation(placements: visible, orderedTargets: ordered, overlappingTargets: overlaps,
                            isMoving: motion != nil, nextUpdateDelay: next)
    }

    private func key(_ target: NativeMenuPanelTarget) -> String {
        switch target {
        case .session(let id): return "session:" + id
        case .usage(let id): return "usage:" + id
        case .overflow: return "overflow"
        case .none: return "none"
        }
    }

    private mutating func resetMotion() {
        idleSince = nil
        motion = nil
    }
}
