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
enum NotchViewDisplayMode {
    case full
    case pillsOnlyOpenState
}

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
    var displayMode: NotchViewDisplayMode = .full
    /// Shared session monitor. Both the primary `.full` instance in
    /// `NotchWindow` and the parallel `.pillsOnlyOpenState` instance in
    /// `PillsStripWindow` need to look at the SAME `instances` array
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
    @ObservedObject private var fullScreenPolicy = FullScreenPolicySelector.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @StateObject private var menuLayoutCoordinator = NotchMenuLayoutCoordinator()
    @StateObject private var transientPopoverWindowTracker = TransientPopoverWindowTracker()
    /// Observed so a flavor flip re-evaluates this view's body and cascades
    /// new ChatTheme tokens into every descendant.
    @ObservedObject private var appearance = AppearanceSelector.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var previousWaitingForInputIds: Set<String> = []
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
    private let menuProbeTimer = Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()

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
            if let enteredAt = waitingForInputTimestamps[session.stableId] {
                return now.timeIntervalSince(enteredAt) < displayDuration
            }
            return false
        }
    }

    // MARK: - Sizing

    private var closedNotchSize: CGSize {
        CGSize(
            width: viewModel.deviceNotchRect.width,
            height: viewModel.deviceNotchRect.height
        )
    }

    /// Extra width for expanding activities
    /// When closed: no expansion (side content uses all available space)
    /// When opened: not used (panel has its own sizing)
    private var expansionWidth: CGFloat {
        0
    }

    /// Outer panel size for the visual notch. Tracks `contentVisible` (an
    /// animatable @Published bool) rather than `status` so the frame
    /// collapses in lock-step with the content fade. Flipping on `status`
    /// instead would snap because the window-resize Combine sink runs on
    /// `status` and the surrounding layout depends on it for side content.
    private var notchSize: CGSize {
        viewModel.contentVisible ? viewModel.openedSize : closedNotchSize
    }

    private var openedHorizontalPadding: CGFloat {
        cornerRadiusInsets.opened.top + 12
    }

    /// Inner content width is keyed off `openedSize`, not the animated
    /// `notchSize`, so contentView's own width stays steady while the
    /// outer panel shrinks. Otherwise content would shrink twice (once
    /// from the parent frame, once from the .scale(0.8) transition).
    private var openedContentWidth: CGFloat {
        max(0, viewModel.openedSize.width - openedHorizontalPadding * 2)
    }

    /// Inner content height pinned to the open panel height (minus the
    /// header row) for the same reason `openedContentWidth` is keyed off
    /// `openedSize`. When the outer notch collapses on close, the inner
    /// VStack would otherwise shrink contentView's proposed height to
    /// near zero, which makes the LazyVStack inside ChatView derealize
    /// most of its rows. On reopen the rows get realized with actual
    /// heights different from the prior estimates, shifting
    /// NSScrollView's preserved contentOffset to a visually wrong row —
    /// the drift we're trying to avoid. Holding the inner height steady
    /// keeps LazyVStack's realization stable across notch state.
    private var openedContentHeight: CGFloat {
        max(0, viewModel.openedSize.height - closedNotchSize.height)
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
        viewModel.contentVisible
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.top
    }

    private var bottomCornerRadius: CGFloat {
        viewModel.contentVisible
            ? cornerRadiusInsets.opened.bottom
            : cornerRadiusInsets.closed.bottom
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
        viewModel.contentVisible
            ? cornerRadiusInsets.opened.top
            : cornerRadiusInsets.closed.bottom
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

    /// Left edge of the actual pill (accounts for expansion beyond hardware notch)
    private var pillLeftEdge: CGFloat {
        let totalPillWidth = closedNotchSize.width + expansionWidth
        return (viewModel.screenRect.width - totalPillWidth) / 2 - 4  // 4px gap
    }

    /// Right edge of the actual pill (accounts for expansion beyond hardware notch)
    private var pillRightEdge: CGFloat {
        let totalPillWidth = closedNotchSize.width + expansionWidth
        return (viewModel.screenRect.width + totalPillWidth) / 2 + 4  // 4px gap
    }

    /// Safe width for left side content (avoids app menus).
    ///
    /// The coordinator binds every measurement and cache entry to the menu
    /// owner resolved at the latest app activation. Periodic probes remeasure
    /// that owner without rerouting merely because its window crosses a
    /// display boundary. Unknown ownership hides pills until reliable
    /// evidence arrives rather than guessing.
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
        guard !sessionMonitor.instances.isEmpty || codexUsageMonitor.showsPill else {
            return false
        }
        switch displayMode {
        case .full:
            return viewModel.status == .closed
        case .pillsOnlyOpenState:
            return true
        }
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

    /// Whether the centered notch shape + panel content should render
    /// in this instance. Always true in `.full`; never in
    /// `.pillsOnlyOpenState` — that variant is a pill-only spectator.
    private var shouldRenderCenter: Bool {
        displayMode == .full
    }

    /// Whether to render the small black notch shape between the left
    /// and right pill groups. With the chat panel retired, this is the
    /// only "notch" visible to the user — without it, external displays
    /// (no physical notch hardware) show an empty gap between the pill
    /// groups. On the built-in display the rendered shape sits behind
    /// the hardware cutout and is invisible. Always on whenever pills
    /// render so left/right groups always have a visual anchor.
    private var shouldRenderNotchIndicator: Bool {
        displayMode == .pillsOnlyOpenState
            && hasPillContent
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
                    includeUsage: codexUsageMonitor.showsPill
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
                        HStack(spacing: PillBarCoordinator.pillSpacing) {
                            NotchPillBar(
                                side: .left,
                                visiblePills: pack.leftPills,
                                overflowCount: pack.leftOverflowCount,
                                maxWidth: leftSafeWidth,
                                overflowPopover: overflowPopover,
                                usagePopover: nil
                            )
                        }
                        .frame(maxWidth: leftSafeWidth, alignment: .trailing)
                        .clipped()
                        .padding(.trailing, viewModel.screenRect.width - pillLeftEdge + 8)
                    }
                    .overlay(alignment: .leading) {
                        // Right bar: left-aligned from pill right edge.
                        // Same session-pill semantics as the left bar.
                        HStack(spacing: PillBarCoordinator.pillSpacing) {
                            NotchPillBar(
                                side: .right,
                                visiblePills: pack.rightPills,
                                overflowCount: pack.rightOverflowCount,
                                maxWidth: rightSafeWidth,
                                overflowPopover: overflowPopover,
                                usagePopover: usagePopover
                            )
                        }
                        .frame(maxWidth: rightSafeWidth, alignment: .leading)
                        .clipped()
                        .padding(.leading, pillRightEdge + 8)
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

            // Notch pill overlay
            if shouldRenderCenter {
                VStack(spacing: 0) {
                    notchLayout
                    // Block ambient animations on the inner content only
                    // (header row state, processing/waiting indicators).
                    // The outer frame, padding, and clipShape sit ABOVE
                    // this modifier so they remain animatable, which is
                    // what lets the border collapse in sync with the
                    // content fade on close. Keeping it inside addresses
                    // the original v1.6.1 stale-cache bug (ghost crab
                    // rendering from per-value .animation modifiers on
                    // hasWaitingForInput / isBouncing) without freezing
                    // the geometry.
                    .transaction { $0.animation = nil }
                    .padding(
                        .horizontal,
                        viewModel.contentVisible
                            ? cornerRadiusInsets.opened.top
                            : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], viewModel.contentVisible ? 12 : 0)
                    .frame(
                        // Width pinned explicitly even when closed: ChatView
                        // stays mounted across notch close (so NSScrollView's
                        // contentOffset preserves verbatim), which means
                        // contentView still claims openedContentWidth in
                        // SwiftUI layout even at maxHeight 0. Without this
                        // override the parent VStack inherits that width and
                        // the closed-pill notch shape balloons across the menu
                        // bar. clipShape below masks the off-screen content.
                        width: viewModel.contentVisible ? notchSize.width : closedNotchSize.width,
                        height: viewModel.contentVisible ? notchSize.height : closedNotchSize.height,
                        alignment: .top
                    )
                    // When the panel is closed, the only visible portion is
                    // the small notch shape between the menu-bar pills.
                    // That sits flush against the macOS hardware notch
                    // (the physical camera cutout, true black). Fill it
                    // with pure black so the two visually merge regardless
                    // of theme. When the panel is open, the body content
                    // (ChatView / ClaudeInstancesView / NotchMenuView)
                    // paints its own theme-aware backgrounds on top, so
                    // the outer fill rarely shows through. Fall back to
                    // ChatTheme.headerBg so any uncovered gap matches
                    // the surrounding panel canvas tone.
                    .background(viewModel.contentVisible ? ChatTheme.headerBg : Color.black)
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        // Anti-aliasing mask along the top edge where the
                        // panel meets the macOS hardware notch. When the
                        // panel is closed it should be true black to merge
                        // with the hardware. When open it should match the
                        // panel canvas (headerBg) so it doesn't show as a
                        // dark seam against Latte's light mantle.
                        Rectangle()
                            .fill(viewModel.contentVisible ? ChatTheme.headerBg : Color.black)
                            .frame(height: 1)
                            .padding(.horizontal, panelCornerRadius)
                    }
                    .shadow(
                        // Heavy 70% black shadow looks fine on Mocha (the
                        // dark panel absorbs most of the halo), but on
                        // Latte's light bg it reads as a thick dark border
                        // around the entire window. Drop to 20% in Latte
                        // for a soft elevation effect that matches typical
                        // light-mode UI conventions.
                        color: (viewModel.contentVisible || isHovering)
                            ? .black.opacity(appearance.mode == .light ? 0.20 : 0.7)
                            : .clear,
                        radius: 6
                    )
                    .frame(
                        // Same override as the inner frame above — see
                        // comment there for why width must be explicit when
                        // closed.
                        width: viewModel.contentVisible ? notchSize.width : closedNotchSize.width,
                        height: viewModel.contentVisible ? notchSize.height : closedNotchSize.height,
                        alignment: .top
                    )
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            isHovering = hovering
                        }
                    }
                    .onTapGesture {
                        // Phase 1 of notch-panel retirement: tapping the
                        // visible notch shape now opens the main window
                        // instead of expanding the in-notch chat panel.
                        AppDelegate.shared?.requestMainWindowActivation(.notchClick)
                    }
                    .opacity(
                        !pillsAreVisible && viewModel.status == .closed
                            ? 0 : 1
                    )
                    .animation(.easeOut(duration: 0.16), value: pillsAreVisible)
                }
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
            // NotchView instance only — running them on the parallel
            // `.pillsOnlyOpenState` instance would:
            //   - double-start `sessionMonitor` (re-bootstrap sessions,
            //     re-bind HookSocketServer.shared.onEvent, re-start the
            //     SessionFileWatcher fleet)
            //   - install a second global click `EventMonitor` that
            //     fires `handleSideClick` twice per click (double pill
            //     navigation)
            //   - reassign `prioritySessionProvider` to a different
            //     `sessionMonitor` instance so the hotkey opens onto
            //     the wrong session list
            // With the notch panel retired, the pills strip mounts
            // NotchView in `.pillsOnlyOpenState`, and that's the
            // only NotchView instance in the app. Bootstrap runs
            // unconditionally now — there is no parallel `.full`
            // instance to defer to.
            sessionMonitor.startMonitoring()
            startSideClickMonitor()
            startFullScreenPointerMonitor()
            syncFullScreenRevealState()
            viewModel.prioritySessionProvider = { [weak sessionMonitor] in
                guard let monitor = sessionMonitor else { return nil }
                return SessionPriority.prioritySession(from: monitor.instances)
            }
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
        .onChange(of: viewModel.status) { oldStatus, newStatus in
            handleStatusChange(from: oldStatus, to: newStatus)
        }
        .onChange(of: sessionMonitor.pendingInstances) { _, sessions in
            handlePendingSessionsChange(sessions)
        }
        .onChange(of: sessionMonitor.instances) { _, instances in
            handleProcessingChange()
            handleWaitingForInputChange(instances)
        }
        .onChange(of: codexUsageMonitor.showsPill) { _, showsPill in
            if !showsPill {
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
            // Re-probe only when pills are actually rendered. When the
            // notch is opened or there are no sessions, leftSafeWidth
            // isn't displayed and the probe traffic is wasted.
            guard viewModel.status == .closed,
                  (!sessionMonitor.instances.isEmpty || codexUsageMonitor.showsPill) else { return }
            menuLayoutCoordinator.probe(screenRect: viewModel.screenRect)
        }
        // Legacy notch-panel notifications (.notchClickOutside,
        // .notchEscapePressed) used to trigger panel close. The panel
        // is gone — observers removed.
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
        ) { _ in
            // Swiping to another Space leaves the overlay visible but
            // unfocused on the new Space — confusing and unactionable.
            // Treat it like a click-outside.
            if viewModel.status == .opened {
                viewModel.notchClose()
            }
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
        pillSnapshotStore.snapshot = renderedSnapshot

        #if DEBUG
        if previousSnapshot != renderedSnapshot {
            let leftIds = pack.leftPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
            let rightIds = pack.rightPills.map { String($0.session.sessionId.prefix(8)) }.joined(separator: ",")
            let mode = displayMode == .full ? "full" : "stripOpen"
            pillRaceLog.notice("render mode=\(mode, privacy: .public) leftSafe=\(Int(self.leftSafeWidth)) rightSafe=\(Int(self.rightSafeWidth)) left=[\(leftIds, privacy: .public)] right=[\(rightIds, privacy: .public)]")
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
                width: PillBarCoordinator.pillWidth(forLabel: pill.label)
            )
        }
        let rightSlots = pack.rightPills.map { pill in
            PillBarHitTest.PillSlot(
                id: pill.session.stableId,
                width: PillBarCoordinator.pillWidth(forLabel: pill.label)
            )
        }
        let leftOverflowWidth: CGFloat? = pack.leftOverflowCount > 0
            ? PillBarCoordinator.overflowPillWidth(count: pack.leftOverflowCount)
            : nil
        let rightOverflowWidth: CGFloat? = pack.rightOverflowCount > 0
            ? PillBarCoordinator.overflowPillWidth(count: pack.rightOverflowCount)
            : nil
        let rightUsageWidth: CGFloat? = pack.showsUsagePill
            ? CGFloat(CodexUsageGlancePolicy.fixedWidth)
            : nil

        // Bar anchors stack TWO paddings — the OUTER overlay padding plus
        // the INNER `NotchPillBar.padding`. So pill[0]'s notch-facing edge
        // sits at `pillLeftEdge - 2 * edgePadding` (left) or `pillRightEdge
        // + 2 * edgePadding` (right). Earlier this was off by one
        // `edgePadding` — clicks on a pill's notch-facing half resolved
        // to the next pill ("nearby session" bug).
        let leftAnchor = pillLeftEdge - 2 * PillBarCoordinator.edgePadding
        let rightAnchor = pillRightEdge + 2 * PillBarCoordinator.edgePadding

        return PillBarHitTest.PillBarSnapshot(
            leftSlots: leftSlots,
            rightSlots: rightSlots,
            leftOverflowWidth: leftOverflowWidth,
            rightOverflowWidth: rightOverflowWidth,
            rightUsageWidth: rightUsageWidth,
            leftAnchorX: leftAnchor,
            rightAnchorX: rightAnchor,
            leftBarWidth: leftSafeWidth + PillBarCoordinator.edgePadding,
            rightBarWidth: rightSafeWidth + PillBarCoordinator.edgePadding,
            pillSpacing: PillBarCoordinator.pillSpacing,
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
            let mathW = Int(PillBarCoordinator.pillWidth(forLabel: pill.label))
            // Strip non-printable from label for log safety; truncate.
            let labelTrimmed = pill.label.replacingOccurrences(of: "\"", with: "'")
            let labelShort = labelTrimmed.count > 24 ? String(labelTrimmed.prefix(24)) + "…" : labelTrimmed
            if let f = frames[pill.session.stableId] {
                let renderW = Int(f.frame.width)
                let minX = Int(f.frame.minX)
                let maxX = Int(f.frame.maxX)
                return "\(sid):\"\(labelShort)\" math=\(mathW) render=\(minX)..\(maxX)(\(renderW))"
            } else {
                return "\(sid):\"\(labelShort)\" math=\(mathW) render=missing"
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
            menu.addItem(actionItem("Refresh Codex Usage") {
                Task { await CodexUsageMonitor.shared.refresh() }
            })
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

    /// Whether to show the expanded closed state (processing, pending permission, or waiting for input)
    private var showClosedActivity: Bool {
        isProcessing || hasPendingPermission || hasWaitingForInput
    }

    @ViewBuilder
    private var notchLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row - always present, contains crab and spinner that persist across states
            // Tapping the header when opened closes the notch (like clicking the pill)
            headerRow
                // Opened: 4pt taller so the bottom hairline divider drops
                // a touch below the icon row. HStack vertical-centers, so
                // the chrome stays middle-aligned in the taller row.
                .frame(height: max(24, closedNotchSize.height) + (viewModel.contentVisible ? 4 : 0))
                .onTapGesture {
                    if viewModel.status == .opened {
                        viewModel.notchClose()
                    }
                }

            // Always-mount contentView so ChatView's underlying NSScrollView
            // keeps its contentOffset across notch close/reopen within a
            // single process — the "reopen to old location" UX. Animation
            // is opacity + scale only; the frame stays at maxHeight: .infinity
            // throughout, and the outer panel frame (controlled by the
            // .frame call further up the view chain) animates between
            // notchSize.height and closedNotchSize.height as a clean
            // finite-to-finite transition.
            //
            // This replaces an earlier always-mount attempt (commit 2e84a68)
            // that deadlocked the open animation by ~10s on external
            // displays. Four lessons applied here together:
            //   1. No `.frame(maxHeight: 0 ↔ .infinity)` animation — that
            //      .infinity edge case was a likely root cause.
            //   2. No `withAnimation` in NotchViewModel.notchOpen — the
            //      .animation modifier below is the only animation source,
            //      so SwiftUI never has two contexts competing for the
            //      same property change.
            //   3. NotchViewModel.notchOpen defers `status = .opened` by
            //      50ms so the contentView's animation transaction commits
            //      before AppKit invalidates layout for the window resize
            //      driven by the status sink. Mirrors how notchClose
            //      already defers `status = .closed`.
            //   4. Outer frame's closed-state height is explicit
            //      (`closedNotchSize.height`) rather than `nil`, so it
            //      doesn't try to compute intrinsic from a contentView
            //      that claims `.infinity`.
            contentView
                .frame(width: openedContentWidth, alignment: .top)
                .frame(height: openedContentHeight, alignment: .top)
                .clipped() // Prevent content (tables, code blocks) from overflowing panel bounds
                .scaleEffect(viewModel.contentVisible ? 1.0 : 0.8, anchor: .top)
                .opacity(viewModel.contentVisible ? 1.0 : 0.0)
                .allowsHitTesting(viewModel.contentVisible)
                .animation(
                    .easeOut(duration: viewModel.contentVisible ? 0.35 : 0.25),
                    value: viewModel.contentVisible
                )
        }
    }

    // MARK: - Header Row (persists across states)

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: 0) {
            if viewModel.contentVisible {
                openedHeaderContent
            } else {
                Color.clear
                    .frame(width: closedNotchSize.width - 20, height: closedNotchSize.height)
            }
        }
        // Opened: grow the chrome row by 4pt so the bottom divider sits a
        // hair below the icon row, giving the title + ≡ × cluster a touch
        // of breathing room. HStack centers vertically by default, so the
        // icons stay middle-aligned in the now-taller row. Closed state
        // keeps the original height so the notch silhouette is unchanged.
        .frame(height: closedNotchSize.height + (viewModel.contentVisible ? 4 : 0))
        // Hairline divider at the bottom of the chrome row when opened.
        // Earlier tries painted a contrasting fill (`surface0`) here,
        // but a darker strip stacked between the macOS menu bar and the
        // chat body produced three competing greys in ~60pt of vertical
        // space — muddy rather than hierarchical. Using the panel's own
        // `headerBg` for the chrome row + a 1pt divider matches the
        // standard macOS pattern (Safari, Notes, Mail) and reads as a
        // clean separator without the tonal stack-up.
        .overlay(alignment: .bottom) {
            if viewModel.contentVisible {
                Rectangle()
                    .fill(ChatTheme.muted.opacity(0.45))
                    .frame(height: 1)
            }
        }
    }

    private var sideWidth: CGFloat {
        max(0, closedNotchSize.height - 12) + 10
    }

    // MARK: - Opened Header Content

    @State private var isOpenedCloseHovered = false
    @State private var isOpenedChatBackHovered = false

    @ViewBuilder
    private var openedHeaderContent: some View {
        HStack(spacing: 8) {
            // Per-content leading area. Folds the chat back-button +
            // session title into this single chrome row instead of
            // stacking a second `chatHeader` row below it (which left
            // ~32 pt of empty space between the `≡ ×` icons and the
            // chat title). Sessions list / menu have nothing leading,
            // so they fall through to a Spacer.
            switch viewModel.contentType {
            case .chat(let session):
                Button {
                    viewModel.exitChat()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isOpenedChatBackHovered ? ChatTheme.primary : ChatTheme.secondary)
                            .frame(width: 22, height: 22)

                        Text(session.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(ChatTheme.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isOpenedChatBackHovered ? ChatTheme.headerHover : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isOpenedChatBackHovered = $0 }
            case .instances, .menu:
                EmptyView()
            }

            Spacer()

            // Menu toggle. When the menu is already open, the icon flips
            // to a back-chevron so it reads as "leave the menu" — that
            // way it doesn't collide visually with the trailing
            // close-panel `xmark` (two adjacent `xmark` buttons would
            // be ambiguous).
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleMenu()
                    if viewModel.contentType == .menu {
                        updateManager.markUpdateSeen()
                    }
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: viewModel.contentType == .menu ? "chevron.left" : "line.3.horizontal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(ChatTheme.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())

                    // Green dot for unseen update
                    if updateManager.hasUnseenUpdate && viewModel.contentType != .menu {
                        Circle()
                            .fill(TerminalColors.green)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)

            // Universal trailing chrome — was the close-panel button.
            // The notch panel doesn't open anymore, so this branch is
            // never visible. Kept as `EmptyView` to preserve the
            // surrounding layout while compiling without
            // `NotchCloseButton`.
            EmptyView()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Content View (Opened State)

    @ViewBuilder
    private var contentView: some View {
        // The notch chat panel was retired in favor of the main window.
        // The panel never opens (no caller invokes `viewModel.notchOpen`),
        // so this view tree is unreachable — but `notchLayout` still
        // mounts it because the closed-state animation keys off the
        // same VStack. EmptyView() keeps the layout stable without
        // dragging the legacy ChatView/ClaudeInstancesView/NotchMenuView
        // surfaces into the build.
        Group {
            EmptyView()
        }
        .frame(width: openedContentWidth, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped() // Clip any overflowing content (markdown tables, code blocks)
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

    private func handleStatusChange(from oldStatus: NotchStatus, to newStatus: NotchStatus) {
        switch newStatus {
        case .opened, .popping:
            isVisible = true
            // Clear waiting-for-input timestamps only when manually opened (user acknowledged)
            if viewModel.openReason == .click || viewModel.openReason == .hotkey {
                waitingForInputTimestamps.removeAll()
            }
        case .closed:
            break  // Notch stays visible in all states
        }
    }

    private func handlePendingSessionsChange(_ sessions: [SessionState]) {
        let currentIds = Set(sessions.map { $0.stableId })
        let newPendingIds = currentIds.subtracting(previousPendingIds)

        if !newPendingIds.isEmpty &&
           viewModel.status == .closed &&
           !TerminalVisibilityDetector.isTerminalVisibleOnCurrentSpace() {
            AppDelegate.shared?.requestMainWindowActivation(.pendingApprovalDetected)
        }

        previousPendingIds = currentIds
    }

    private func handleWaitingForInputChange(_ instances: [SessionState]) {
        // Get sessions that are now waiting for input
        let waitingForInputSessions = instances.filter { $0.phase == .waitingForInput }
        let currentIds = Set(waitingForInputSessions.map { $0.stableId })
        let newWaitingIds = currentIds.subtracting(previousWaitingForInputIds)

        // Track timestamps for newly waiting sessions
        let now = Date()
        for session in waitingForInputSessions where newWaitingIds.contains(session.stableId) {
            waitingForInputTimestamps[session.stableId] = now
        }

        // Clean up timestamps for sessions no longer waiting
        let staleIds = Set(waitingForInputTimestamps.keys).subtracting(currentIds)
        for staleId in staleIds {
            waitingForInputTimestamps.removeValue(forKey: staleId)
        }

        // Bounce the notch when a session newly enters waitingForInput state
        if !newWaitingIds.isEmpty {
            // Get the sessions that just entered waitingForInput
            let newlyWaitingSessions = waitingForInputSessions.filter { newWaitingIds.contains($0.stableId) }

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

        previousWaitingForInputIds = currentIds
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
