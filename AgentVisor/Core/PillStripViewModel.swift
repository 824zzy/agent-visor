//
//  PillStripViewModel.swift
//  AgentVisor
//
//  Display identity, geometry, and full-screen state for the menu-bar pill
//  strip. The model has no browser or Chat state.
//

import AppKit
import AgentVisorCore
import Combine
import OSLog
import SwiftUI

private let fsLogger = Logger(subsystem: AppBranding.loggerSubsystem, category: "FullScreenDetector")

@MainActor
class PillStripViewModel: ObservableObject {
    // MARK: - Published State

    /// True when a native full-screen window covers this screen. The view
    /// combines this evidence with the user's visibility policy and current
    /// reveal intent.
    @Published private(set) var isFullScreenAppActive: Bool = false

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let hotkeySelector = HotkeySelector.shared

    // MARK: - Geometry

    let geometry: NotchGeometry
    let hasPhysicalNotch: Bool

    /// Display this geometry was captured from. Click routing compares the
    /// captured `screenRect` against this display's live frame, so geometry
    /// left over from an earlier display arrangement can never claim a click
    /// (see `MenuBarGeometryFreshness`).
    let displayID: CGDirectDisplayID?

    /// True when the captured geometry no longer matches the display it came
    /// from — display detached, moved, or resized. Callers that resolve global
    /// clicks must ignore them while this is true; a rebuilt controller with
    /// fresh geometry takes over.
    var isGeometryStale: Bool {
        MenuBarGeometryFreshness.isStale(
            captured: geometry.screenRect,
            live: liveScreenFrame
        )
    }

    private var liveScreenFrame: CGRect? {
        guard let displayID else { return nil }
        return NSScreen.screens.first { $0.displayID == displayID }?.frame
    }

    var deviceNotchRect: CGRect { geometry.deviceNotchRect }
    var screenRect: CGRect { geometry.screenRect }

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(
        deviceNotchRect: CGRect,
        screenRect: CGRect,
        visibleFrame: CGRect,
        hasPhysicalNotch: Bool,
        displayID: CGDirectDisplayID?
    ) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
            visibleFrame: visibleFrame
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.displayID = displayID
        observeSelectors()
        observeFullScreenSignals()
        recomputeFullScreenState()
    }

    /// Stop every observation this model owns. Called by the owning window
    /// controller when it is replaced, so a superseded model cannot keep
    /// reacting to workspace events with geometry from an old display
    /// arrangement. Without this the replaced model stayed subscribed for the
    /// life of the process, because the closed strip window kept its hosting
    /// view — and its view model — alive.
    func teardown() {
        cancellables.removeAll()
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
            let result = FullScreenWindowDetector.ownerPID(intersecting: cgScreenRect)
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


}
