//
//  NotchViewModel.swift
//  AgentVisor
//
//  State management for the dynamic island
//

import AppKit
import AgentVisorCore
import Combine
import OSLog
import SwiftUI

private let fsLogger = Logger(subsystem: AppBranding.loggerSubsystem, category: "FullScreenDetector")

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

extension NotchStatusInput {
    init(_ status: NotchStatus) {
        switch status {
        case .closed: self = .closed
        case .opened: self = .opened
        case .popping: self = .popping
        }
    }
}

enum NotchOpenReason {
    case click
    case notification
    case hotkey
    case unknown
}

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    var id: String {
        switch self {
        case .instances: return "instances"
        case .menu: return "menu"
        case .chat(let session): return "chat-\(session.sessionId)"
        }
    }
}

@MainActor
class NotchViewModel: ObservableObject {
    // MARK: - Published State

    @Published var status: NotchStatus = .closed
    @Published var openReason: NotchOpenReason = .unknown
    @Published var contentType: NotchContentType = .instances
    @Published var isHovering: Bool = false

    /// True when a native full-screen window covers this screen. The view
    /// combines this evidence with the user's visibility policy and current
    /// reveal intent.
    @Published private(set) var isFullScreenAppActive: Bool = false

    /// Drives the contentView's insertion/removal transition.
    /// Decoupled from `status` so that on close we can hide content
    /// (triggering its 0.25s removal transition) while keeping the panel
    /// frame at its open size, then collapse the frame after the
    /// transition finishes. Without this split, the frame snapped to
    /// the closed-notch size the instant `status` changed, clipping the
    /// inner removal animation into a tiny area and reading as a cliff.
    @Published private(set) var contentVisible: Bool = false

    /// Pending delayed status flip from a close. Tracked so an
    /// intervening open can cancel it (otherwise the delayed close
    /// would land after the user has already reopened).
    private var pendingCloseWork: DispatchWorkItem?

    /// The app that was frontmost before the notch opened (for restoring after message send)
    var appBeforeNotchOpened: NSRunningApplication?

