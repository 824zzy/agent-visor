//
//  PillsStripWindow.swift
//  AgentVisor
//
//  A thin overlay that renders the menu-bar pill strip on the selected display.
//
//  The window ignores mouse events. A global monitor resolves clicks against the
//  layout that PillStripView rendered, then routes the selected session to its
//  owning app or to Agent Visor Chat.
//

import AppKit
import Combine
import SwiftUI

class PillsStripPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        hasShadow = false
        isMovable = false

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle
        ]

        // Same level as the main notch window so z-order is predictable.
        level = .mainMenu + 3

        // CRITICAL: never accept mouse events directly — clicks pass
        // through to the menu bar (or whatever app owns the area) and
        // a global `EventMonitor` in `PillStripView.handleSideClick` catches
        // hits on session pills. Mirrors the closed-state main window.
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // A separate menu-bar status item provides the strip's accessibility
    // surface. This panel exists only as a render canvas, so opt out and let AX
    // probes targeting the menu bar do not enter the SwiftUI render hierarchy.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}

class PillsStripWindowController: NSWindowController {
    let viewModel: PillStripViewModel
    let sessionMonitor: SessionMonitor
    private let screen: NSScreen
    private var backingPropertiesObserver: Any?
    private var didChangeScreenObserver: Any?

    deinit {
        if let token = backingPropertiesObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = didChangeScreenObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    init(screen: NSScreen) {
        self.sessionMonitor = SessionMonitor()
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )
        // Window height is unused by the pills strip itself.
        self.viewModel = PillStripViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            visibleFrame: screen.visibleFrame,
            hasPhysicalNotch: screen.hasPhysicalNotch,
            displayID: screen.displayID
        )

        let notchHeight = notchSize.height

        // Strip covers the top notch-height of the screen, full width.
        // PillStripView's body positions content at the top with
        // `alignment: .top`, so it naturally fills this strip.
        let stripFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - notchHeight,
            width: screenFrame.width,
            height: notchHeight
        )

        let panel = PillsStripPanel(
            contentRect: stripFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        // This is the only PillStripView. Its onAppear starts session monitoring
        // and the global click monitor.
        let hostingController = NSHostingController(
            rootView: PillStripView(
                viewModel: viewModel,
                sessionMonitor: sessionMonitor
            )
        )
        // Disable SwiftUI → window size propagation; the strip frame is
        // fixed and SwiftUI shouldn't try to negotiate.
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = []
        }
        // Opt out of the screen-top safe-area inset. The strip window
        // sits across the menu-bar / hardware-notch region, which on
        // notched MacBooks reports `safeAreaInsets.top ≈ 32pt`. Without
        // this, SwiftUI insets the PillStripView's content downward by that
        // 32pt, so the rendered pill row visibly shifts.
        if #available(macOS 13.3, *) {
            hostingController.safeAreaRegions = []
        }
        panel.contentViewController = hostingController
        panel.setFrame(stripFrame, display: false)

        // Force a redraw when the window's backing scale or screen
        // changes (external-monitor reconfiguration, color profile
        // flip, sleep+wake of just the external display), AppKit
        // doesn't always re-rasterize the existing NSHostingController
        // layers at the new scale. The strip would then render blurry
        // until the user clicked anywhere. Walk + redraw on either
        // notification snaps it back deterministically. Walk is
        // idempotent so duplicate notifications cost nothing.
        backingPropertiesObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel = panel else { return }
            forceWindowRedisplay(panel)
        }
        didChangeScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            guard let panel = panel else { return }
            forceWindowRedisplay(panel)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Retire this controller for good.
    ///
    /// `WindowManager` rebuilds the strip whenever the pill display's identity
    /// or frame changes. Dropping the reference is not enough: the closed panel
    /// kept its `NSHostingController`, and therefore the SwiftUI view and the
    /// `PillStripViewModel`, alive for the rest of the process — so a superseded
    /// controller went on observing workspace events and answering click
    /// questions with geometry from the previous display arrangement.
    ///
    /// Clearing `contentViewController` unmounts the SwiftUI view, which runs
    /// its `onDisappear` teardown (global click monitors, menu-layout
    /// coordinator), then the view model drops its own subscriptions.
    ///
    /// The `SessionMonitor` this controller owns is intentionally left
    /// running: `stopMonitoring()` also stops process-wide singletons
    /// (`HookSocketServer`, `CodexMetadataWatcher`) that the replacement
    /// controller depends on. Session-monitor ownership needs its own change.
    func teardown() {
        if let token = backingPropertiesObserver {
            NotificationCenter.default.removeObserver(token)
            backingPropertiesObserver = nil
        }
        if let token = didChangeScreenObserver {
            NotificationCenter.default.removeObserver(token)
            didChangeScreenObserver = nil
        }
        window?.contentViewController = nil
        viewModel.teardown()
        window?.orderOut(nil)
        window?.close()
    }
}
