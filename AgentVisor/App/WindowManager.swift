//
//  WindowManager.swift
//  AgentVisor
//
//  Manages the notch window lifecycle
//

import AppKit
import AgentVisorCore
import Combine
import os.log

/// Logger for window management
private let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Window")

class WindowManager {
    private var pillsEnabledCancellable: AnyCancellable?

    /// The menu-bar pills strip — always-visible thin overlay covering
    /// the menu-bar strip on the notch screen, hosting `NotchView` so
    /// the user keeps seeing session pills. Owns the live
    /// `ClaudeSessionMonitor`. The legacy notch chat panel was retired
    /// in favor of the main window.
    private(set) var pillsStripController: PillsStripWindowController?

    /// Track the screen identity + frame the current controller was built
    /// against so we can short-circuit rebuilds when nothing actually
    /// changed. `didChangeScreenParameters` and `didWake` fire for many
    /// benign reasons (HDR toggles, brightness changes, color profile
    /// shifts, wake-from-sleep where nothing structural moved). Each
    /// rebuild was destroying the panel and re-instantiating NotchView,
    /// which restarts `sessionMonitor` and re-runs probeMenuBarAsync —
    /// seconds of work and a visible wipe of the user's in-progress
    /// gesture.
    private var lastDisplayID: CGDirectDisplayID?
    private var lastScreenFrame: NSRect?

    /// Set up or recreate the menu-bar pills strip.
    @discardableResult
    func setupNotchWindow() -> PillsStripWindowController? {
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        guard let screen = screenSelector.selectedScreen else {
            logger.warning("No screen found")
            return nil
        }

        let newDisplayID = screen.displayID
        let newFrame = screen.frame
        if pillsStripController != nil,
           newDisplayID == lastDisplayID,
           newFrame == lastScreenFrame {
            return pillsStripController
        }

        if let existingStrip = pillsStripController {
            existingStrip.window?.orderOut(nil)
            existingStrip.window?.close()
            pillsStripController = nil
        }

        let strip = PillsStripWindowController(screen: screen)
        pillsStripController = strip
        if PillsEnabledSelector.shared.enabled {
            strip.showWindow(nil)
        }
        // Subscribe once: when the user toggles pills in Settings,
        // show or hide the strip window without tearing down the
        // controller (which owns the live ClaudeSessionMonitor that
        // AppDelegate keeps a strong reference to).
        if pillsEnabledCancellable == nil {
            pillsEnabledCancellable = PillsEnabledSelector.shared.$enabled
                .receive(on: DispatchQueue.main)
                .sink { [weak self] enabled in
                    guard let window = self?.pillsStripController?.window else { return }
                    if enabled {
                        window.orderFrontRegardless()
                    } else {
                        window.orderOut(nil)
                    }
                }
        }

        lastDisplayID = newDisplayID
        lastScreenFrame = newFrame

        return strip
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
