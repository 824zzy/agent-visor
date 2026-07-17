//
//  NotchGeometry.swift
//  AgentVisor
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    /// Region of `screenRect` not occupied by the menu bar / dock —
    /// canonical AppKit answer for "where can a window draw without
    /// covering chrome." Used to floor `maxOpenedSize` so the user can
    /// resize the panel all the way to the dock (or to the bottom of
    /// the screen when the dock is hidden / auto-hidden) instead of
    /// stopping at a hard-coded buffer.
    let visibleFrame: CGRect
    let windowHeight: CGFloat

    /// The notch rect in screen coordinates (for hit testing with global mouse position)
    var notchScreenRect: CGRect {
        CGRect(
            x: screenRect.midX - deviceNotchRect.width / 2,
            y: screenRect.maxY - deviceNotchRect.height,
            width: deviceNotchRect.width,
            height: deviceNotchRect.height
        )
    }

    /// Top edge of the opened panel in screen coords. Anchored to
    /// `visibleFrame.maxY` (just below the menu bar) so the panel
    /// never covers Apple/File menus or status icons. Used to be
    /// `screenRect.maxY` but that made the menu bar unreachable
    /// while the panel was open — especially painful on external
    /// monitors where the simulated notch click handle is also covered.
    var openedPanelTopY: CGFloat { visibleFrame.maxY }

    /// The opened panel rect in screen coordinates for a given size
    func openedScreenRect(for size: CGSize) -> CGRect {
        // Match the actual rendered panel size (tuned to match visual output)
        let width = size.width - 6
        let height = size.height - 30
        return CGRect(
            x: screenRect.midX - width / 2,
            y: openedPanelTopY - height,
            width: width,
            height: height
        )
    }

    /// Check if a point is in the notch area (with padding for easier interaction)
    func isPointInNotch(_ point: CGPoint) -> Bool {
        let visibleMenuHeight = max(0, screenRect.maxY - visibleFrame.maxY)
        let stripHeight = min(max(max(visibleMenuHeight, deviceNotchRect.height), 1), 80)
        guard point.y >= screenRect.maxY - stripHeight,
              point.y <= screenRect.maxY else {
            return false
        }
        return notchScreenRect.insetBy(dx: -10, dy: 0).contains(point)
    }

    /// Check if a point is in the opened panel area
    func isPointInOpenedPanel(_ point: CGPoint, size: CGSize) -> Bool {
        openedScreenRect(for: size).contains(point)
    }

    /// Check if a point is outside the opened panel (for closing)
    /// Uses extra padding to avoid closing on edge clicks
    func isPointOutsidePanel(_ point: CGPoint, size: CGSize) -> Bool {
        let rect = openedScreenRect(for: size)
        let padded = rect.insetBy(dx: -20, dy: -20)
        return !padded.contains(point)
    }
}
