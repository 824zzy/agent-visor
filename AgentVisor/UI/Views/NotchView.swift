//
//  NotchView.swift
//  AgentVisor
//
//  The main dynamic island SwiftUI view with accurate notch shape
//

import AppKit
import AgentVisorCore
import Combine
import CoreGraphics
import SwiftUI
import os.log

#if DEBUG
private let pillRaceLog = Logger(subsystem: AppBranding.loggerSubsystem, category: "PillRace")
#endif

private final class PillMenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

enum SessionOpenRouter {
    static func smartOpen(
        _ session: SessionState,
        modifierIntent: PillClickModifierIntent = .standard
    ) {
        let action = PillClickNavigationPolicy.action(
            ownership: ownership(for: session),
            modifierIntent: modifierIntent
        )
        switch action {
        case .openAgentVisor:
            openAgentVisor(session)
        case .openOriginal:
            openOriginal(session)
        }
    }

    static func openAgentVisor(_ session: SessionState) {
        AppDelegate.shared?.openSessionInMainWindow(session.sessionId)
    }

    static func openOriginal(_ session: SessionState) {
        SessionNavigator.navigateToSession(session)
    }

    static func ownership(for session: SessionState) -> AgentControlSessionOwnership {
        switch session.origin {
        case .codexAppServer, .visorSpawned:
            return .agentVisorAppServer
        case .terminal:
            return .terminal(host: session.terminalHost)
        case .cursorObserved:
            return .ownerApp(host: session.terminalHost ?? .cursor)
        case .observed:
            if session.agentID == .codex {
                return .ownerApp(host: codexOwnerHost(for: session))
            }
            return .opaqueHost(host: session.terminalHost)
        }
    }

    private static func codexOwnerHost(for session: SessionState) -> TerminalHost? {
        switch session.terminalHost {
        case .codexApp, .unknown, .none:
            return .codexApp
        default:
            return session.terminalHost
        }
    }
}

// Corner radius constants
private let cornerRadiusInsets = (
    opened: (top: CGFloat(19), bottom: CGFloat(24)),
    closed: (top: CGFloat(6), bottom: CGFloat(14))
)

/// Which slice of the notch UI a `NotchView` instance renders.
///
/// - `.full`: the standard composition — closed-state pills + center
///   notch shape that animates open into the full panel content. Used
///   by the primary `NotchWindow`.
/// - `.pillsOnlyOpenState`: pills only, and ONLY while the panel is
///   opened. Used by the parallel `PillsStripWindow` so the user keeps
///   seeing session pills in the menu-bar strip while the (now-inset)
///   panel hangs below the menu bar. The mainWindow already shows
///   pills when closed, so this gate keeps them mutually exclusive
///   and avoids double-rendering.


/// Holds the most recently rendered pill-bar snapshot for the click
/// handler to read. Reference type so writes from inside `body` don't
/// trigger SwiftUI re-renders (we'd loop forever); both NotchView
/// instances (`.full` for closed-state pills, `.pillsOnlyOpenState`
/// for opened-state strip pills) write into the SAME shared instance.
/// The click monitor only runs in `.full`, but it needs to resolve
/// against whichever instance most recently rendered — sharing one
/// store closes that gap.
///
/// The contract: `handleSideClick` MUST read from here and never
/// rebuild the snapshot from `sessionMonitor.instances`. See
/// `PillBarHitTestTests.test_resolveAgainstSnapshot_renderedAndLiveDiverge`
/// for the regression this guards: live-state re-sorts on
/// `lastActivity` bumps in the milliseconds between render and click,
/// so a snapshot recomputed at click time disagrees with what the
/// user saw and the click resolves to the wrong pill.
/// Shared "which pill should flash right now" channel. Set by
/// `dispatchHit` when a pill click resolves; observed by the
/// pill views to drive their press-flash animation. Lives outside
/// the pill view so it survives the view's identity churn during
/// session re-sorts (a SwiftUI `@State` inside the view would be
/// blown away when ForEach decides to re-key the row).
///
/// Reference type + singleton: there's exactly one click stream
/// across the closed `.full` window and the opened
/// `.pillsOnlyOpenState` strip, and both windows' pill views need
/// to observe the same flash signal. Using one shared store
/// guarantees that the flash, the snapshot read, and the
/// navigation dispatch are all keyed off the same click —
/// no path can fire without the others. That's the structural
/// invariant that prevents the regression where one of the
/// three was silently disconnected.
final class PillFlashStore: ObservableObject {
    static let shared = PillFlashStore()
    /// `nil` when nothing is flashing; otherwise the stableId of the
    /// pill mid-flash, OR `Self.overflowSentinel` for the +N pill.
    @Published var flashingId: String?
    static let overflowSentinel = "__overflow__"
    static let usageSentinel = "__usage__"

    /// Trigger a flash on the given id, automatically clearing it
    /// after the press-flash duration. Idempotent across rapid
    /// re-clicks: a new flash on the same id resets the timer.
    func flash(_ id: String, duration: TimeInterval = 0.25) {
        flashingId = id
        let snapshotId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            // Only clear if we're still flashing the same id — a
            // newer click on a different pill must take precedence
            // and not be cleared by an older timer firing late.
            if self?.flashingId == snapshotId {
                self?.flashingId = nil
            }
        }
    }
}

final class PillBarSnapshotStore {
    static let shared = PillBarSnapshotStore()
    var snapshot: PillBarHitTest.PillBarSnapshot?
    var leftPills: [VisiblePill] = []
    var rightPills: [VisiblePill] = []
    var overflowSnapshot: SidebarSessionListSnapshot?
    var navigatorSnapshot: SidebarSessionListSnapshot?
    var density: PillBarPacker.Density = .standard
    var pillsInReadingOrder: [VisiblePill] { leftPills + rightPills }
    /// Diagnostic-only: actual rendered pill frames in `.global`
    /// (screen) coordinates, captured via `PillFramesPreferenceKey`.
    /// Used by `handleSideClick` to log math-width vs SwiftUI-width
    /// for root-cause confirmation. NOT read by the click resolver.
    var renderedFrames: [PillFrameReport] = []
}

@MainActor
final class TransientPopoverWindowTracker: ObservableObject {
    enum Kind {
        case overflow
        case usage
    }

    private weak var overflowWindow: NSWindow?
    private weak var usageWindow: NSWindow?

    func setWindow(_ window: NSWindow?, for kind: Kind) {
        switch kind {
        case .overflow:
            overflowWindow = window
        case .usage:
            usageWindow = window
        }
    }

