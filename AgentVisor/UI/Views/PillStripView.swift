//
//  PillStripView.swift
//  AgentVisor
//
//  The menu-bar pill strip, with an optional physical-notch decoration.
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


private let pillCornerRadii = (top: CGFloat(6), bottom: CGFloat(14))

/// Shared "which pill should flash right now" channel. Set by
/// `dispatchHit` when a pill click resolves; observed by the
/// pill views to drive their press-flash animation. Lives outside
/// the pill view so it survives the view's identity churn during
/// session re-sorts (a SwiftUI `@State` inside the view would be
/// blown away when ForEach decides to re-key the row).
///
/// There is one click stream and one strip. Keeping the flash outside the pill
/// view makes the rendered target, the click result, and the animation use the
/// same stable session identity.
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

/// Holds the pill layout that was actually rendered. Click handling reads this
/// snapshot instead of rebuilding from live sessions, because an activity update
/// can reorder sessions between rendering and the click.
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

struct PillStripView: View {
    @ObservedObject var viewModel: PillStripViewModel
    /// Shared session monitor. The pills strip is the only instance in
    /// the app, and it needs the SAME `instances` array
    /// at click time — otherwise a one-tick lag between the two
    /// `@StateObject` instances' subscriber callbacks could let
    /// `handleSideClick`'s pack diverge from the visually rendered
    /// pills, reintroducing a "click pill A, navigate to B" race.
    /// Sharing one monitor closes that gap.
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var navigationRecencyStore = SessionNavigationRecencyStore.shared
    @ObservedObject private var codexUsageMonitor = CodexUsageMonitor.shared
    @ObservedObject private var claudeUsageMonitor = ClaudeUsageMonitor.shared
    @ObservedObject private var fullScreenPolicy = FullScreenPolicySelector.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @StateObject private var menuLayoutCoordinator = MenuBarLayoutCoordinator()
    @StateObject private var transientPopoverWindowTracker = TransientPopoverWindowTracker()
    /// Observed so a flavor flip re-evaluates this view's body and cascades
    /// new ChatTheme tokens into every descendant.
    @ObservedObject private var appearance = AppearanceSelector.shared
    @State private var previousPendingIds: Set<String> = []
    @State private var readyEpisodeTracker = ReadySessionEpisodeTracker()
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
    /// The one rendered layout read by click handling and shortcuts.
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

    // MARK: - Sizing

    private var notchReservationSize: CGSize {
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

    private var menuBarInteractionHeight: CGFloat {
        let visibleMenuHeight = max(0, viewModel.screenRect.maxY - viewModel.geometry.visibleFrame.maxY)
        let stripHeight = max(visibleMenuHeight, notchReservationSize.height)
        return min(max(stripHeight, 1), 80)
    }

    private var menuBarInteractionYRange: ClosedRange<CGFloat> {
        let maxY = viewModel.screenRect.height
        return (maxY - menuBarInteractionHeight)...maxY
    }

    // MARK: - Body

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
        let totalPillWidth = notchReservationSize.width
        return (viewModel.screenRect.width - totalPillWidth) / 2 - notchCenterGap
    }

    /// Right edge of the actual pill (accounts for expansion beyond hardware notch)
    private var pillRightEdge: CGFloat {
        let totalPillWidth = notchReservationSize.width
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

    /// Whether the strip has anything to lay out. Full-screen hiding does not
    /// participate here, because hidden layouts must stay current for direct
    /// 1–9 and 0 shortcuts.
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
                    .frame(width: viewModel.screenRect.width, height: notchReservationSize.height)
                    .allowsHitTesting(false)
                    .id(menuBarVersion)  // Force re-render when frontmost app changes or tray shifts
                    .overlay(alignment: .trailing) {
                        // Left bar: right-aligned to pill left edge.
                        HStack(spacing: pack.pillSpacing) {
                            PillBar(
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
                            PillBar(
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

            // Decorative shape behind a physical notch. External displays do
            // not render it, and the shape never accepts a click.
            if shouldRenderNotchIndicator {
                NotchShape(
                    topCornerRadius: pillCornerRadii.top,
                    bottomCornerRadius: pillCornerRadii.bottom
                )
                .fill(Color.black)
                .frame(
                    width: notchReservationSize.width,
                    height: notchReservationSize.height
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
                .opacity(pillsAreVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: pillsAreVisible)
            }

        }
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
            // Bootstrap the only pill-strip view in the app.
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

    // MARK: - Event Handlers

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
