//
//  NotchGeometry.swift
//  AgentVisor
//
//  Geometry calculations for the notch
//

import CoreGraphics
import Foundation

/// Pure geometry calculations for the notch
///
/// This type describes *rendering* geometry only. It deliberately owns no
/// point-in-region tests: a geometry value captured for one display would
/// happily answer "yes, that point is mine" for a point that is physically on
/// another display, which is how an invisible click target ended up floating
/// in the middle of an external monitor. Global click routing lives in
/// `NotchView.handleSideClick`, which checks `MenuBarGeometryFreshness` first.
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

    /// Top edge of the opened panel in screen coords. Anchored to
    /// `visibleFrame.maxY` (just below the menu bar) so the panel
    /// never covers Apple/File menus or status icons.
    var openedPanelTopY: CGFloat { visibleFrame.maxY }
}
