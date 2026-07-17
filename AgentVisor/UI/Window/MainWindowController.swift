//
//  MainWindowController.swift
//  AgentVisor
//
//  Owns the keyboard-first Sessions browser window and its settings context.
//

import AppKit
import Combine
import SwiftUI

final class MainWindowController: NSWindowController {
    private var appearanceCancellable: AnyCancellable?
    private let viewModel: MainWindowViewModel

    convenience init() {
        let viewModel = MainWindowViewModel()
        let window = MainWindow()
        let savedFrame = window.frame
        let host = NSHostingController(rootView: MainSplitView(viewModel: viewModel))
        // Setting `contentViewController` re-sizes the window to the
        // hosting view's intrinsic content size. SwiftUI's
        // NavigationSplitView with an empty detail pane reports a
        // small ideal size (sidebar ideal=300 + nothing else), which
        // clobbers MainWindow's 1200×760 default down to ~960×640.
        // We restore the frame we just configured below.
        window.contentViewController = host
        window.setFrame(savedFrame, display: false)
        self.init(window: window, viewModel: viewModel)
        // Drive NSWindow.appearance off the same selector that drives
        // SwiftUI's preferredColorScheme. SwiftUI alone leaves the
        // titlebar / traffic-light / NSScroller chrome in the system
        // appearance, which produces the "dark frame around light
        // body" look when the user toggles Light Mode. Setting the
        // NSAppearance flips ALL native chrome together with the
        // Catppuccin token reads.
        applyAppearance(AppearanceSelector.shared.mode)
        // dropFirst: $mode emits the current value to new subscribers
        // immediately, which would re-apply the appearance we just
        // set above — harmless on its own, but `window.appearance =
        // ...` triggers a redisplay cascade that, on app launch, can
        // race with PillsStripWindowController's mount and leave the
        // pills strip in a state where its global EventMonitor never
        // attaches (sample-confirmed regression). Skip the initial
        // emission so we only re-apply on actual user changes.
        appearanceCancellable = AppearanceSelector.shared.$mode
            .dropFirst()
            .sink { [weak self] mode in
                self?.applyAppearance(mode)
            }
    }

    private init(window: NSWindow, viewModel: MainWindowViewModel) {
        self.viewModel = viewModel
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyAppearance(_ mode: AppearanceMode) {
        guard let window else { return }
        switch mode {
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        case .system:
            // nil = inherit from the app, which inherits from the OS.
            // The user wants the window to follow whatever the macOS
            // global setting is, including auto-switch.
            window.appearance = nil
        }
    }

    func show() {
        guard let window else { return }
        viewModel.refreshHistoricalSessions()
        // Always `makeKeyAndOrderFront`, even when the window is
        // already visible. Earlier this branched to
        // `orderFrontRegardless` when visible — that raised the
        // z-order but didn't promote the window to key status, so
        // `NSApp.activate` came back half-completed: the window
        // painted on top, but the app stayed in the background. The
        // user saw a visible window but their menu bar still
        // belonged to the previous app, traffic lights stayed gray,
        // and Cmd+N landed in nowhere. A second double-shift hit a
        // different code path (window became hidden via toggle, then
        // re-shown), which is why the second invocation "worked."
        // `makeKeyAndOrderFront` is idempotent and handles both
        // ordering and key-status promotion in a single call.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSessions() {
        viewModel.prepareForSessionBrowser()
        show()
    }

    func showSession(_ sessionId: String) {
        viewModel.selectSession(sessionId)
        show()
    }

    func showSettings() {
        viewModel.mode = .settings
        show()
    }

    func showUpdates() {
        viewModel.prepareForUpdateSettings()
        show()
    }

    /// Hotkey-friendly toggle: bring the window forward when hidden or
    /// not key, otherwise hide it. Replaces the legacy notch panel
    /// toggle so the global hotkey now drives the main window.
    func toggleSessions() {
        guard let window else { return }
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showSessions()
        }
    }
}
