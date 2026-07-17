//
//  MainWindow.swift
//  AgentVisor
//
//  Standard resizable host for the Sessions browser.
//

import AppKit
import AgentVisorCore

final class MainWindow: NSWindow {
    /// First-launch and "small persisted frame" recovery size.
    private static let defaultSize = NSSize(width: 1040, height: 720)
    /// Floor for the auto-restored frame. Anything smaller is treated
    /// as a degenerate persisted size (e.g. a user dragged a corner
    /// down to minSize once and the autosave kept it forever) and is
    /// snapped back to `defaultSize`. Also enforced as the minSize so
    /// future drags can't reproduce that state.
    private static let minUsableSize = NSSize(width: 960, height: 640)

    init() {
        let initialFrame = NSRect(origin: .zero, size: Self.defaultSize)
        super.init(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = AppBranding.appName  // VoiceOver / window menu still see it
        minSize = Self.minUsableSize
        // AppKit caches the window's backing-layer bitmap during a
        // live resize and stretches/clips it instead of asking SwiftUI
        // to relayout every drag tick. Without this, NSWindow's
        // resize tracker fires `placeSubviews` at 60-120Hz, which
        // walks the LazyVStack and recurses through hundreds of
        // realized rows via `UnaryLayoutEngine.sizeThatFits` —
        // sample-confirmed 100% CPU / 1.3 GB RSS pin during a 5s
        // drag (2026-05-30). Setting this also matches what every
        // native macOS app (Finder, Mail, Safari) does — the snapshot
        // looks slightly stretched at the resize edge during the
        // drag, but the chat content never goes blank, and SwiftUI
        // does ONE final layout pass at the released size.
        preservesContentDuringLiveResize = true
        // Closing the window must NOT release it — pills strip stays
        // up as the persistent surface and reopening the window
        // (Cmd-N / Dock click) needs a live controller to call
        // `show()` on. Without this, AppKit deallocates the window
        // and the next show() segfaults.
        isReleasedWhenClosed = false
        // Codex / Cursor / Claude Desktop all hide the app name in
        // their titlebar — the Dock icon already says which app it
        // is, and the selected sidebar row already labels the
        // session. Showing "Agent Visor" is redundant.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        // System-managed frame persistence. Restores frame across
        // launches without our own UserDefaults code.
        setFrameAutosaveName(MainWindowSettings.frameAutosaveName)
        // Recovery: if the persisted frame is smaller than the new
        // minUsableSize floor (most likely because an earlier build
        // had minSize = 720x480 and the user dragged the window down
        // to that minimum once), snap back to defaultSize so users
        // who installed a previous version don't see a tiny window
        // forever. Also covers true first-launch (frame == initial).
        let restored = frame
        let needsResize = restored.size.width < Self.minUsableSize.width
            || restored.size.height < Self.minUsableSize.height
        if restored == initialFrame || needsResize {
            setContentSize(Self.defaultSize)
            center()
        }
    }
}
