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
        // Summon order matters on cooperative-activation macOS (14+,
        // and stricter on 26.x). A background app summoned from a
        // global hotkey while another app is frontmost is no longer
        // force-raised by `activate(ignoringOtherApps:)` alone —
        // `makeKeyAndOrderFront` orders the window into the z-stack,
        // but the app never activates, so the window never becomes
        // key and other apps' windows stay on top (the "visible but
        // covered" double-shift regression on macOS 26.5). Because
        // the window then stays non-key, `toggleSessions` kept taking
        // the re-show branch, so repeated double-taps never raised or
        // toggled it.
        //
        // Fix: activate the app first, promote the window to key with
        // the idempotent `makeKeyAndOrderFront`, then
        // `orderFrontRegardless` so the window rises above other
        // applications' windows even when full activation is deferred.
        // This uses `orderFrontRegardless` IN ADDITION TO — never
        // instead of — `makeKeyAndOrderFront`, so it does not
        // reintroduce the earlier "ordered on top but not key" bug.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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

    /// Bring the Sessions browser forward when hidden or not key. Hide it when
    /// the user invokes the toggle while it is already active.
    func toggleSessions() {
        guard let window else { return }
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            showSessions()
        }
    }
}
