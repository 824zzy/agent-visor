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
/// `PillStripView.handleSideClick`, which checks `MenuBarGeometryFreshness` first.
struct NotchGeometry: Sendable {
    let deviceNotchRect: CGRect
    let screenRect: CGRect
    /// Region of `screenRect` not occupied by the menu bar / dock. The
    /// pills strip measures the menu-bar strip height from the gap
    /// between this and `screenRect`.
    let visibleFrame: CGRect
}