    func contains(eventWindow: NSWindow?, screenPoint: NSPoint) -> Bool {
        let eventWindowMatches = eventWindow.map {
            $0 === overflowWindow || $0 === usageWindow
        } ?? false
        let visiblePopoverFrames = [overflowWindow, usageWindow].compactMap { window -> CGRect? in
            guard let window, window.isVisible else { return nil }
            return window.frame
        }
        return TransientPopoverHitRegionPolicy.isInside(
            eventWindowMatches: eventWindowMatches,
            screenPoint: screenPoint,
            visiblePopoverFrames: visiblePopoverFrames
        )
    }
}

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    /// Shared session monitor. The pills strip is the only instance in
    /// the app, and it needs the SAME `instances` array
    /// at click time — otherwise a one-tick lag between the two
    /// `@StateObject` instances' subscriber callbacks could let
    /// `handleSideClick`'s pack diverge from the visually rendered
    /// pills, reintroducing a "click pill A, navigate to B" race.
    /// Sharing one monitor closes that gap.
    @ObservedObject var sessionMonitor: ClaudeSessionMonitor
    @StateObject private var activityCoordinator = NotchActivityCoordinator.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var navigationRecencyStore = SessionNavigationRecencyStore.shared
    @ObservedObject private var codexUsageMonitor = CodexUsageMonitor.shared
    @ObservedObject private var claudeUsageMonitor = ClaudeUsageMonitor.shared
    @ObservedObject private var fullScreenPolicy = FullScreenPolicySelector.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @StateObject private var menuLayoutCoordinator = NotchMenuLayoutCoordinator()
    @StateObject private var transientPopoverWindowTracker = TransientPopoverWindowTracker()
    /// Observed so a flavor flip re-evaluates this view's body and cascades
    /// new ChatTheme tokens into every descendant.
    @ObservedObject private var appearance = AppearanceSelector.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var readyEpisodeTracker = ReadySessionEpisodeTracker()
    @State private var waitingForInputTimestamps: [String: Date] = [:]  // sessionId -> when it entered waitingForInput
    @State private var isVisible: Bool = true
    @State private var isHovering: Bool = false
    @State private var isBouncing: Bool = false
    @State private var sideClickMonitor: EventMonitor?
    @State private var fullScreenPointerMonitor: EventMonitor?
    @State private var fullScreenPointerHideWorkItem: DispatchWorkItem?
    @State private var fullScreenShortcutHideWorkItem: DispatchWorkItem?
    @State private var isFullScreenPointerRevealActive = false
    @State private var isFullScreenShortcutRevealActive = false
    @State private var transientPopoverKeyMonitor: EventMonitor?
    @State private var showSessionNavigatorPopover = false
    @State private var frozenOverflowSnapshot: SidebarSessionListSnapshot?
    @State private var frozenNavigatorSnapshot: SidebarSessionListSnapshot?
    @State private var showCodexUsagePopover = false
    /// Backing store for the rendered pill snapshot. Shared singleton
    /// so both NotchView instances (closed `.full` + opened
    /// `.pillsOnlyOpenState`) write into the same place; only `.full`
    /// has the click monitor, and it always reads the most-recent
    /// render. See `PillBarSnapshotStore` doc.
    private let pillSnapshotStore = PillBarSnapshotStore.shared
    private let hoverContextMenuCoordinator = PillHoverContextMenuCoordinator.shared
    /// Bumped when menu-bar apps launch or quit so the right-side tray
    /// boundary is recalculated.
    @State private var menuBarVersion: Int = 0
    /// Drives periodic re-probe of the menu bar. Activation events
    /// trigger the immediate + retry-burst probe path; this timer is
    /// the safety net for changes that don't fire any activation —
    /// title-driven menu mutation, Spaces switch, display reconfig,
    /// and the moment AX TCC permission flips on after a CDHash
    /// change. 1.4s caps the worst-case overlap window for those
    /// no-activation cases without burning meaningful CPU on
    /// `CGWindowListCopyWindowInfo` and AX round-trips.
    // Re-measures the owner app's live menu-title edge. App *switches* are
    // caught immediately by the activation handler + its 0.1/0.4/1.0s retry
    // burst; this periodic probe is the only path that catches a *same-app*
    // menu-width change (e.g. opening an Outlook compose/event window adds
    // menus, widening past the cached edge). 0.5s bounds that transient
    // instead of the previous 1.4s, so the left pills re-contract before the
    // overlap is noticeable. Probe only runs while pills are rendered (see
    // the guarded onReceive), so the added cost is negligible.
    private let menuProbeTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    @Namespace private var activityNamespace

    /// Whether any Claude session is currently processing or compacting
    private var isAnyProcessing: Bool {
        sessionMonitor.instances.contains { $0.phase == .processing || $0.phase == .compacting }
    }

    /// Whether any Claude session has a pending permission request
    private var hasPendingPermission: Bool {
        sessionMonitor.instances.contains { $0.phase.isWaitingForApproval }
    }

    /// Whether any Claude session is waiting for user input (done/ready state) within the display window
    private var hasWaitingForInput: Bool {
        let now = Date()
        let displayDuration: TimeInterval = 30  // Show checkmark for 30 seconds

        return sessionMonitor.instances.contains { session in
            guard session.phase == .waitingForInput else { return false }
            // Only show if within the 30-second display window
            if let enteredAt = waitingForInputTimestamps[session.sessionId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            // On a display without a physical notch there is no synthetic
            // notch, so the center reserves zero width and the left/right
            // pill groups consolidate at center instead of straddling an
            // empty gap. The height still tracks the menu-bar strip so the
            // interaction band and pill row keep their vertical extent.
            width: viewModel.hasPhysicalNotch ? viewModel.deviceNotchRect.width : 0,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities
    /// When closed: no expansion (side content uses all available space)
    private var expansionWidth: CGFloat {
        0
    }

    /// Outer size for the visual notch shape. The panel is gone, so this
    /// is always the closed size.
    private var notchSize: CGSize {
        closedNotchSize
    }

    private var menuBarInteractionHeight: CGFloat {
        let visibleMenuHeight = max(0, viewModel.screenRect.maxY - viewModel.geometry.visibleFrame.maxY)
        let stripHeight = max(visibleMenuHeight, closedNotchSize.height)
        return min(max(stripHeight, 1), 80)
    }

    private var menuBarInteractionYRange: ClosedRange<CGFloat> {
        let maxY = viewModel.screenRect.height
        return (maxY - menuBarInteractionHeight)...maxY
    }

    /// Width of the closed content (notch + any expansion)
    private var closedContentWidth: CGFloat {
        closedNotchSize.width + expansionWidth
    }

    // MARK: - Corner Radii

    private var topCornerRadius: CGFloat {
        cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        cornerRadiusInsets.closed.bottom
    }

    /// Corner radius for the panel's rounded-rect clip. Single value
    /// for all four corners — replaces the old `NotchShape` which
    /// carved concave (notch-hugging) curves into the top corners.
    /// On external displays those concave curves were vestigial and
    /// read as "wrong" against the chrome row; on a real notched
    /// MacBook they only look right when the closed pill is flush
    /// against the hardware notch, which is a niche read. Standard
    /// rounded corners look right everywhere.
    private var panelCornerRadius: CGFloat {
        cornerRadiusInsets.closed.bottom
    }

    private var currentNotchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
    }

    // Animation springs
    private let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
    private let closeAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)

    // MARK: - Body

    /// Left edge of the hardware notch (x coordinate)
    private var notchLeftEdge: CGFloat {
        viewModel.deviceNotchRect.origin.x
    }

    /// Right edge of the hardware notch (x coordinate)
    private var notchRightEdge: CGFloat {
        viewModel.deviceNotchRect.origin.x + viewModel.deviceNotchRect.width
    }

    /// Half of the fixed gap that separates each pill group from the notch
    /// center. On a physical notch this holds the pills 4px off the
    /// hardware cutout; without a notch there is nothing to clear, so the
    /// groups meet at center and the seam is governed purely by
    /// `seamEdgePadding` below (kept at the normal pill spacing).
    private var notchCenterGap: CGFloat {
        viewModel.hasPhysicalNotch ? 4 : 0
    }

    /// Left edge of the actual pill (accounts for expansion beyond hardware notch)
    private var pillLeftEdge: CGFloat {
        let totalPillWidth = closedNotchSize.width + expansionWidth
        return (viewModel.screenRect.width - totalPillWidth) / 2 - notchCenterGap
    }

    /// Right edge of the actual pill (accounts for expansion beyond hardware notch)
    private var pillRightEdge: CGFloat {
        let totalPillWidth = closedNotchSize.width + expansionWidth
        return (viewModel.screenRect.width + totalPillWidth) / 2 + notchCenterGap
    }

    /// Inner padding between each pill group and the notch center. On a
    /// physical notch this keeps pills `edgePadding` off the cutout. Without
    /// a notch the two groups form one contiguous strip, so the padding
    /// shrinks to half the pill spacing and the center seam matches the gap
    /// between any other two pills instead of leaving a notch-sized hole.
    private func seamEdgePadding(pillSpacing: CGFloat) -> CGFloat {
        viewModel.hasPhysicalNotch ? PillBarCoordinator.edgePadding : pillSpacing / 2
    }

    /// Safe width for left side content (avoids app menus).
    ///
    /// The coordinator binds every measurement and cache entry to the current
    /// target-screen menu owner. Periodic probes also refresh that owner when
    /// a window crosses displays without causing a new app activation. Unknown
    /// ownership keeps the last reliable boundary rather than guessing.
    private var leftSafeWidth: CGFloat {
        menuLayoutCoordinator.safeWidth(available: pillLeftEdge)
    }

    /// Safe width for the right-side pill bar. The coordinator keeps the
    /// latest reliable tray boundary for this display, so one incomplete
    /// WindowServer snapshot cannot collapse every pill onto the left.
    /// More room applies immediately; less room must remain stable briefly
    /// before the pill bar contracts around newly added status items.
    private var rightSafeWidth: CGFloat {
        menuLayoutCoordinator.statusTraySafeWidth(availableFrom: pillRightEdge)
    }

    /// Whether this view instance owns a current pill layout. Full-screen
    /// hiding deliberately does not participate here: hidden layouts keep
    /// refreshing so direct 1-9 and 0 shortcuts retain a current snapshot.
    /// With the notch chat panel retired, the panel never opens
    /// (`status` stays `.closed` for the full process lifetime), so
    /// `.pillsOnlyOpenState` — which historically gated on
    /// `status != .closed` — now needs to render unconditionally.
    /// `.full` keeps its original "show pills while closed" semantics.
    private var hasPillContent: Bool {
        !sessionMonitor.instances.isEmpty || codexUsageMonitor.showsPill || claudeUsageMonitor.showsPill
    }

    private var codexUsagePresentation: CodexUsageMenuBarPresentation? {
        guard codexUsageMonitor.showsPill, let snapshot = codexUsageMonitor.snapshot else {
            return nil
        }
        return CodexUsageGlancePolicy.menuBarPresentation(for: snapshot)
    }

    private var pillsAreVisible: Bool {
        FullScreenPillVisibilityPolicy.isVisible(
            isFullScreenActive: viewModel.isFullScreenAppActive,
            policy: fullScreenPolicy.policy,
            pointerRevealActive: isFullScreenPointerRevealActive,
            shortcutRevealActive: isFullScreenShortcutRevealActive,
            popoverPresented: showSessionNavigatorPopover || showCodexUsagePopover
        )
    }

    /// Whether to render the small black notch shape between the left
    /// and right pill groups. This is drawn only on a display that has a
    /// physical notch, where it sits behind the hardware cutout and reads
    /// as the natural home for the pills. On displays without a physical
    /// notch (external monitors) Agent Visor shows no synthetic notch at
    /// all — the pills consolidate at center and the session browser is
    /// reached through the menu-bar status item, the Dock, or the global
    /// hotkey. The shape is decorative in every case: it does not hit-test,
    /// and no global click monitor turns menu-bar clicks into window
    /// summons any more.
    private var shouldRenderNotchIndicator: Bool {
        hasPillContent && viewModel.hasPhysicalNotch
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Session pill bars flanking the notch. Full-screen policy changes
            // opacity only; packing and shortcut snapshots continue at rest.
            if hasPillContent {
                let _ = navigationRecencyStore.revision
                // Pack once at this scope; both overlays read their slice
                // from the same result so left/right stay in sync. Also
                // captured into `pillSnapshotStore` so `handleSideClick`
                // resolves clicks against the same layout the user just
                // saw — see PillBarHitTestTests for the regression this
                // guards.
                let navigatorSnapshot = SidebarSessionListBuilder.build(
                    from: sessionMonitor.instances,
                    selectedSessionId: nil
                )
                let navigatorPillSessions = navigatorSnapshot.flatRows.compactMap {
                    navigatorSnapshot.sessionsById[$0.sessionId]
                }
                let pack = PillBarCoordinator.pack(
                    sessions: navigatorPillSessions,
                    leftMax: leftSafeWidth,
                    rightMax: rightSafeWidth,
                    codexUsagePresentation: codexUsagePresentation,
                    includeClaudeUsage: claudeUsageMonitor.showsPill,
                    currentDensity: pillSnapshotStore.density
                )
                let liveOverflowSnapshot = SidebarSessionListBuilder.build(
                    from: pack.overflowSessions,
                    selectedSessionId: nil
                )
                let overflowPopover = OverflowPopoverConfiguration(
                    isPresented: $showSessionNavigatorPopover,
                    snapshot: frozenOverflowSnapshot ?? liveOverflowSnapshot,
                    allSessionsSnapshot: frozenNavigatorSnapshot ?? navigatorSnapshot,
                    totalSessionCount: navigatorSnapshot.flatRows.count,
                    onWindowChange: { window in
                        transientPopoverWindowTracker.setWindow(window, for: .overflow)
                    },
                    onSelect: { session, modifierIntent in
                        dismissTransientPopovers()
                        recordNavigationRecency(session)
                        SessionOpenRouter.smartOpen(session, modifierIntent: modifierIntent)
                    },
                    onOpenAgentVisor: { session in
                        dismissTransientPopovers()
                        recordNavigationRecency(session)
                        SessionOpenRouter.openAgentVisor(session)
                    },
                    onOpenOriginal: { session in
                        dismissTransientPopovers()
                        recordNavigationRecency(session)
                        SessionOpenRouter.openOriginal(session)
                    },
                    onOpenMainWindow: {
                        dismissTransientPopovers()
                        AppDelegate.shared?.requestMainWindowActivation(.overflowPill)
                    },
                    onOpenSettings: {
                        dismissTransientPopovers()
                        AppDelegate.shared?.openSettings()
                    },
                    onDismiss: {
                        dismissTransientPopovers()
                    }
                )
                let usagePopover = pack.showsUsagePill
                    ? UsagePopoverConfiguration(
                        isPresented: $showCodexUsagePopover,
                        onWindowChange: { window in
                            transientPopoverWindowTracker.setWindow(window, for: .usage)
                        }
                    )
                    : nil
                let _ = capturePillSnapshot(
                    pack: pack,
                    overflowSnapshot: liveOverflowSnapshot,
                    navigatorSnapshot: navigatorSnapshot
                )

                // Invisible full-width canvas for positioning side content
                // allowsHitTesting(false) so clicks on empty space pass through
                Color.clear
                    .frame(width: viewModel.screenRect.width, height: closedNotchSize.height)
                    .allowsHitTesting(false)
                    .id(menuBarVersion)  // Force re-render when frontmost app changes or tray shifts
                    .overlay(alignment: .trailing) {
                        // Left bar: right-aligned to pill left edge.
                        HStack(spacing: pack.pillSpacing) {
                            NotchPillBar(
                                side: .left,
                                visiblePills: pack.leftPills,
                                overflowCount: pack.leftOverflowCount,
                                overflowPillWidth: pack.leftOverflowWidth,
                                maxWidth: leftSafeWidth,
                                pillSpacing: pack.pillSpacing,
                                horizontalPadding: pack.horizontalPadding,
                                overflowPopover: overflowPopover,
                                usagePopover: nil
                            )
                        }
                        .frame(maxWidth: leftSafeWidth, alignment: .trailing)
                        .clipped()
                        .padding(
                            .trailing,
                            viewModel.screenRect.width - pillLeftEdge
                                + seamEdgePadding(pillSpacing: pack.pillSpacing)
                        )
                    }
                    .overlay(alignment: .leading) {
                        // Right bar: left-aligned from pill right edge.
                        // Same session-pill semantics as the left bar.
                        HStack(spacing: pack.pillSpacing) {
                            NotchPillBar(
                                side: .right,
                                visiblePills: pack.rightPills,
                                overflowCount: pack.rightOverflowCount,
                                overflowPillWidth: pack.rightOverflowWidth,
                                maxWidth: rightSafeWidth,
                                pillSpacing: pack.pillSpacing,
                                horizontalPadding: pack.horizontalPadding,
                                overflowPopover: overflowPopover,
                                usagePopover: usagePopover,
                                showsCodexUsage: pack.showsCodexUsagePill,
                                showsClaudeUsage: pack.showsClaudeUsagePill
                            )
                        }
                        .frame(maxWidth: rightSafeWidth, alignment: .leading)
                        .clipped()
                        .padding(
                            .leading,
                            pillRightEdge + seamEdgePadding(pillSpacing: pack.pillSpacing)
                        )
                    }
                    // Diagnostic: collect actual rendered pill frames
                    // for click-time width comparison. Doesn't drive
                    // hit-testing — `pillSnapshotStore.snapshot` still
                    // does that. Kept on the same canvas as the bars
                    // so both overlays' preference values flow up.
                    .onPreferenceChange(PillFramesPreferenceKey.self) { frames in
                        pillSnapshotStore.renderedFrames = frames
                    }
                    .opacity(pillsAreVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.16), value: pillsAreVisible)
            }

            // Decorative closed-style notch indicator for the pills
            // strip. Anchors the panel visually to the menu-bar edge
            // when open, so users on external displays (no hardware
            // notch) can see "the notch is here" instead of staring
            // at a panel hanging in mid-air below the menu bar.
            if shouldRenderNotchIndicator {
                NotchShape(
                    topCornerRadius: cornerRadiusInsets.closed.top,
                    bottomCornerRadius: cornerRadiusInsets.closed.bottom
                )
                .fill(Color.black)
                .frame(
                    width: closedNotchSize.width,
                    height: closedNotchSize.height
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .opacity(pillsAreVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: pillsAreVisible)
            }

        }
        .opacity(isVisible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Drives system-managed chrome (e.g. text selection caret, native
        // controls) to follow the user-chosen flavor. The hardware-notch
        // mask itself stays fill(.black) regardless.
        // `.system` resolves to nil so the OS's effective appearance flows
        // through (auto-switch with sunset/sunrise); explicit modes pin.
        .preferredColorScheme({
            switch appearance.mode {
            case .light:  return .light
            case .dark:   return .dark
            case .system: return nil
            }
        }())
        .onAppear {
            isVisible = true
            // Several pieces of bootstrap belong to the primary `.full`
            // Bootstrap for the pills strip — the only NotchView
            // instance in the app.
            sessionMonitor.startMonitoring()
            startSideClickMonitor()
            startFullScreenPointerMonitor()
            syncFullScreenRevealState()
            GlobalSessionShortcutManager.shared.onToggleOverflow = {
                toggleSessionNavigatorPopover()
            }
            menuLayoutCoordinator.start(screenRect: viewModel.screenRect)
        }
        .onDisappear {
            GlobalSessionShortcutManager.shared.onToggleOverflow = nil
            sideClickMonitor?.stop()
            sideClickMonitor = nil
            fullScreenPointerMonitor?.stop()
            fullScreenPointerMonitor = nil
            cancelFullScreenPointerHide()
            cancelFullScreenShortcutHide()
            transientPopoverKeyMonitor?.stop()
            transientPopoverKeyMonitor = nil
            menuLayoutCoordinator.stop()
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: codexUsageMonitor.showsPill) { _, _ in
            if !codexUsageMonitor.showsPill && !claudeUsageMonitor.showsPill {
                showCodexUsagePopover = false
            }
        }
        .onChange(of: claudeUsageMonitor.showsPill) { _, _ in
            if !codexUsageMonitor.showsPill && !claudeUsageMonitor.showsPill {
                showCodexUsagePopover = false
            }
        }
        .onChange(of: showSessionNavigatorPopover) { _, _ in
            syncTransientPopoverKeyMonitor()
        }
        .onChange(of: showCodexUsagePopover) { _, _ in
            syncTransientPopoverKeyMonitor()
        }
        .onChange(of: viewModel.isFullScreenAppActive) { _, _ in
            syncFullScreenRevealState()
        }
        .onChange(of: fullScreenPolicy.policy) { _, _ in
            syncFullScreenRevealState()
        }
        .onChange(of: sessionShortcutManager.isRevealingShortcuts) { _, isRevealing in
            updateFullScreenShortcutReveal(isRevealing: isRevealing)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification)
        ) { notification in
            menuLayoutCoordinator.handleAppActivation(
                notification,
                screenRect: viewModel.screenRect
            )
        }
        // Tray icons shift left/right when menu-bar apps launch or quit.
        // Re-probe immediately and keep the existing render identity bump.
        .onReceive(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didLaunchApplicationNotification)
        ) { _ in
            menuBarVersion &+= 1
            menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)
        ) { _ in
            menuBarVersion &+= 1
            menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .agentVisorAccessibilityRecovered)
        ) { _ in
            menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)
        }
        .onReceive(menuProbeTimer) { _ in
            // Re-probe only when pills are actually rendered. With no
            // sessions, leftSafeWidth isn't displayed and the probe
            // traffic is wasted.
            guard !sessionMonitor.instances.isEmpty || codexUsageMonitor.showsPill || claudeUsageMonitor.showsPill else { return }
            menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)
        }
    }

    // MARK: - Pill Snapshot Capture

    /// Build a `PillBarHitTest.PillBarSnapshot` from the just-rendered
    /// pack and stash it into `pillSnapshotStore`. Called during body
    /// evaluation so the snapshot tracks every visible re-layout. The
    /// store is a class so this write doesn't loop SwiftUI.
    ///
    /// Returns Bool (always true) only to satisfy SwiftUI's
    /// ViewBuilder, which can't take Void expressions.
    @discardableResult
    private func capturePillSnapshot(
        pack: PillBarCoordinator.Pack,
        overflowSnapshot: SidebarSessionListSnapshot,
        navigatorSnapshot: SidebarSessionListSnapshot
    ) -> Bool {
        let previousSnapshot = pillSnapshotStore.snapshot
        let renderedSnapshot = makePillSnapshot(pack: pack)
        pillSnapshotStore.leftPills = pack.leftPills
        pillSnapshotStore.rightPills = pack.rightPills
        pillSnapshotStore.overflowSnapshot = overflowSnapshot
        pillSnapshotStore.navigatorSnapshot = navigatorSnapshot
        pillSnapshotStore.density = pack.density
        pillSnapshotStore.snapshot = renderedSnapshot

        #if DEBUG
        if previousSnapshot != renderedSnapshot {
            let leftIds = pack.leftPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
            let rightIds = pack.rightPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
            pillRaceLog.notice("render leftSafe=\(Int(self.leftSafeWidth)) rightSafe=\(Int(self.rightSafeWidth)) density=\(String(describing: pack.density), privacy: .public) spacing=\(Int(pack.pillSpacing)) padding=\(Int(pack.horizontalPadding)) usage=\(Int(pack.usageSlotWidth)) hidden=\(pack.overflowSessions.count) left=[\(leftIds, privacy: .public)] right=[\(rightIds, privacy: .public)]")
        }
        #endif
        return true
    }

    /// Anchor/slot math shared between render-time snapshot capture and
    /// the click handler. Lifted out so render and click can't disagree
    /// on bar geometry — only the pack contents differ between them
    /// (and that difference is the bug we're guarding against).
    private func makePillSnapshot(pack: PillBarCoordinator.Pack) -> PillBarHitTest.PillBarSnapshot {
        // Render order vs. notch-proximity order:
        //   Left bar uses `.frame(maxWidth: leftSafeWidth, alignment: .trailing)`
        //   so `visiblePills[0]` is the LEFTMOST pill — visually FARTHEST
        //   from the notch. The pill closest to the notch is the LAST
        //   element of `visiblePills`. PillBarHitTest walks `sessionPills`
        //   from the anchor outward, so the left-bar input must be reversed.
        //   Right bar already matches notch-proximity order under
        //   `.leading` alignment, no reversal needed.
        let leftSlots = pack.leftPills.reversed().map { pill in
            PillBarHitTest.PillSlot(
                id: pill.session.stableId,
                width: pill.renderedWidth
            )
        }
        let rightSlots = pack.rightPills.map { pill in
            PillBarHitTest.PillSlot(
                id: pill.session.stableId,
                width: pill.renderedWidth
            )
        }
        let rightUsageWidth: CGFloat? = pack.showsUsagePill
            ? pack.usageSlotWidth
            : nil

        // Rendering owns one outer notch-edge padding layer. Snapshot anchors
        // use that same offset so a click resolves against the exact pill the
        // user saw rather than the adjacent session. Both must consume the
        // notch-aware seam padding; using the raw edgePadding here while the
        // overlays use the collapsed non-notch seam would shift every click.
        let leftAnchor = pillLeftEdge - seamEdgePadding(pillSpacing: pack.pillSpacing)
        let rightAnchor = pillRightEdge + seamEdgePadding(pillSpacing: pack.pillSpacing)

        return PillBarHitTest.PillBarSnapshot(
            leftSlots: leftSlots,
            rightSlots: rightSlots,
            leftOverflowWidth: pack.leftOverflowWidth,
            rightOverflowWidth: pack.rightOverflowWidth,
            rightUsageWidth: rightUsageWidth,
            leftAnchorX: leftAnchor,
            rightAnchorX: rightAnchor,
            leftBarWidth: leftSafeWidth,
            rightBarWidth: rightSafeWidth,
            pillSpacing: pack.pillSpacing,
            minY: menuBarInteractionYRange.lowerBound,
            maxY: menuBarInteractionYRange.upperBound
        )
    }

    // MARK: - Slot Range Diagnostic

    /// Extract the same 4-char prefix the render-side log uses
    /// (`session.sessionId.prefix(8)`) from a stableId of the form
    /// "<pid>-<uuid>". Plain `split("-").last` returns the LAST UUID
    /// segment, not the first — bug in the prior formatter that made
    /// snapshot ids and slot-range ids look like disjoint sets.
    private func stableIdSidPrefix8(_ stableId: String) -> String {
        guard let dash = stableId.firstIndex(of: "-") else {
            return String(stableId.prefix(8))
        }
        let sid = stableId[stableId.index(after: dash)...]
        return String(sid.prefix(8))
    }

    /// Walk the left-bar slots from the anchor leftward (mirrors
    /// `PillBarHitTest.resolve`). Emits one tuple per slot:
    ///   `id:<sid8>@start..end`
    /// Overflow slot, when present, sits OUTBOARD of the session
    /// pills and is logged with id="+N".
    private func formatLeftRanges(_ s: PillBarHitTest.PillBarSnapshot) -> String {
        var cursor = s.leftAnchorX
        var parts: [String] = []
        for slot in s.leftSlots {
            let end = cursor
            let start = end - slot.width
            // slot.id is stableId; trim to the distinctive sessionId prefix.
            let sid = stableIdSidPrefix8(slot.id)
            parts.append("\(sid)@\(Int(start))..\(Int(end))")
            cursor = start - s.pillSpacing
        }
        if let overflowW = s.leftOverflowWidth {
            let end = cursor
            let start = end - overflowW
            parts.append("+N@\(Int(start))..\(Int(end))")
        }
        return parts.joined(separator: ",")
    }

    /// For each visible pill, emit:
    ///   `<sid8>:"<label>" math=<calcW> render=<minX>..<maxX>(<renderW>)`
    /// Lets us see directly whether `pillWidth(forLabel:)` matches
    /// SwiftUI's actual rendered width per-pill, and whether the
    /// rendered minX/maxX of each pill actually contains the click.
    private func formatPillComparisons() -> String {
        let allPills = pillSnapshotStore.leftPills + pillSnapshotStore.rightPills
        let frames = Dictionary(uniqueKeysWithValues: pillSnapshotStore.renderedFrames.map { ($0.id, $0) })
        return allPills.map { pill in
            let sid = stableIdSidPrefix8(pill.session.stableId)
            let mathW = Int(pill.renderedWidth)
            // Strip non-printable from label for log safety; truncate.
            let labelTrimmed = pill.label.replacingOccurrences(of: "\"", with: "'")
            let labelShort = labelTrimmed.count > 24 ? String(labelTrimmed.prefix(24)) + "…" : labelTrimmed
            let tier = String(describing: pill.labelTier)
            if let f = frames[pill.session.stableId] {
                let renderW = Int(f.frame.width)
                let minX = Int(f.frame.minX)
                let maxX = Int(f.frame.maxX)
                return "\(sid):\"\(labelShort)\" tier=\(tier) math=\(mathW) render=\(minX)..\(maxX)(\(renderW))"
            } else {
                return "\(sid):\"\(labelShort)\" tier=\(tier) math=\(mathW) render=missing"
            }
        }.joined(separator: " | ")
    }

    /// Walk the right-bar slots from the anchor rightward.
    private func formatRightRanges(_ s: PillBarHitTest.PillBarSnapshot) -> String {
        var cursor = s.rightAnchorX
        var parts: [String] = []
        for slot in s.rightSlots {
            let start = cursor
            let end = start + slot.width
            let sid = stableIdSidPrefix8(slot.id)
            parts.append("\(sid)@\(Int(start))..\(Int(end))")
            cursor = end + s.pillSpacing
        }
        if let overflowW = s.rightOverflowWidth {
            let start = cursor
            let end = start + overflowW
            parts.append("+N@\(Int(start))..\(Int(end))")
            cursor = end + s.pillSpacing
        }
        if let usageW = s.rightUsageWidth {
            let start = cursor
            let end = start + usageW
            parts.append("usage@\(Int(start))..\(Int(end))")
        }
        return parts.joined(separator: ",")
    }

    // MARK: - Side Content Click Forwarding

    private func startFullScreenPointerMonitor() {
        guard fullScreenPointerMonitor == nil else { return }
        let monitor = EventMonitor(mask: .mouseMoved) { [self] _ in
            updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
        }
        monitor.start()
        fullScreenPointerMonitor = monitor
        updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
    }

    private func syncFullScreenRevealState() {
        guard viewModel.isFullScreenAppActive,
              fullScreenPolicy.policy == .onDemand else {
            cancelFullScreenPointerHide()
            cancelFullScreenShortcutHide()
            isFullScreenPointerRevealActive = false
            isFullScreenShortcutRevealActive = false
            return
        }
        updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
        updateFullScreenShortcutReveal(
            isRevealing: sessionShortcutManager.isRevealingShortcuts
        )
    }

    private func updateFullScreenPointerReveal(at pointer: CGPoint) {
        guard viewModel.isFullScreenAppActive,
              fullScreenPolicy.policy == .onDemand else {
            cancelFullScreenPointerHide()
            isFullScreenPointerRevealActive = false
            return
        }

        let isInsideRevealZone = FullScreenPillPointerZonePolicy.contains(
            pointer: pointer,
            screenRect: viewModel.screenRect,
            isRevealed: isFullScreenPointerRevealActive
        )
        if isInsideRevealZone {
            cancelFullScreenPointerHide()
            isFullScreenPointerRevealActive = true
        } else {
            scheduleFullScreenPointerHide()
        }
    }

    private func scheduleFullScreenPointerHide() {
        guard isFullScreenPointerRevealActive,
              fullScreenPointerHideWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [self] in
            fullScreenPointerHideWorkItem = nil
            isFullScreenPointerRevealActive = false
        }
        fullScreenPointerHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func cancelFullScreenPointerHide() {
        fullScreenPointerHideWorkItem?.cancel()
        fullScreenPointerHideWorkItem = nil
    }

    private func updateFullScreenShortcutReveal(isRevealing: Bool) {
        guard viewModel.isFullScreenAppActive,
              fullScreenPolicy.policy == .onDemand else {
            cancelFullScreenShortcutHide()
            isFullScreenShortcutRevealActive = false
            return
        }
        if isRevealing {
            cancelFullScreenShortcutHide()
            isFullScreenShortcutRevealActive = true
        } else {
            scheduleFullScreenShortcutHide()
        }
    }

    private func scheduleFullScreenShortcutHide() {
        guard isFullScreenShortcutRevealActive,
              fullScreenShortcutHideWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [self] in
            fullScreenShortcutHideWorkItem = nil
            isFullScreenShortcutRevealActive = false
        }
        fullScreenShortcutHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func cancelFullScreenShortcutHide() {
        fullScreenShortcutHideWorkItem?.cancel()
        fullScreenShortcutHideWorkItem = nil
    }

    /// Global monitor detects clicks in left/right menu bar regions,
    /// then forwards them as synthetic events to the window so SwiftUI buttons handle targeting.
    private func startSideClickMonitor() {
        let monitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [self] event in
            handleSideClick(event)
        }
        monitor.start()
        sideClickMonitor = monitor
    }

    private func startTransientPopoverKeyMonitor() {
        guard transientPopoverKeyMonitor == nil else { return }
        let monitor = EventMonitor(mask: .keyDown) { [self] event in
            applyTransientPopoverPolicy(event.keyCode == 53 ? .escapeKey : .otherKey)
        }
        monitor.start()
        transientPopoverKeyMonitor = monitor
    }

    private func syncTransientPopoverKeyMonitor() {
        if showCodexUsagePopover {
            startTransientPopoverKeyMonitor()
        } else {
            transientPopoverKeyMonitor?.stop()
            transientPopoverKeyMonitor = nil
        }
    }

    private func handleSideClick(_ event: NSEvent) {
        if transientPopoverWindowTracker.contains(
            eventWindow: event.window,
            screenPoint: NSEvent.mouseLocation
        ) {
            applyTransientPopoverPolicy(.insidePopover)
            return
        }

        // Hidden full-screen layouts keep their shortcut snapshot current,
        // but must not intercept pointer actions from the owning app.
        guard pillsAreVisible else {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }
        guard hasPillContent else {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }
        guard let snapshot = pillSnapshotStore.snapshot else {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }
        // Geometry is captured once, when the strip is built for a display.
        // If that display has since moved, resized, or been detached, every
        // rect below describes the wrong region of the desktop — on a
        // multi-display setup the stale rect can land in the middle of
        // another monitor. Ignore the click and let the rebuilt strip, which
        // carries fresh geometry, own it.
        guard !viewModel.isGeometryStale else {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }

        let mousePos = NSEvent.mouseLocation
        let screenOriginX = viewModel.screenRect.origin.x
        let clickX = mousePos.x - screenOriginX
        let clickY = mousePos.y - viewModel.screenRect.origin.y
        if let minY = snapshot.minY, clickY < minY {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }
        if let maxY = snapshot.maxY, clickY > maxY {
            applyTransientPopoverPolicy(.outsideClick)
            return
        }

        // Resolve against the snapshot captured at body-render time, NOT
        // a freshly recomputed pack. `sessionMonitor.instances` re-sorts
        // on every `lastActivity` bump (dozens per second on a busy
        // session), so the live array can disagree with what the user
        // saw by the time their click reaches us. See PillBarHitTestTests
        // `test_resolveAgainstSnapshot_renderedAndLiveDiverge` for the
        // pinned contract: if you ever feel like inlining a `pack(...)`
        // call here again, the test makes it visible at review.
        let hit = PillBarHitTest.resolve(click: CGPoint(x: clickX, y: clickY), snapshot: snapshot)
        if event.type == .rightMouseDown {
            applyTransientPopoverPolicy(.outsideClick)
        } else {
            applyTransientPopoverPolicy(transientPopoverInteraction(for: hit))
        }
        #if DEBUG
        // Diagnostic line 1 (existing): snapshot order + resolved id.
        let leftIds = pillSnapshotStore.leftPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
        let rightIds = pillSnapshotStore.rightPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
        let resolvedDesc: String
        switch hit {
        case .session(let id):
            // id here is stableId ("<pid>-<uuid>"); take the distinctive prefix
            // of <uuid> for grep-parity with the render line. Earlier
            // version used `split("-").last`, which on UUIDs returns
            // the LAST segment instead of the first — making logs
            // look misleadingly like snapshot/slot ids were disjoint.
            resolvedDesc = "session=\(stableIdSidPrefix8(id))"
        case .overflow:    resolvedDesc = "overflow"
        case .usage:       resolvedDesc = "usage"
        case .empty:       resolvedDesc = "empty"
        case .outside:     resolvedDesc = "outside"
        }
        pillRaceLog.notice("click x=\(Int(clickX)) snapLeft=[\(leftIds, privacy: .public)] snapRight=[\(rightIds, privacy: .public)] resolved=\(resolvedDesc, privacy: .public)")
        // Diagnostic: dump the FULL stableId of the resolved pill +
        // every pill in the snapshot, so we can verify the resolver
        // and navigator are operating on byte-identical ids and
        // detect any UUID-prefix collisions hiding behind the 4-char
        // logging shorthand.
        if case .session(let id) = hit {
            let fullSnap = (pillSnapshotStore.leftPills + pillSnapshotStore.rightPills)
                .map { "\($0.label)~\($0.session.stableId)" }
                .joined(separator: " | ")
            pillRaceLog.notice("clickFull resolvedStableId=\(id, privacy: .public) snap=[\(fullSnap, privacy: .public)]")
        }

        // Diagnostic line 2 (new): the per-slot ranges the hit-test
        // walks. Mirrors the cursor walk in PillBarHitTest.resolve
        // exactly. If the slot containing `clickX` here matches what
        // `resolve` returns, the math is internally consistent and
        // the bug is upstream (snapshot inputs wrong). If they
        // disagree, the bug is in `resolve` (or this mirror has a
        // typo — visually verify against PillBarHitTest.swift).
        pillRaceLog.notice("ranges leftAnchor=\(Int(snapshot.leftAnchorX)) leftBarW=\(Int(snapshot.leftBarWidth)) rightAnchor=\(Int(snapshot.rightAnchorX)) rightBarW=\(Int(snapshot.rightBarWidth)) pillLeftEdge=\(Int(self.pillLeftEdge)) pillRightEdge=\(Int(self.pillRightEdge)) leftSafe=\(Int(self.leftSafeWidth)) rightSafe=\(Int(self.rightSafeWidth))")
        pillRaceLog.notice("leftRanges=[\(self.formatLeftRanges(snapshot), privacy: .public)]")
        pillRaceLog.notice("rightRanges=[\(self.formatRightRanges(snapshot), privacy: .public)]")

        // Diagnostic line 3 (new): per-pill comparison of math width
        // (`PillBarCoordinator.pillWidth(forLabel:)`, what the click
        // resolver assumes) vs SwiftUI's actual rendered global frame
        // (what the user clicks on). If these diverge by more than a
        // pixel or two, that's the bug.
        let comparisons = self.formatPillComparisons()
        pillRaceLog.notice("pillCompare=[\(comparisons, privacy: .public)]")
        #endif

        // The snapshot stores the side's `[VisiblePill]` separately so
        // we can recover the SessionState from the resolved id; left
        // and right are tried in sequence by `resolve` so we hand both
        // sides to the dispatcher and let it look up the matching id.
        let visiblePills = pillSnapshotStore.leftPills + pillSnapshotStore.rightPills
        if event.type == .rightMouseDown {
            showPillContextMenu(hit)
        } else {
            dispatchHit(
                hit,
                pills: visiblePills,
                modifierIntent: event.modifierFlags.contains(.option) ? .forceAgentVisor : .standard
            )
        }
    }

    private func transientPopoverInteraction(
        for hit: PillBarHitTest.Hit
    ) -> TransientPopoverInteraction {
        switch hit {
        case .overflow where showSessionNavigatorPopover:
            return .presentingControl
        case .usage where showCodexUsagePopover:
            return .presentingControl
        default:
            return .outsideClick
        }
    }

    @discardableResult
    private func applyTransientPopoverPolicy(
        _ interaction: TransientPopoverInteraction
    ) -> TransientPopoverDismissalAction {
        let action = TransientPopoverDismissalPolicy.action(for: interaction)
        if action == .dismiss {
            dismissTransientPopovers()
        }
        return action
    }

    private func dismissTransientPopovers() {
        showSessionNavigatorPopover = false
        frozenOverflowSnapshot = nil
        frozenNavigatorSnapshot = nil
        showCodexUsagePopover = false
        transientPopoverWindowTracker.setWindow(nil, for: .overflow)
        transientPopoverWindowTracker.setWindow(nil, for: .usage)
        transientPopoverKeyMonitor?.stop()
        transientPopoverKeyMonitor = nil
    }

    /// Map a `PillBarHitTest.Hit` to an action. Returns true if the hit
    /// was handled (so the caller can short-circuit further bar checks).
    /// `pills` is the side's snapshot used to recover the SessionState
    /// from the resolved stable id.
    ///
    /// IMPORTANT: this function is the SOLE click-effect surface for
    /// pills. The flash animation and the navigation dispatch are
    /// triggered side-by-side here on purpose — they read the same
    /// `id`, run on the same code path, and can't fall out of sync.
    /// The pill view itself has no Button, no `.onTapGesture`, no
    /// `.action()` — it's pure presentation that observes
    /// `PillFlashStore.shared.flashingId`. Don't reintroduce
    /// click-handling inside the pill view.
    @discardableResult
    private func dispatchHit(
        _ hit: PillBarHitTest.Hit,
        pills: [VisiblePill],
        modifierIntent: PillClickModifierIntent
    ) -> Bool {
        switch hit {
        case .session(let id):
            guard let pill = pills.first(where: { $0.session.stableId == id }) else {
                return false
            }
            hoverContextMenuCoordinator.primaryActionTriggered(for: id)
            // Flash and dispatch from the same resolved id so the
            // visible press state and navigation target cannot drift.
            PillFlashStore.shared.flash(id)
            let session = pill.session
            recordNavigationRecency(session)
            SessionOpenRouter.smartOpen(session, modifierIntent: modifierIntent)
            return true
        case .overflow:
            return toggleSessionNavigatorPopover()
        case .usage:
            PillFlashStore.shared.flash(PillFlashStore.usageSentinel)
            let willShowUsagePopover = !showCodexUsagePopover
            if willShowUsagePopover {
                Task { await CodexUsageMonitor.shared.refresh() }
                Task { await ClaudeUsageMonitor.shared.refresh() }
            }
            showSessionNavigatorPopover = false
            frozenOverflowSnapshot = nil
            frozenNavigatorSnapshot = nil
            showCodexUsagePopover = willShowUsagePopover
            return true
        case .empty, .outside:
            return false
        }
    }

    @discardableResult
    private func toggleSessionNavigatorPopover() -> Bool {
        let hasOverflow = !(pillSnapshotStore.overflowSnapshot?.flatRows.isEmpty ?? true)
        let action = GlobalSessionShortcutPolicy.overflowAction(
            isPresented: showSessionNavigatorPopover,
            hasOverflow: hasOverflow
        )
        guard action != .ignore else { return false }

        PillFlashStore.shared.flash(PillFlashStore.overflowSentinel)
        let willShowNavigatorPopover = action == .open
        if willShowNavigatorPopover {
            frozenOverflowSnapshot = pillSnapshotStore.overflowSnapshot
            frozenNavigatorSnapshot = pillSnapshotStore.navigatorSnapshot
        }
        #if DEBUG
        let actionLabel = willShowNavigatorPopover ? "open" : "close"
        pillRaceLog.notice("overflowClick action=\(actionLabel, privacy: .public)")
        #endif
        showCodexUsagePopover = false
        showSessionNavigatorPopover = willShowNavigatorPopover
        if !willShowNavigatorPopover {
            frozenOverflowSnapshot = nil
            frozenNavigatorSnapshot = nil
        }
        return true
    }

    private func showPillContextMenu(_ hit: PillBarHitTest.Hit) {
        switch hit {
        case .session(let id):
            let menu = NSMenu()
            menu.addItem(actionItem("Pill Settings...") {
                AppDelegate.shared?.openSettings()
            })
            presentSessionContextMenu(menu, sessionID: id)
        case .overflow:
            let model = PillClickOverflowMenuModel.menu()
            let menu = NSMenu()
            menu.addItem(actionItem(model.openAgentVisorTitle) {
                AppDelegate.shared?.requestMainWindowActivation(.overflowPill)
            })
            menu.addItem(.separator())
            menu.addItem(actionItem(model.settingsTitle) {
                AppDelegate.shared?.openSettings()
            })
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case .usage:
            let menu = NSMenu()
            if codexUsageMonitor.showsPill {
                menu.addItem(actionItem("Refresh Codex Usage") {
                    Task { await CodexUsageMonitor.shared.refresh() }
                })
            }
            if claudeUsageMonitor.showsPill {
                menu.addItem(actionItem("Refresh Claude Usage") {
                    Task { await ClaudeUsageMonitor.shared.refresh() }
                })
            }
            menu.addItem(.separator())
            menu.addItem(actionItem("Pill Settings...") {
                AppDelegate.shared?.openSettings()
            })
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        case .empty, .outside:
            return
        }
    }

    private func presentSessionContextMenu(_ menu: NSMenu, sessionID: String) {
        let location = NSEvent.mouseLocation
        hoverContextMenuCoordinator.contextMenuOpened(for: sessionID)
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: location, in: nil)
            hoverContextMenuCoordinator.contextMenuClosed(for: sessionID)
        }
    }

    private func actionItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(PillMenuActionTarget.invoke), keyEquivalent: "")
        let target = PillMenuActionTarget(action)
        item.target = target
        item.representedObject = target
        return item
    }

    private func recordNavigationRecency(_ session: SessionState) {
        SessionNavigationRecencyStore.shared.record(session)
    }

    // MARK: - Notch Layout

    private var isProcessing: Bool {
        activityCoordinator.expandingActivity.show && activityCoordinator.expandingActivity.type == .claude
    }

    // MARK: - Event Handlers

    private func handleProcessingChange() {
        if isAnyProcessing || hasPendingPermission {
            // Show claude activity when processing or waiting for permission
            activityCoordinator.showActivity(type: .claude)
            isVisible = true
        } else if hasWaitingForInput {
            // Keep visible for waiting-for-input but hide the processing spinner
            activityCoordinator.hideActivity()
            isVisible = true
        } else {
            // Hide activity indicator when done (notch itself stays visible)
            activityCoordinator.hideActivity()
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            AppDelegate.shared?.requestMainWindowActivation(.pendingApprovalDetected)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.sessionId })
        let newWaitingIds = readyEpisodeTracker.update(readySessionIDs: currentIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.sessionId) {
            waitingForInputTimestamps[session.sessionId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.sessionId) }

            // Play notification sound if the session is not actively focused
            if let soundName = AppSettings.notificationSound.soundName {
                // Check if we should play sound (async check for tmux pane focus)
                Task {
                    let shouldPlaySound = await shouldPlayNotificationSound(for: newlyWaitingSessions)
                    if shouldPlaySound {
                        _ = await MainActor.run {
                            NSSound(named: soundName)?.play()
                        }
                    }
                }
            }

            // Trigger bounce animation to get user's attention
            DispatchQueue.main.async {
                isBouncing = true
                // Bounce back after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isBouncing = false
                }
            }

            // Schedule hiding the checkmark after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
                // Trigger a UI update to re-evaluate hasWaitingForInput
                handleProcessingChange()
            }
        }
    }

    /// Determine if notification sound should play for the given sessions
    /// Returns true if ANY session is not actively focused
    private func shouldPlayNotificationSound(for sessions: [SessionState]) async -> Bool {
        for session in sessions {
            guard let pid = session.pid else {
                // No PID means we can't check focus, assume not focused
                return true
            }

            let isFocused = await TerminalVisibilityDetector.isSessionFocused(sessionPid: pid)
            if !isFocused {
                return true
            }
        }

        return false
    }
}
