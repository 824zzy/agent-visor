import Foundation
import CoreGraphics

/// Owns physical targets during interaction; semantic status and priority stay live.
public struct NativeMenuLayoutTransition {
    public struct Presentation {
        public let frames: [NativeMenuPanelTarget: CGRect]
        public let opacity: Double
        public let nextUpdateDelay: TimeInterval?
    }

    public static let settleDelay: TimeInterval = 0.12
    public static let fadeDuration: TimeInterval = 0.18

    private var frames: [NativeMenuPanelTarget: CGRect] = [:]
    private var initialized = false
    private var pointerEngaged = false
    private var idleSince: TimeInterval?
    private var fadeStartedAt: TimeInterval?
    private var destination: [NativeMenuPanelTarget: CGRect]?
    private var handedOff = false

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
        now: TimeInterval
    ) -> Presentation {
        frames = frames.filter { availableTargets.contains($0.key) }
        destination = destination?.filter { availableTargets.contains($0.key) }
        let proposed = proposedFrames.filter { availableTargets.contains($0.key) }
        let geometryIsSafe = [frames, destination ?? [:]].allSatisfy { layout in
            layout.values.allSatisfy { frame in
                safeAreas.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(frame) }
            }
        }
        if !initialized || !geometryIsSafe {
            initialized = true
            frames = proposed
            resetTransition()
        }

        // Include gaps within each lane, but never bridge the physical notch.
        let inside = pointer.map { point in
            safeAreas.contains { area in
                let laneFrames = frames.values.filter { area.insetBy(dx: -0.5, dy: -0.5).contains($0) }
                let strip = laneFrames.reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
                return strip?.insetBy(dx: -4, dy: -4).contains(point) == true
            }
        } ?? false
        pointerEngaged = inside || (mouseDown && pointerEngaged)
        if pointerEngaged || shortcutsHeld || popoverOpen {
            resetTransition()
            return presentation(next: frames == proposed ? nil : 0.05)
        }

        if let startedAt = fadeStartedAt, let destination {
            if reduceMotion {
                frames = proposed
                resetTransition()
                return presentation()
            }
            let progress = min(1, max(0, (now - startedAt) / Self.fadeDuration))
            if progress < 0.5 - 0.000_001 {
                // Coalesce late snapshots until the invisible handoff point.
                self.destination = proposed
                return presentation(opacity: 1 - 2 * progress, next: 1.0 / 60)
            }
            if !handedOff {
                frames = destination
                handedOff = true
                // Timers need not land exactly on the midpoint. Always relocate at zero opacity.
                return presentation(opacity: 0, next: 1.0 / 60)
            }
            if progress < 1 {
                return presentation(opacity: max(0, 2 * progress - 1), next: 1.0 / 60)
            }
            resetTransition()
        }

        guard frames != proposed else {
            resetTransition()
            return presentation()
        }
        if idleSince == nil { idleSince = now }
        let remaining = Self.settleDelay - (now - (idleSince ?? now))
        if remaining > 0.000_001 {
            return presentation(next: remaining)
        }
        if reduceMotion || frames.isEmpty || proposed.isEmpty {
            frames = proposed
            resetTransition()
            return presentation()
        }
        fadeStartedAt = now
        destination = proposed
        return presentation(next: 1.0 / 60)
    }

    private func presentation(opacity: Double = 1, next: TimeInterval? = nil) -> Presentation {
        Presentation(frames: frames, opacity: opacity, nextUpdateDelay: next)
    }

    private mutating func resetTransition() {
        idleSince = nil
        fadeStartedAt = nil
        destination = nil
        handedOff = false
    }
}
