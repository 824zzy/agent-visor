//
//  NotchPanelRedirect.swift
//  AgentVisor
//
//  Bridges legacy notch-panel "open" call sites (the click-on-notch
//  hit test inside `NotchViewModel.handleMouseDown`, etc.) to the new
//  main-window show path. The notch chat panel is retired but the
//  pills strip still ships a tap-to-open gesture against the visible
//  notch shape — this redirect keeps that gesture working without
//  letting the dead panel content view mount and pop a blank container
//  under the menu bar.
//
//  Lives outside the AppDelegate (and outside AgentVisorCore) so
//  NotchViewModel can call into it without dragging the AppDelegate
//  module dependency into Core.
//

import Foundation

enum NotchPanelRedirect {
    /// Installed by AppDelegate at launch. Synchronously dispatches to
    /// the main thread, so call sites can be on any thread.
    static var openMainWindow: (() -> Void)?
}