    /// Provides the highest-priority session for auto-chat on pill click (set by NotchView)
    var prioritySessionProvider: (() -> SessionState?)?

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let hotkeySelector = HotkeySelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }
    var windowHeight: CGFloat { geometry.windowHeight }

    /// Bumped any time the user-overridden size changes for the current content type.
    /// Window controller observes this to push a new frame.
    @Published private(set) var sizeRevision: Int = 0

    /// Default size per content type before user override
    private var defaultOpenedSize: CGSize {
        switch contentType {
        case .chat:
            return CGSize(
                width: min(screenRect.width * 0.5, 600),
                height: 580
            )
        case .menu:
            // Bumped from 500 → 540 to accommodate the Light Mode
            // toggle row added next to the picker rows. Picker
            // expansions still add on top.
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 540
                    + screenSelector.expandedPickerHeight
                    + soundSelector.expandedPickerHeight
                    + hotkeySelector.expandedPickerHeight
            )
        case .instances:
            return CGSize(
                width: min(screenRect.width * 0.4, 480),
                height: 320
            )
        }
    }

    /// Final opened size: user override (clamped) if present, otherwise default
    var openedSize: CGSize {
        if let override = userSize(for: sizeStorageKey) {
            return clamp(size: override)
        }
        return defaultOpenedSize
    }

    /// Floor on the resizable panel size
    var minOpenedSize: CGSize {
        CGSize(width: 380, height: 360)
    }

    /// Ceiling on the resizable panel size, derived from screen bounds.
    /// Height is bounded by the distance from `geometry.openedPanelTopY`
    /// (where the panel now anchors — just below the menu bar) down to
    /// `visibleFrame.minY` (top of dock, or bottom of screen when dock
    /// is hidden) so the user can drag the panel all the way to the
    /// dock without overlapping it. Previously this used
    /// `screenRect.maxY` as the top anchor — when we moved the anchor
    /// down by `menuBarHeight` to keep the menu bar reachable, this
    /// ceiling stayed too tall by the same amount and pushed the
    /// panel's bottom (status bar) `menuBarHeight` past the dock,
    /// clipping the status bar off-screen.
    var maxOpenedSize: CGSize {
        let visibleFrame = geometry.visibleFrame
        let availableHeight = geometry.openedPanelTopY - visibleFrame.minY
        return CGSize(
            width: max(minOpenedSize.width, screenRect.width - 80),
            height: max(minOpenedSize.height, availableHeight)
        )
    }

    private func clamp(size: CGSize) -> CGSize {
        let lo = minOpenedSize
        let hi = maxOpenedSize
        return CGSize(
            width: max(lo.width, min(hi.width, size.width)),
            height: max(lo.height, min(hi.height, size.height))
        )
    }

    // MARK: - Size persistence

    private static let sizeDefaultsKeyPrefix = "notch.userSize."

    /// Stable storage key for the current content type. Nil if we don't persist this type.
    private var sizeStorageKey: String {
        switch contentType {
        case .chat: return "chat"
        case .menu: return "menu"
        case .instances: return "instances"
        }
    }

    private func defaultsKey(for storageKey: String) -> String {
        Self.sizeDefaultsKeyPrefix + storageKey
    }

    private func userSize(for storageKey: String) -> CGSize? {
        guard let arr = UserDefaults.standard.array(forKey: defaultsKey(for: storageKey)) as? [Double],
              arr.count == 2 else { return nil }
        return CGSize(width: arr[0], height: arr[1])
    }

    /// Persist a user-chosen size for the current content type. Clamps to min/max.
    func applyUserSize(_ size: CGSize) {
        let clamped = clamp(size: size)
        let key = defaultsKey(for: sizeStorageKey)
        UserDefaults.standard.set([Double(clamped.width), Double(clamped.height)], forKey: key)
        sizeRevision &+= 1
    }

    /// Drop the user override for the current content type, returning to default.
    func resetUserSize() {
        UserDefaults.standard.removeObject(forKey: defaultsKey(for: sizeStorageKey))
        sizeRevision &+= 1
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private let events = EventMonitors.shared

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, visibleFrame: CGRect, windowHeight: CGFloat, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            visibleFrame: visibleFrame,
            windowHeight: windowHeight
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        setupEventHandlers()
        observeSelectors()
        observeFullScreenSignals()
        recomputeFullScreenState()
    }

    // MARK: - Full-screen detection

    /// Serial queue for the AX scan so it never blocks the main thread
    /// during rapid Cmd-Tab activation storms.
    private let fullScreenScanQueue = DispatchQueue(
        label: AppBranding.loggerSubsystem + ".fullscreen-detect",
        qos: .userInitiated
    )

    /// Subscribe to the workspace signals that change full-screen state:
    /// active Space change (entering/leaving a full-screen Space), app
    /// activation (switching between full-screen apps), and launch/quit
    /// (a full-screen app exiting). All notifications funnel through a
    /// debounced recompute so a burst of app switches collapses to one
    /// AX scan.
    private func observeFullScreenSignals() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ]
        let merged = Publishers.MergeMany(names.map { center.publisher(for: $0) })
        merged
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeFullScreenState() }
            .store(in: &cancellables)
    }

    /// Find the topmost non-self app whose windows intersect this screen
    /// and check whether any of its windows reports `AXFullScreen == true`.
    /// CGWindow bounds heuristics can't reliably distinguish a window that
    /// was zoomed via the green button (covers `visibleFrame`) from one in
    /// macOS full-screen mode — both have nearly identical CG bounds on a
    /// notched MBP with a hidden dock. `AXFullScreen` is the canonical
    /// signal AppKit itself sets on `NSWindow.toggleFullScreen`. Requires
    /// Accessibility permission, which the app already holds for other
    /// features (Cursor send, Ghostty automation, etc.).
    private func recomputeFullScreenState() {
        let screenRect = geometry.screenRect
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenRect.height
        let cgScreenTop = primaryHeight - screenRect.origin.y - screenRect.height
        let cgScreenRect = CGRect(
            x: screenRect.origin.x, y: cgScreenTop,
            width: screenRect.width, height: screenRect.height
        )

        fullScreenScanQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Self.fullScreenOwnerPid(intersecting: cgScreenRect)
            DispatchQueue.main.async {
                let foundFullScreen = result != nil
                if self.isFullScreenAppActive != foundFullScreen {
                    let state = foundFullScreen ? "entered" : "exited"
                    let w = Int(screenRect.width)
                    let h = Int(screenRect.height)
                    fsLogger.info("full-screen \(state, privacy: .public) on \(w, privacy: .public)×\(h, privacy: .public)")
                    self.isFullScreenAppActive = foundFullScreen
                }
            }
        }
    }

    /// Walk running .regular apps via AX, find a window with `AXFullScreen`
    /// set whose frame intersects the target screen rect (CG coords).
    /// Returns the owning pid on first match, or nil if no full-screen
    /// window covers the screen. Skips our own pid. `nonisolated` so the
    /// scan can run on `fullScreenScanQueue` without bouncing through the
    /// main actor for AX work.
    nonisolated private static func fullScreenOwnerPid(intersecting cgScreenRect: CGRect) -> pid_t? {
        let myPid = getpid()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != myPid
        }
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            let listRC = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
            guard listRC == .success, let windows = windowsRef as? [AXUIElement] else { continue }
            for window in windows {
                var fsRef: CFTypeRef?
                let fsRC = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef)
                guard fsRC == .success, (fsRef as? Bool) == true else { continue }

                // Confirm the fullscreen window is on this screen.
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
                _ = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                var pos = CGPoint.zero
                var size = CGSize.zero
                if let posRef, CFGetTypeID(posRef) == AXValueGetTypeID() {
                    let p = unsafeBitCast(posRef, to: AXValue.self)
                    AXValueGetValue(p, .cgPoint, &pos)
                }
                if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
                    let s = unsafeBitCast(sizeRef, to: AXValue.self)
                    AXValueGetValue(s, .cgSize, &size)
                }
                let frame = CGRect(origin: pos, size: size)
                if cgScreenRect.intersects(frame) || frame == .zero {
                    // frame == .zero is rare but seen on apps that hand back
                    // garbage AX values for fullscreen windows; treat as
                    // "is fullscreen somewhere" and conservatively hide.
                    return app.processIdentifier
                }
            }
        }
        return nil
    }

    private func observeSelectors() {
        screenSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        soundSelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        hotkeySelector.$isPickerExpanded
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        events.mouseLocation
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] location in
                self?.handleMouseMove(location)
            }
            .store(in: &cancellables)

        events.mouseDown
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMouseDown()
            }
            .store(in: &cancellables)

    }

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = contentType { return true }
        return false
    }

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    private func handleMouseMove(_ location: CGPoint) {
        let inNotch = geometry.isPointInNotch(location)
        let inOpened = status == .opened && geometry.isPointInOpenedPanel(location, size: openedSize)

        let newHovering = inNotch || inOpened

        // Only update if changed to prevent unnecessary re-renders.
        // Hovering used to auto-expand the panel after 1s; that produced
        // accidental opens whenever the cursor brushed the pill on the way
        // to the menu bar. Click-to-open is the only entry point now.
        guard newHovering != isHovering else { return }
        isHovering = newHovering
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        // Test against the visible NotchShape, not the bounding rect.
        // The window frame is wider than the visible black panel because
        // NotchShape carves 19×19pt concave cutouts at the top corners
        // and 24pt rounded cutouts at the bottom. Without shape-accurate
        // testing, clicks in those transparent cutouts (visually outside
        // the border) are classified as inside and don't close.
        let action = NotchClickPolicy.action(
            status: NotchStatusInput(status),
            inNotch: geometry.isPointInNotch(location),
            inVisiblePanel: isPointInVisiblePanel(location)
        )

        switch action {
        case .open:
            // Notch chat panel was retired; clicking the visible notch
            // shape now hands off to the main window via the same
            // bridge the redirect callbacks installed by AppDelegate
            // use. Falling through to `notchOpen` would mount the
            // (intentionally empty) panel content view and pop a
            // blank container under the menu bar.
            NotchPanelRedirect.openMainWindow?()
        case .close:
            notchClose()
        case .ignore:
            break
        }
    }

    /// Whether `screenPoint` (Cocoa screen coords, origin bottom-left) lies
    /// inside the visible NotchShape of the opened panel. Used by both the
    /// click-outside-to-close check and the hit-test gate so SwiftUI never
    /// receives clicks in the transparent corner cutouts.
    func isPointInVisiblePanel(_ screenPoint: CGPoint) -> Bool {
        let size = openedSize
        let panelRect = CGRect(
            x: geometry.screenRect.midX - size.width / 2,
            y: geometry.openedPanelTopY - size.height,
            width: size.width,
            height: size.height
        )
        guard panelRect.contains(screenPoint) else { return false }

        // The opened panel is now clipped to a uniform RoundedRectangle
        // (matches `NotchView.panelCornerRadius`). Hit-test against a
        // BezierPath of the same rounded rect so clicks in the corner
        // cutouts pass through to the menu bar / app behind us instead
        // of being classified as inside-panel. Radius mirrors
        // `cornerRadiusInsets.opened.top` in NotchView.swift.
        let localX = screenPoint.x - panelRect.minX
        let localY = panelRect.maxY - screenPoint.y
        let openedRadius: CGFloat = 19
        let path = CGPath(
            roundedRect: CGRect(origin: .zero, size: size),
            cornerWidth: openedRadius,
            cornerHeight: openedRadius,
            transform: nil
        )
        return path.contains(CGPoint(x: localX, y: localY))
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Small delay to let the window's ignoresMouseEvents update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Actions

    func notchOpen(reason: NotchOpenReason = .unknown) {
        openReason = reason
        // Cancel any in-flight close so a fast close→open sequence
        // doesn't get its delayed `status = .closed` running after we've
        // re-opened.
        pendingCloseWork?.cancel()
        pendingCloseWork = nil
        // Save the current frontmost app before we activate AgentVisor.
        // Read this BEFORE the deferred status flip below so we capture the
        // app that was frontmost at gesture time, not at +50ms.
        if status == .closed {
            appBeforeNotchOpened = NSWorkspace.shared.frontmostApplication
        }
        // Flip contentVisible immediately. NotchView's .animation(_:value:)
        // modifier on the contentView drives the opacity/scale animation.
        // No withAnimation here — having two animation contexts (this and
        // the modifier) compete on the same property change is what
        // deadlocked the open animation for ~10s on external displays in
        // the prior always-mount attempt.
        contentVisible = true

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            currentChatSession = nil
            contentType = .instances
        } else if let chatSession = currentChatSession {
            // Restore chat session if we had one open before. Avoid
            // unnecessary updates if already showing this chat.
            if case .chat(let current) = contentType, current.sessionId != chatSession.sessionId {
                contentType = .chat(chatSession)
            } else if case .chat = contentType {
                // already on this chat, no-op
            } else {
                contentType = .chat(chatSession)
            }
        }
        // Otherwise: show instances list (the default contentType)

        // Defer the status flip so the contentView's animation transaction
        // commits before the window-resize sink in NotchWindowController
        // calls setFrame against the WindowServer. The synchronous flip +
        // resize race was a contributing factor to the prior deadlock.
        // 50ms is enough for SwiftUI to commit the contentVisible change
        // and start the animation; the window resize then lands cleanly
        // mid-animation without contention.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            self.status = .opened
        }
    }

    func notchClose() {
        // Save or clear chat session based on what's currently showing
        if case .chat(let session) = contentType {
            currentChatSession = session
        } else {
            currentChatSession = nil
        }
        // Don't reset contentType to .instances here. Closing from chat
        // would otherwise swap ChatView for ClaudeInstancesView mid-fade,
        // making the close animation visibly janky. Menu is transient by
        // design — reset that to instances so it doesn't persist across
        // close. Chat persists; the next open() restores it.
        if case .menu = contentType {
            contentType = .instances
        }
        pendingCloseWork?.cancel()
        // Synchronized close: a single 0.25s ambient animation drives the
        // frame size, corner radii, padding, and shadow toward their
        // closed values via NotchView's `contentVisible`-keyed properties.
        // The contentView's removal `.transition` has its own matched
        // 0.25s smooth curve so border and content collapse as one.
        withAnimation(.smooth(duration: 0.25)) {
            contentVisible = false
        }
        // Defer the logical `status` flip to .closed until after the
        // close animation finishes. Side content (left/right pills) is
        // gated on `status == .closed`, so flipping early would expose
        // pills next to a still-collapsing panel and overlap during the
        // animation. The window-resize sink also runs on `status`, so
        // deferring keeps the window at panel size during the visual
        // collapse and avoids reparenting cracks.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Confirm we're still meant to be closing; an open during the
            // window would have cancelled this work item via notchOpen.
            self.status = .closed
            self.pendingCloseWork = nil
        }
        pendingCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Open if closed, close if open. Used by the global hotkey so the
    /// same gesture both summons and dismisses the notch.
    func toggleViaHotkey() {
        switch status {
        case .opened:
            notchClose()
        case .closed, .popping:
            notchOpen(reason: .hotkey)
        }
    }

    func notchPop() {
        guard status == .closed else { return }
        status = .popping
    }

    func notchUnpop() {
        guard status == .popping else { return }
        status = .closed
    }

    func toggleMenu() {
        contentType = contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case .chat(let current) = contentType, current.sessionId == session.sessionId {
            return
        }
        contentType = .chat(session)
    }

    /// Go back to instances list and clear saved chat state.
    /// Wrap the contentType flip in a spring so the chat→instances swap
    /// animates the same way the hamburger menu's chat→menu swap does
    /// (NotchView.swift:1228 uses the same spring for toggleMenu). Without
    /// this, the back-button path is an instant snap while the menu
    /// button is a 300ms spring — visibly inconsistent.
    func exitChat() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            currentChatSession = nil
            contentType = .instances
        }
    }

}
