//
//  PillsStripWindow.swift
//  AgentVisor
//
//  Thin always-visible window covering the menu-bar strip on the notch
//  screen. Hosts a `NotchView` in `.pillsOnlyOpenState` so the user
//  keeps seeing session pills while the panel is open and inset below
//  the menu bar.
//
//  Why a separate window: the primary `NotchWindow` shrinks to the
//  panel rect when opened (`ignoresMouseEvents = false` for panel
//  interaction), so it no longer covers the menu-bar strip. The first
//  attempt at restoring strip pills tried to extend the primary
//  window upward, but `level = .mainMenu+3 + ignoresMouseEvents=false`
//  re-triggered the historical "top-half freeze" — the window swallowed
//  every click in the menu-bar area. A dedicated `ignoresMouseEvents=true`
//  window dodges that entirely; pill clicks are caught the same way the
//  closed-state pills already are (global `EventMonitor` →
//  `PillBarHitTest.resolve` → direct navigation).
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
        // a global `EventMonitor` in `NotchView.handleSideClick` catches
        // hits on session pills. Mirrors the closed-state main window.
        ignoresMouseEvents = true

        isReleasedWhenClosed = true
        acceptsMouseMovedEvents = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The notch view's accessibility surface lives in the main panel.
    // The strip panel exists only as a render canvas — opt out so AX
    // probes targeting the menu bar don't deadlock against our SwiftUI
    // hierarchy (same reasoning as `NotchPanel`).
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}

class PillsStripWindowController: NSWindowController {
    let viewModel: NotchViewModel
    let sessionMonitor: ClaudeSessionMonitor
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
        self.sessionMonitor = ClaudeSessionMonitor()
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height
        )
        // Window height is unused by the pills strip itself but the
        // viewModel's geometry helpers expect a non-zero panel height.
        // The legacy NotchWindowController used 750; we keep the same
        // value so geometry math stays identical for the pills layout.
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            visibleFrame: screen.visibleFrame,
            windowHeight: 750,
            hasPhysicalNotch: screen.hasPhysicalNotch
        )

        let notchHeight = notchSize.height

        // Strip covers the top notch-height of the screen, full width.
        // NotchView's body positions content at the top with
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

        // `.pillsOnlyOpenState` is the lighter mode: it renders pills
        // and skips the panel layout (`notchLayout` / `contentView`)
        // entirely. With the chat panel retired, the heavier `.full`
        // mode pulled in expensive menu-owner and tray scans on every
        // body re-render — pinning CPU at
        // 20-100% during streaming. Switching to the lighter variant
        // is correct because the panel never opens and the only role
        // left is "render the pills row in the menu-bar strip."
        // Bootstrap (sessionMonitor.startMonitoring + click monitor +
        // prioritySessionProvider) was previously gated on `.full`;
        // it now runs unconditionally inside `NotchView.onAppear`.
        let hostingController = NSHostingController(
            rootView: NotchView(
                viewModel: viewModel,
                displayMode: .pillsOnlyOpenState,
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
        // this, SwiftUI insets the pillsOnlyOpenState NotchView's
        // content downward by that 32pt, so each open/close cycle
        // visibly shifts the rendered pill row vs. mainWindow's pills
        // (which already opt out via NotchViewController's hosting
        // setup). Matches the equivalent line on the main hosting view.
        if #available(macOS 13.3, *) {
            hostingController.safeAreaRegions = []
        }
        panel.contentViewController = hostingController
        panel.setFrame(stripFrame, display: false)

        // Mirror the protection NotchViewController installs on the
        // main panel: when the window's backingScaleFactor or screen
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
}
