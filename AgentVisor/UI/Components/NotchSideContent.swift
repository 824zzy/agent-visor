//
//  NotchSideContent.swift
//  AgentVisor
//
//  Session pill bars that flank the hardware notch in the menu bar.
//  Both left and right bars render the same pill content (project name +
//  status dot). PillBarCoordinator splits sessions across the two sides
//  based on the safe widths reported by NotchView (which accounts for
//  app menu items on the left and system tray icons on the right).
//

import AppKit
import AgentVisorCore
import Combine
import os.log
import SwiftUI

enum MenuBarPillMetrics {
    static let height: CGFloat = 24
    static let sessionFontSize: CGFloat = 11
    static let usageFontSize: CGFloat = 10.5
    static let horizontalPadding: CGFloat = 7
    static let statusDotDiameter: CGFloat = 6
}

struct PopoverWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> PopoverWindowObservingView {
        let view = PopoverWindowObservingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: PopoverWindowObservingView, context: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.reportWindowIfNeeded()
    }

    static func dismantleNSView(_ nsView: PopoverWindowObservingView, coordinator: ()) {
        nsView.clearReportedWindow()
    }
}

final class PopoverWindowObservingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    private weak var reportedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindowIfNeeded()
    }

    func reportWindowIfNeeded() {
        guard window !== reportedWindow else { return }
        reportedWindow = window
        onWindowChange?(window)
    }

    func clearReportedWindow() {
        reportedWindow = nil
        onWindowChange?(nil)
    }
}

/// Covers controls that remain direct descendants of the popover host.
/// Scroll-backed rows install their own first-mouse action surface because
/// SwiftUI inserts deeper native hit targets inside ScrollView.
@MainActor
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct FirstMouseHostingContainer<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> FirstMouseHostingView<Content> {
        let view = FirstMouseHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }

    func updateNSView(_ nsView: FirstMouseHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

@MainActor
final class SessionNavigatorKeyboardEventMonitor: ObservableObject {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SessionNavigatorKeyboard")

    var onEvent: ((SessionNavigatorKeyboardEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    func start() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let keyboardEvent = self.keyboardEvent(
                    keyCode: event.keyCode,
                    modifiers: ModifierMask.fromNSEvent(event.modifierFlags),
                    text: event.characters
                  ) else {
                return event
            }
            self.onEvent?(keyboardEvent)
            return nil
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SessionNavigatorKeyboardEventMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return monitor.handleEventTap(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.logger.error("unable to create keyboard event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let keyboardEvent = keyboardEvent(
            keyCode: keyCode,
            modifiers: ModifierMask.fromCGEvent(event.flags),
            text: text(from: event)
        ) else {
            return Unmanaged.passUnretained(event)
        }
        onEvent?(keyboardEvent)
        return nil
    }

    private func keyboardEvent(
        keyCode: UInt16,
        modifiers: ModifierMask,
        text: String?
    ) -> SessionNavigatorKeyboardEvent? {
        SessionNavigatorKeyboardInputPolicy.event(
            keyCode: keyCode,
            modifiers: modifiers,
            text: text
        )
    }

    private func text(from event: CGEvent) -> String? {
        var characters = [UniChar](repeating: 0, count: 16)
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &length,
            unicodeString: &characters
        )
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

private extension ModifierMask {
    static func fromCGEvent(_ flags: CGEventFlags) -> ModifierMask {
        var result: ModifierMask = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}

@MainActor
final class FirstMouseActionButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

struct FirstMouseActionOverlay: NSViewRepresentable {
    let action: (NSEvent.ModifierFlags) -> Void
    let onHoverChange: (Bool) -> Void

    init(
        action: @escaping (NSEvent.ModifierFlags) -> Void,
        onHoverChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.action = action
        self.onHoverChange = onHoverChange
    }

    final class Coordinator: NSObject {
        var action: (NSEvent.ModifierFlags) -> Void
        var onHoverChange: (Bool) -> Void

        init(
            action: @escaping (NSEvent.ModifierFlags) -> Void,
            onHoverChange: @escaping (Bool) -> Void
        ) {
            self.action = action
            self.onHoverChange = onHoverChange
        }

        @objc func invoke() {
            action(NSApp.currentEvent?.modifierFlags ?? [])
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, onHoverChange: onHoverChange)
    }

    func makeNSView(context: Context) -> FirstMouseActionButton {
        let button = FirstMouseActionButton(
            title: "",
            target: context.coordinator,
            action: #selector(Coordinator.invoke)
        )
        button.isBordered = false
        button.isTransparent = true
        button.focusRingType = .none
        button.setAccessibilityElement(false)
        button.onHoverChange = { [weak coordinator = context.coordinator] isHovered in
            coordinator?.onHoverChange(isHovered)
        }
        return button
    }

    func updateNSView(_ nsView: FirstMouseActionButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.onHoverChange = onHoverChange
    }

    static func dismantleNSView(_ nsView: FirstMouseActionButton, coordinator: Coordinator) {
        nsView.onHoverChange = nil
    }
}

// MARK: - Pill Frame Reporting (diagnostic)
//
// Each rendered pill publishes its actual screen-space frame via this
// PreferenceKey. NotchView aggregates them so the click handler can
// compare math vs reality at log time. Diagnostic-only — no behavior
// depends on it.

struct PillFrameReport: Equatable {
    let id: String      // session.stableId
    let label: String
    let frame: CGRect   // .global coordinate space (screen-relative)
}

struct PillFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [PillFrameReport] = []
    static func reduce(value: inout [PillFrameReport], nextValue: () -> [PillFrameReport]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Pill Button (with press flash)

private struct PillShortcutKeycap: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundColor(.black.opacity(0.8))
            .frame(width: 10, height: 12)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.88))
            )
            .frame(width: 6, height: 6)
    }
}

/// Pill-shaped, presentation-only view for a session. NOT a Button —
/// click handling lives in `NotchView.handleSideClick` which resolves
/// against a snapshot and dispatches via `dispatchHit`. The flash is
/// a derived effect of that dispatch: `PillFlashStore.shared.flashingId`
/// gates the animation, and is set on the same code path that runs
/// the navigation. Two effects, one source.
///
/// Why no Button: the host windows (`NotchPanel`, `PillsStripPanel`)
/// use `ignoresMouseEvents = true`, so SwiftUI hit-testing never
/// receives the click anyway. The earlier Button-with-action layout
/// was dead surface that created a silent failure mode where the
/// flash could regress without anyone noticing. Don't reintroduce.
struct PillButton: View {
    let session: SessionState
    let label: String
    let role: PillSurfaceRole
    let shortcutPosition: Int?

    @ObservedObject private var flashStore = PillFlashStore.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @ObservedObject private var hoverContextMenuCoordinator = PillHoverContextMenuCoordinator.shared
    @State private var hoverTimer: DispatchWorkItem?
    @State private var showPopover = false

    private var isFlashing: Bool {
        flashStore.flashingId == session.stableId
    }

    private var isRecentShortcut: Bool {
        role == .recentShortcut
    }

    private var revealedShortcutPosition: Int? {
        sessionShortcutManager.position(forStableID: session.stableId)
    }

    var body: some View {
        HStack(spacing: 3) {
            if let revealedShortcutPosition {
                PillShortcutKeycap(number: revealedShortcutPosition)
            } else {
                SessionStatusDot(
                    session: session,
                    diameter: MenuBarPillMetrics.statusDotDiameter,
                    colorScheme: .darkChrome
                )
                    .opacity(isRecentShortcut ? 0.55 : 1.0)
            }
            Text(label)
                .font(.system(size: MenuBarPillMetrics.sessionFontSize, weight: .medium))
                .foregroundColor(.white.opacity(isRecentShortcut ? 0.62 : 0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, MenuBarPillMetrics.horizontalPadding)
        .padding(.vertical, 3)
        .frame(height: MenuBarPillMetrics.height)
        .background(
            Capsule()
                .fill(isFlashing ? Color.white.opacity(0.25) : Color.black.opacity(isRecentShortcut ? 0.24 : 0.35))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isRecentShortcut ? 0.07 : 0), lineWidth: 1)
                )
        )
        .scaleEffect(isFlashing ? 0.93 : 1.0)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isFlashing)
        .onHover { hovering in
            hoverTimer?.cancel()
            if hovering {
                hoverContextMenuCoordinator.pointerEntered(session.stableId)
                guard hoverContextMenuCoordinator.canPresentHover(for: session.stableId) else {
                    showPopover = false
                    return
                }
                let work = DispatchWorkItem {
                    guard hoverContextMenuCoordinator.canPresentHover(for: session.stableId) else {
                        return
                    }
                    showPopover = true
                }
                hoverTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            } else {
                showPopover = false
                hoverContextMenuCoordinator.pointerExited(session.stableId)
            }
        }
        .onChange(of: hoverContextMenuCoordinator.dismissalRevision) { _, _ in
            hoverTimer?.cancel()
            showPopover = false
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            SessionDetailPopover(
                session: session,
                shortcutPosition: shortcutPosition,
                shortcutModifierFamily: sessionShortcutManager.family
            )
        }
    }
}

final class SessionNavigationRecencyStore: ObservableObject {
    static let shared = SessionNavigationRecencyStore()

    @Published private(set) var revision = 0
    private let defaultsKey = "sessionNavigationRecency.v1"
    private let readyAcknowledgmentDefaultsKey = "sessionReadyAcknowledgments.v1"
    private let maxEntries = 256
    private let defaults: UserDefaults
    private var pendingRecentNavigationCommits: [String: PendingPillMovement] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(_ session: SessionState, now: Date = Date()) {
        let existingReadyAcknowledgment = readyAcknowledgedAt(for: session)
        let nextReadyAcknowledgment = ReadyAttentionPolicy.acknowledgmentDateAfterNavigation(
            isReady: session.phase == .waitingForInput,
            phaseChangedAt: session.phaseChangedAt,
            existingAcknowledgedAt: existingReadyAcknowledgment,
            navigationAt: now
        )

        let defersNavigationRecency = session.phase == .idle
        if defersNavigationRecency {
            scheduleRecentNavigationCommit(for: session, navigationAt: now)
        } else {
            store(now, for: session, defaultsKey: defaultsKey)
        }

        var publishesImmediately = !defersNavigationRecency
        if nextReadyAcknowledgment != existingReadyAcknowledgment,
           let nextReadyAcknowledgment {
            store(
                nextReadyAcknowledgment,
                for: session,
                defaultsKey: readyAcknowledgmentDefaultsKey
            )
            scheduleReadyPositionRefresh(for: session)
            publishesImmediately = true
        }
        if publishesImmediately {
            revision &+= 1
        }
    }

    func date(for session: SessionState) -> Date? {
        date(for: session, defaultsKey: defaultsKey)
    }

    func readyAcknowledgedAt(for session: SessionState) -> Date? {
        date(for: session, defaultsKey: readyAcknowledgmentDefaultsKey)
    }

    private func date(for session: SessionState, defaultsKey: String) -> Date? {
        let raw = rawDates(defaultsKey: defaultsKey)
        let value = raw[session.stableId] ?? raw[session.sessionId]
        return value.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private func store(_ date: Date, for session: SessionState, defaultsKey: String) {
        var raw = rawDates(defaultsKey: defaultsKey)
        let value = date.timeIntervalSinceReferenceDate
        raw[session.stableId] = value
        raw[session.sessionId] = value

        if raw.count > maxEntries {
            raw = Dictionary(uniqueKeysWithValues: raw
                .sorted { lhs, rhs in lhs.value > rhs.value }
                .prefix(maxEntries)
                .map { ($0.key, $0.value) }
            )
        }
        defaults.set(raw, forKey: defaultsKey)
    }

    private func rawDates(defaultsKey: String) -> [String: TimeInterval] {
        defaults.dictionary(forKey: defaultsKey) as? [String: TimeInterval] ?? [:]
    }

    private func scheduleRecentNavigationCommit(
        for session: SessionState,
        navigationAt: Date
    ) {
        let key = session.sessionId
        let existing = pendingRecentNavigationCommits[key]
        let pending = PillMovementGracePolicy.pendingMove(
            existing: existing,
            navigationAt: navigationAt
        )
        pendingRecentNavigationCommits[key] = pending
        guard existing == nil else { return }

        let delay = max(0, pending.deadline.timeIntervalSince(navigationAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let pending = self.pendingRecentNavigationCommits.removeValue(forKey: key) else {
                return
            }
            self.store(pending.navigationDate, for: session, defaultsKey: self.defaultsKey)
            self.revision &+= 1
        }
    }

    private func scheduleReadyPositionRefresh(for session: SessionState) {
        guard session.phase == .waitingForInput else { return }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ReadyAttentionPolicy.defaultPositionHold
        ) { [weak self] in
            self?.revision &+= 1
        }
    }
}

// MARK: - Overflow Pill Button

/// Presentation-only +N pill. Click handling and flash routing
/// follow the same pattern as `PillButton` — see its doc.
struct OverflowPillButton: View {
    let count: Int

    @ObservedObject private var flashStore = PillFlashStore.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared

    private var isFlashing: Bool {
        flashStore.flashingId == PillFlashStore.overflowSentinel
    }

    var body: some View {
        Group {
            if sessionShortcutManager.isRevealingShortcuts {
                PillShortcutKeycap(number: 0)
            } else {
                Text("+\(count)")
                    .font(.system(size: MenuBarPillMetrics.sessionFontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
            .frame(
                width: PillBarCoordinator.overflowPillWidth(count: count),
                height: MenuBarPillMetrics.height
            )
            .background(
                Capsule()
                    .fill(isFlashing ? Color.white.opacity(0.25) : Color.black.opacity(0.25))
            )
            .scaleEffect(isFlashing ? 0.93 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isFlashing)
    }
}

struct CodexUsagePillButton: View {
    @ObservedObject private var monitor = CodexUsageMonitor.shared
    @ObservedObject private var flashStore = PillFlashStore.shared

    private struct CodexUsagePillValue: View {
        let presentation: CodexUsageWindowPresentation

        var body: some View {
            HStack(spacing: 2) {
                Text(presentation.label)
                    .foregroundColor(.white.opacity(0.55))
                Text(presentation.remainingPercent.map { "\($0)%" } ?? "--%")
                    .foregroundColor(valueColor)
            }
            .font(.system(size: MenuBarPillMetrics.usageFontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
        }

        private var valueColor: Color {
            switch presentation.tone {
            case .normal: return .white.opacity(0.8)
            case .warning: return TerminalColors.amber
            case .critical: return TerminalColors.red
            case nil: return .white.opacity(0.35)
            }
        }
    }

    private var presentation: CodexUsageGlancePresentation {
        CodexUsageGlancePolicy.presentation(for: monitor.snapshot)
    }

    private var isFlashing: Bool {
        flashStore.flashingId == PillFlashStore.usageSentinel
    }

    var body: some View {
        HStack(spacing: 4) {
            CodexUsagePillValue(presentation: presentation.fiveHour)
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 1, height: 10)
            CodexUsagePillValue(presentation: presentation.sevenDay)
        }
        .frame(
            width: CGFloat(CodexUsageGlancePolicy.fixedWidth),
            height: MenuBarPillMetrics.height
        )
        .background(
            Capsule().fill(
                isFlashing ? Color.white.opacity(0.25) : Color.black.opacity(0.3)
            )
        )
        .scaleEffect(isFlashing ? 0.93 : 1)
        .animation(
            .spring(response: 0.2, dampingFraction: 0.7),
            value: isFlashing
        )
        .accessibilityLabel(presentation.label)
    }
}

struct CodexUsagePopover: View {
    @ObservedObject private var monitor = CodexUsageMonitor.shared

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Codex Usage")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ChatTheme.primary)
                    Spacer()
                    freshness(now: context.date)
                }

                if let snapshot = monitor.snapshot {
                    if let primary = snapshot.primary {
                        windowRow(primary, fallbackTitle: "Primary limit", now: context.date)
                    }
                    if let secondary = snapshot.secondary {
                        Divider().opacity(0.4)
                        windowRow(secondary, fallbackTitle: "Secondary limit", now: context.date)
                    }
                    if let credits = snapshot.resetCreditsAvailable, credits > 0 {
                        Divider().opacity(0.4)
                        Text("\(credits) usage reset \(credits == 1 ? "credit" : "credits") available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ChatTheme.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        if monitor.isRefreshing {
                            ProgressView().controlSize(.small)
                        }
                        Text(monitor.lastError ?? "Loading Codex usage...")
                            .font(.system(size: 11))
                            .foregroundColor(ChatTheme.secondary)
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
            .background(ChatTheme.headerBg)
        }
    }

    @ViewBuilder
    private func windowRow(
        _ window: CodexUsageWindow,
        fallbackTitle: String,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(windowTitle(window, fallback: fallbackTitle))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ChatTheme.primary)
                Spacer()
                Text("\(window.remainingPercent)% left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(toneColor(window.remainingPercent))
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(toneColor(window.remainingPercent))
            if let resetsAt = window.resetsAt {
                Text("Resets \(relativeDate(resetsAt, now: now))")
                    .font(.system(size: 10))
                    .foregroundColor(ChatTheme.tertiary)
            }
        }
    }

    private func freshness(now: Date) -> some View {
        let text: String
        if monitor.lastError != nil, let observedAt = monitor.snapshot?.observedAt {
            text = "Refresh failed; updated \(relativeDate(observedAt, now: now))"
        } else if let observedAt = monitor.snapshot?.observedAt {
            text = "Updated \(relativeDate(observedAt, now: now))"
        } else if monitor.isRefreshing {
            text = "Updating"
        } else {
            text = "Unavailable"
        }
        return Text(text)
            .font(.system(size: 9.5))
            .foregroundColor(ChatTheme.tertiary)
    }

    private func windowTitle(_ window: CodexUsageWindow, fallback: String) -> String {
        switch window.windowDurationMinutes {
        case 300: return "5 hour limit"
        case 10_080: return "Weekly limit"
        case let minutes?:
            return "\(CodexUsageGlancePolicy.durationLabel(minutes: minutes) ?? fallback) limit"
        case nil:
            return fallback
        }
    }

    private func toneColor(_ remainingPercent: Int) -> Color {
        switch CodexUsageGlancePolicy.tone(remainingPercent: remainingPercent) {
        case .normal: return TerminalColors.green
        case .warning: return TerminalColors.amber
        case .critical: return TerminalColors.red
        }
    }

    private func relativeDate(_ date: Date, now: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

struct SessionNavigatorPopover: View {
    let snapshot: SidebarSessionListSnapshot
    let allSessionsSnapshot: SidebarSessionListSnapshot
    let totalSessionCount: Int
    let onSelect: (SessionState, PillClickModifierIntent) -> Void
    let onOpenAgentVisor: (SessionState) -> Void
    let onOpenOriginal: (SessionState) -> Void
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    @State private var isOpenBrowserFooterHovered = false
    @State private var isSettingsFooterHovered = false
    @State private var searchQuery = ""
    @State private var keyboardCursorSessionID: String?
    @StateObject private var keyboardMonitor = SessionNavigatorKeyboardEventMonitor()
    @ObservedObject private var titleStore = CursorSessionTitleStore.shared
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            VStack(spacing: 0) {
                header
                searchField
                Divider().opacity(0.45)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if displayedSessionIDs.isEmpty {
                                Text(searchSelection.isSearching
                                    ? "No matching sessions"
                                    : "No recent sessions")
                                    .font(.system(size: 12))
                                    .foregroundColor(ChatTheme.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 18)
                            } else if searchSelection.isSearching {
                                navigatorSearchResults(now: context.date)
                            } else {
                                ForEach(snapshot.groupedRows, id: \.id) { group in
                                    navigatorSection(group, now: context.date)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: keyboardCursorSessionID) { _, sessionID in
                        guard let sessionID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(sessionID, anchor: .center)
                        }
                    }
                    .onChange(of: searchQuery) { _, _ in
                        keyboardCursorSessionID = displayedSessionIDs.first
                    }
                }
                .frame(maxHeight: CGFloat(SessionNavigatorPopoverLayoutPolicy.maximumHeight))
                Divider().opacity(0.45)
                footer
            }
            .frame(width: popoverWidth)
            .background(ChatTheme.headerBg)
            .onAppear {
                keyboardMonitor.onEvent = handleKeyboardEvent
                keyboardMonitor.start()
                handleKeyboardEvent(.opened)
            }
            .onDisappear {
                keyboardMonitor.stop()
                keyboardMonitor.onEvent = nil
                searchQuery = ""
            }
        }
    }

    private var popoverWidth: CGFloat {
        let visibleScreenWidth = NSScreen.main.map { Double($0.visibleFrame.width) }
        return CGFloat(SessionNavigatorPopoverLayoutPolicy.width(forVisibleScreenWidth: visibleScreenWidth))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(searchSelection.isSearching
                    ? SessionNavigatorSummaryPolicy.searchTitle
                    : SessionNavigatorSummaryPolicy.overflowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                Spacer()
                Text("\(displayedSessionIDs.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(ChatTheme.tertiary)
            }
            Text(searchSelection.isSearching
                ? SessionNavigatorSummaryPolicy.searchHeaderText(
                    matchCount: displayedSessionIDs.count,
                    totalSessionCount: totalSessionCount
                )
                : SessionNavigatorSummaryPolicy.headerText(for: navigatorSummary))
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
            TextField(
                SessionNavigatorSummaryPolicy.searchPlaceholder(
                    totalSessionCount: totalSessionCount
                ),
                text: $searchQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(ChatTheme.primary)
            .focused($isSearchFocused)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(ChatTheme.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.gray.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    isSearchFocused ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var searchSelection: SessionNavigatorSearchSelection {
        SessionNavigatorSearchPolicy.select(
            overflowSessionIDs: snapshot.flatRows.map(\.sessionId),
            allCandidates: allSessionsSnapshot.flatRows.compactMap { row in
                guard let session = allSessionsSnapshot.sessionsById[row.sessionId] else {
                    return nil
                }
                return SessionNavigatorSearchCandidate(
                    sessionID: session.sessionId,
                    title: SessionRowTitleResolver.title(for: session, titleStore: titleStore),
                    project: row.projectName ?? session.bestProjectName,
                    source: sourceName(for: session),
                    owner: ownerName(for: session),
                    path: session.cwd,
                    sortDate: SidebarRecency.sortDate(
                        lastActivityDate: session.lastActivityDate,
                        lastUserMessageDate: session.lastUserMessageDate,
                        lastActivity: session.lastActivity
                    )
                )
            },
            query: searchQuery
        )
    }

    private var displayedSessionIDs: [String] {
        searchSelection.orderedSessionIDs
    }

    private var navigatorSummary: SessionNavigatorSummary {
        var counts: [SidebarStateSectionKind: Int] = [:]
        for group in snapshot.groupedRows {
            switch group.kind {
            case .needsAttention:
                counts[.needsAttention] = group.rows.count
            case .ready:
                counts[.ready] = group.rows.count
            case .working:
                counts[.working] = group.rows.count
            case .recent:
                counts[.recent] = group.rows.count
            case .project, .other:
                break
            }
        }
        return SessionNavigatorSummaryPolicy.summary(sectionCounts: counts)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button(action: onOpenMainWindow) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11, weight: .medium))
                    Text(SessionNavigatorSummaryPolicy.openBrowserLabel)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(ChatTheme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOpenBrowserFooterHovered ? Color.gray.opacity(0.10) : Color.clear)
            )
            .onHover { isOpenBrowserFooterHovered = $0 }

            Divider()
                .frame(height: 20)

            Button(action: onOpenSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                    Text(SessionNavigatorSummaryPolicy.settingsLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(ChatTheme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSettingsFooterHovered ? Color.gray.opacity(0.10) : Color.clear)
            )
            .onHover { isSettingsFooterHovered = $0 }
            .accessibilityLabel(SessionNavigatorSummaryPolicy.settingsLabel)
        }
    }

    @ViewBuilder
    private func navigatorSection(_ group: SidebarFlatRowGroup, now: Date) -> some View {
        Text(group.displayTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(ChatTheme.tertiary)
            .padding(.horizontal, 4)
            .padding(.top, group.kind == .needsAttention ? 0 : 8)
            .padding(.bottom, 2)
        ForEach(group.rows, id: \.id) { row in
            if let session = snapshot.sessionsById[row.sessionId] {
                SessionNavigatorRow(
                    session: session,
                    projectName: row.projectName,
                    now: now,
                    isKeyboardSelected: session.sessionId == keyboardCursorSessionID,
                    onSelect: onSelect,
                    onOpenAgentVisor: onOpenAgentVisor,
                    onOpenOriginal: onOpenOriginal
                )
                .id(row.sessionId)
            }
        }
    }

    @ViewBuilder
    private func navigatorSearchResults(now: Date) -> some View {
        ForEach(displayedSessionIDs, id: \.self) { sessionID in
            if let session = allSessionsSnapshot.sessionsById[sessionID] {
                SessionNavigatorRow(
                    session: session,
                    projectName: projectNamesBySessionID[sessionID],
                    now: now,
                    isKeyboardSelected: sessionID == keyboardCursorSessionID,
                    onSelect: onSelect,
                    onOpenAgentVisor: onOpenAgentVisor,
                    onOpenOriginal: onOpenOriginal
                )
                .id(sessionID)
            }
        }
    }

    private var projectNamesBySessionID: [String: String] {
        allSessionsSnapshot.flatRows.reduce(into: [:]) { result, row in
            if let projectName = row.projectName {
                result[row.sessionId] = projectName
            }
        }
    }

    private func sourceName(for session: SessionState) -> String {
        AgentRegistry.provider(for: session.agentID)?.displayName
            ?? session.agentID.rawValue
    }

    private func ownerName(for session: SessionState) -> String {
        if session.origin == .visorSpawned { return "Agent Visor" }
        if session.origin == .cursorObserved { return "Cursor" }
        if session.agentID == .codex, session.tty == nil { return "Codex" }
        if let host = SessionHostDisplayPolicy.displayHost(
            agentID: session.agentID,
            terminalHost: session.terminalHost
        ), host != .unknown {
            return HostMetadata.metadata(for: host).displayName
        }
        return sourceName(for: session)
    }

    private func handleKeyboardEvent(_ event: SessionNavigatorKeyboardEvent) {
        let decision = SessionNavigatorKeyboardPolicy.reduce(
            currentCursorID: keyboardCursorSessionID,
            visibleSessionIDs: displayedSessionIDs,
            query: searchQuery,
            event: event
        )
        keyboardCursorSessionID = decision.cursorSessionID
        searchQuery = decision.query

        switch decision.action {
        case .none:
            break
        case .open(let sessionID, let modifierIntent):
            guard let session = allSessionsSnapshot.sessionsById[sessionID]
                    ?? snapshot.sessionsById[sessionID] else { return }
            onSelect(session, modifierIntent)
        case .focusSearch:
            isSearchFocused = true
        case .dismiss:
            onDismiss()
        }
    }
}

struct SessionNavigatorRow: View {
    let session: SessionState
    let projectName: String?
    let now: Date
    let isKeyboardSelected: Bool
    let onSelect: (SessionState, PillClickModifierIntent) -> Void
    let onOpenAgentVisor: (SessionState) -> Void
    let onOpenOriginal: (SessionState) -> Void

    @State private var isHovered = false
    @ObservedObject private var titleStore = CursorSessionTitleStore.shared

    private var rowTitle: String {
        SessionRowTitleResolver.title(for: session, titleStore: titleStore)
    }

    private var relativeTimestampLabel: String? {
        let date = SidebarRecency.sortDate(
            lastActivityDate: session.lastActivityDate,
            lastUserMessageDate: session.lastUserMessageDate,
            lastActivity: session.lastActivity
        )
        return RelativeTimestampFormatter.format(since: date, now: now)
    }

    private var menuModel: PillClickMenuModel {
        PillClickMenuModel.session(
            agentID: session.agentID,
            ownership: SessionOpenRouter.ownership(for: session)
        )
    }

    var body: some View {
        Button(action: selectSessionFromSwiftUI) {
            HStack(alignment: .center, spacing: 8) {
                SessionStatusDot(session: session, diameter: 7, colorScheme: .adaptive)
                AgentStatusBadge(session: session, pointSize: 18)
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    metadataLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isKeyboardSelected
                        ? Color.accentColor.opacity(0.14)
                        : (isHovered ? Color.gray.opacity(0.10) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isKeyboardSelected ? Color.accentColor.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .overlay {
            FirstMouseActionOverlay(
                action: { modifierFlags in
                    selectSession(modifierFlags: modifierFlags)
                },
                onHoverChange: { isHovered = $0 }
            )
        }
        .contextMenu {
            Button(menuModel.openAgentVisorTitle) {
                onOpenAgentVisor(session)
            }
            if menuModel.canOpenOriginal {
                Button(menuModel.openOriginalTitle) {
                    onOpenOriginal(session)
                }
            }
        }
        .accessibilityAddTraits(isKeyboardSelected ? [.isSelected] : [])
    }

    private func selectSessionFromSwiftUI() {
        selectSession(modifierFlags: NSApp.currentEvent?.modifierFlags ?? [])
    }

    private func selectSession(modifierFlags: NSEvent.ModifierFlags) {
        let optionHeld = modifierFlags.contains(.option)
        onSelect(session, optionHeld ? .forceAgentVisor : .standard)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(rowTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(ChatTheme.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if let relativeTimestampLabel {
                Text(relativeTimestampLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(ChatTheme.tertiary)
            }
        }
    }

    private var metadataLine: some View {
        HStack(spacing: 5) {
            SourceChip(agentID: session.agentID, terminalHost: session.terminalHost)
            if let projectName, !projectName.isEmpty {
                Text(projectName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(ChatTheme.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Catppuccin.surface1.opacity(0.7))
                    )
            }
            Text(statusFreshnessText)
                .font(.system(size: 10))
                .foregroundColor(ChatTheme.tertiary)
                .lineLimit(1)
        }
    }

    private var statusFreshnessText: String {
        let status = statusLabel
        if session.phase == .idle {
            return "\(status) · inferred"
        }
        let observedAt = session.phaseObservedAt ?? session.phaseChangedAt
        let elapsed = max(0, now.timeIntervalSince(observedAt))
        if elapsed < 60 {
            return "\(status) · synced \(Int(elapsed))s ago"
        }
        if let relative = RelativeTimestampFormatter.format(elapsed: elapsed) {
            return "\(status) · synced \(relative) ago"
        }
        return "\(status) · synced"
    }

    private var statusLabel: String {
        if session.phase.isWaitingForApproval {
            guard let toolName = PendingActionPresentation.contextualToolName(session.pendingToolName) else {
                return "Needs attention"
            }
            return toolName == "AskUserQuestion"
                ? "Needs your input"
                : "Needs approval: \(toolName)"
        }
        switch session.phase {
        case .processing: return "Working"
        case .compacting: return "Compacting"
        case .waitingForInput: return "Ready"
        case .idle: return "Recent"
        case .ended: return "Ended"
        case .waitingForApproval: return "Needs attention"
        }
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

// MARK: - Visible Pill

/// One renderable pill: a session paired with its display label.
struct VisiblePill: Identifiable {
    let session: SessionState
    let label: String
    let role: PillSurfaceRole
    let shortcutPosition: Int?
    var id: String { session.stableId }
}

// MARK: - Pill Bar

struct OverflowPopoverConfiguration {
    let isPresented: Binding<Bool>
    let snapshot: SidebarSessionListSnapshot
    let allSessionsSnapshot: SidebarSessionListSnapshot
    let totalSessionCount: Int
    let onWindowChange: (NSWindow?) -> Void
    let onSelect: (SessionState, PillClickModifierIntent) -> Void
    let onOpenAgentVisor: (SessionState) -> Void
    let onOpenOriginal: (SessionState) -> Void
    let onOpenMainWindow: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void
}

struct UsagePopoverConfiguration {
    let isPresented: Binding<Bool>
    let onWindowChange: (NSWindow?) -> Void
}

/// Renders a row of session pills on one side of the notch. The caller
/// (`PillBarCoordinator.pack`) decides which pills go on which side and
/// where the +N overflow slot lives. This view just renders what it's
/// handed, so packing math is testable in `AgentVisorCore`.
struct NotchPillBar: View {
    enum Side { case left, right }

    let side: Side
    let visiblePills: [VisiblePill]
    /// Count of sessions not visible on EITHER bar. Non-zero means this
    /// side owns the +N slot. Zero means render no overflow pill here.
    let overflowCount: Int
    let maxWidth: CGFloat
    let overflowPopover: OverflowPopoverConfiguration?
    let usagePopover: UsagePopoverConfiguration?
    // No `onOverflowTap` — the overflow pill is presentation-only,
    // same as the session pills. The `.overflow` hit case in
    // `NotchView.dispatchHit` toggles the Sessions popover state.

    var body: some View {
        if visiblePills.isEmpty && overflowCount == 0 && usagePopover == nil {
            EmptyView()
        } else {
            HStack(spacing: PillBarCoordinator.pillSpacing) {
                ForEach(visiblePills) { pill in
                    PillButton(
                        session: pill.session,
                        label: pill.label,
                        role: pill.role,
                        shortcutPosition: pill.shortcutPosition
                    )
                        // Diagnostic: report each pill's actual rendered
                        // global frame so NotchView's click handler can
                        // compare math-width vs SwiftUI-width.
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: PillFramesPreferenceKey.self,
                                    value: [PillFrameReport(
                                        id: pill.session.stableId,
                                        label: pill.label,
                                        frame: geo.frame(in: .global)
                                    )]
                                )
                            }
                        )
                }

                if overflowCount > 0 {
                    if let overflowPopover {
                        OverflowPillButton(count: overflowCount)
                            .popover(isPresented: overflowPopover.isPresented, arrowEdge: .top) {
                                FirstMouseHostingContainer(
                                    content: SessionNavigatorPopover(
                                        snapshot: overflowPopover.snapshot,
                                        allSessionsSnapshot: overflowPopover.allSessionsSnapshot,
                                        totalSessionCount: overflowPopover.totalSessionCount,
                                        onSelect: overflowPopover.onSelect,
                                        onOpenAgentVisor: overflowPopover.onOpenAgentVisor,
                                        onOpenOriginal: overflowPopover.onOpenOriginal,
                                        onOpenMainWindow: overflowPopover.onOpenMainWindow,
                                        onOpenSettings: overflowPopover.onOpenSettings,
                                        onDismiss: overflowPopover.onDismiss
                                    )
                                )
                                .background(
                                    PopoverWindowReader(onWindowChange: overflowPopover.onWindowChange)
                                )
                                .onDisappear {
                                    overflowPopover.onWindowChange(nil)
                                }
                            }
                    } else {
                        OverflowPillButton(count: overflowCount)
                    }
                }


                if side == .right, let usagePopover {
                    CodexUsagePillButton()
                        .popover(isPresented: usagePopover.isPresented, arrowEdge: .top) {
                            CodexUsagePopover()
                                .background(
                                    PopoverWindowReader(onWindowChange: usagePopover.onWindowChange)
                                )
                                .onDisappear {
                                    usagePopover.onWindowChange(nil)
                                }
                        }
                }
            }
            .padding(
                side == .left ? .trailing : .leading,
                PillBarCoordinator.edgePadding
            )
            .frame(
                maxWidth: maxWidth,
                alignment: side == .left ? .trailing : .leading
            )
        }
    }
}

// MARK: - Pill Bar Coordinator

/// Splits sessions across the left and right pill bars, picking which
/// side hosts the +N overflow slot. Pure-Swift packing logic lives in
/// `AgentVisorCore.PillBarPacker` so it's covered by unit tests; this
/// coordinator just bridges from `[SessionState]` to the packer's
/// abstract `Candidate` model and back.
enum PillBarCoordinator {
    static let pillSpacing: CGFloat = 4
    /// Padding between the outermost pill and the edge of the auxiliary
    /// region (trailing for left bar, leading for right bar).
    static let edgePadding: CGFloat = 8

    struct Pack {
        let leftPills: [VisiblePill]
        let rightPills: [VisiblePill]
        let overflowSessions: [SessionState]
        let leftOverflowCount: Int
        let rightOverflowCount: Int
        let showsUsagePill: Bool
    }

    static func pack(
        sessions: [SessionState],
        leftMax: CGFloat,
        rightMax: CGFloat,
        includeUsage: Bool = false
    ) -> Pack {
        let selection = selectPillSurface(sessions: sessions)
        let visibleIds = selection.orderedVisibleIds
        var sessionsByStableId: [String: SessionState] = [:]
        for session in sessions {
            sessionsByStableId[session.stableId] = session
        }

        // Subtract the per-side edge padding from the usable region so
        // the packer's budget matches what the HStack actually has after
        // padding. (Without this, the rightmost pill would press against
        // the system tray boundary by exactly `edgePadding` pixels.)
        let leftUsable = max(0, leftMax - edgePadding)
        let rightReservation = CodexUsageGlancePolicy.reserveRightSide(
            usableWidth: Double(max(0, rightMax - edgePadding)),
            spacing: Double(pillSpacing),
            enabled: includeUsage
        )
        let rightUsable = CGFloat(rightReservation.sessionUsableWidth)

        guard !visibleIds.isEmpty else {
            return Pack(
                leftPills: [],
                rightPills: [],
                overflowSessions: [],
                leftOverflowCount: 0,
                rightOverflowCount: 0,
                showsUsagePill: rightReservation.showsUsage
            )
        }

        struct Entry {
            let session: SessionState
            let role: PillSurfaceRole
            let label: String
            let shortLabel: String
            let candidate: PillBarPacker.Candidate
        }

        func makeEntries(_ pairs: [(SessionState, PillSurfaceRole)]) -> [Entry] {
            pairs.enumerated().map { idx, pair in
                let (session, role) = pair
                let label = sessionLabel(session)
                let width = pillWidth(forLabel: label)
                // Every pill provides a shorter render label so the packer
                // can compress lower-priority suffixes before hiding sessions
                // behind +N. The first pill keeps the older aggressive fallback:
                // if the left bar is very narrow, showing one recognizable
                // highest-priority pill beats an empty side.
                let shortLabel = idx == 0 ? aggressivelyShortLabel(from: label) : compactLabel(from: label)
                let minimumWidth: CGFloat? = shortLabel == label ? nil : pillWidth(forLabel: shortLabel)
                return Entry(
                    session: session,
                    role: role,
                    label: label,
                    shortLabel: shortLabel,
                    candidate: PillBarPacker.Candidate(
                        id: session.stableId,
                        pillWidth: width,
                        minimumWidth: minimumWidth
                    )
                )
            }
        }

        func packEntries(_ entries: [Entry]) -> PillBarPacker.PackResult {
            PillBarPacker.pack(
                candidates: entries.map(\.candidate),
                leftMax: leftUsable,
                rightMax: rightUsable,
                pillSpacing: pillSpacing,
                overflowPillWidthFor: { count in overflowPillWidth(count: count) }
            )
        }

        let activeIdSet = Set(selection.orderedActiveIds)
        let orderedPairs = selection.orderedVisibleIds.compactMap { id -> (SessionState, PillSurfaceRole)? in
            guard let session = sessionsByStableId[id] else { return nil }
            return (session, activeIdSet.contains(id) ? .active : .recentShortcut)
        }

        let entries = makeEntries(orderedPairs)
        let result = packEntries(entries)

        // Build a lookup of (session, full-label) and substitute the
        // short label for any IDs the packer rebalanced.
        let byEntry = Dictionary(uniqueKeysWithValues: entries.map { ($0.candidate.id, $0) })
        let shortcutSnapshot = GlobalSessionShortcutSnapshot(
            leftVisibleSessionIDs: result.leftVisibleIds,
            rightVisibleSessionIDs: result.rightVisibleIds
        )
        let materialize: (String) -> VisiblePill? = { id in
            guard let entry = byEntry[id] else { return nil }
            let label = result.shortenedIds.contains(id) ? entry.shortLabel : entry.label
            return VisiblePill(
                session: entry.session,
                label: label,
                role: entry.role,
                shortcutPosition: shortcutSnapshot.displayPosition(forSessionID: id)
            )
        }
        let leftPills = result.leftVisibleIds.compactMap(materialize)
        let rightPills = result.rightVisibleIds.compactMap(materialize)

        let overflowSessions: [SessionState] = result.hiddenIds.compactMap {
            byEntry[$0]?.session
        }
        let hiddenVisibleCount = overflowSessions.count
        let leftOverflow = result.overflowSide == .left ? hiddenVisibleCount : 0
        let rightOverflow = result.overflowSide == .right ? hiddenVisibleCount : 0

        return Pack(
            leftPills: leftPills,
            rightPills: rightPills,
            overflowSessions: overflowSessions,
            leftOverflowCount: leftOverflow,
            rightOverflowCount: rightOverflow,
            showsUsagePill: rightReservation.showsUsage
        )
    }

    static func activePillCount(sessions: [SessionState]) -> Int {
        selectPillSurface(sessions: sessions).orderedActiveIds.count
    }

    // MARK: - Width Estimation

    /// Width of a session pill rendered with the given label. Must stay in
    /// sync with `PillButton`'s layout (dot + label + horizontal padding).
    static func pillWidth(forLabel label: String) -> CGFloat {
        let labelWidth = textWidth(label)
        return labelWidth
            + (2 * MenuBarPillMetrics.horizontalPadding)
            + MenuBarPillMetrics.statusDotDiameter
            + 3
    }

    /// Width of the "+N" overflow pill for a given count.
    static func overflowPillWidth(count: Int) -> CGFloat {
        let labelWidth = textWidth("+\(count)", weight: .medium)
        return labelWidth + (2 * MenuBarPillMetrics.horizontalPadding)
    }

    static func textWidth(_ text: String, weight: NSFont.Weight = .medium) -> CGFloat {
        let font = NSFont.systemFont(
            ofSize: MenuBarPillMetrics.sessionFontSize,
            weight: weight
        )
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attrs).width)
    }

    /// Active tool context label showing what the session is doing right now
    static func sessionLabel(_ session: SessionState) -> String {
        // Pending approval: show tool name
        if let toolName = PendingActionPresentation.contextualToolName(session.pendingToolName) {
            return truncate(MCPToolFormatter.formatToolName(toolName))
        }

        // Active tool: show tool + context (only when actually processing)
        if session.phase.isActive,
           let currentTool = session.toolTracker.inProgress.values
            .sorted(by: { $0.startTime > $1.startTime }).first {
            let name = MCPToolFormatter.formatToolName(currentTool.name)
            if let msg = session.lastMessage, let lastTool = session.lastToolName,
               MCPToolFormatter.formatToolName(lastTool) == name {
                return truncate("\(name) \(msg)")
            }
            return truncate(name)
        }

        // Source session name takes priority over stale tool context.
        // Showing "Bash" for every idle session defeats the purpose.
        if let name = session.sessionName {
            return truncate(name)
        }

        // Last completed tool (only when there is no session name)
        if let toolName = session.lastToolName {
            let name = MCPToolFormatter.formatToolName(toolName)
            if let msg = session.lastMessage {
                return truncate("\(name) \(msg)")
            }
            return truncate(name)
        }
        if let msg = session.lastMessage {
            return truncate(msg)
        }
        return truncate(session.bestProjectName)
    }

    private static func truncate(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 22 {
            return String(cleaned.prefix(20)) + "..."
        }
        return cleaned
    }

    /// Aggressive truncation for the no-empty-side rebalance. When the
    /// left bar is too narrow for a normal-length pill, the packer can
    /// retry with this shorter form so the user still sees a pill on
    /// each side. Keeps just enough characters to identify the session
    /// at a glance ("claud..." beats no pill at all).
    static func aggressivelyShortLabel(from label: String) -> String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 6 {
            return String(cleaned.prefix(6)) + "..."
        }
        return cleaned
    }

    static func compactLabel(from label: String) -> String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 14 {
            return String(cleaned.prefix(12)) + "..."
        }
        return cleaned
    }

    private static func selectPillSurface(sessions: [SessionState]) -> PillSurfaceSelection {
        let now = Date()
        let candidates = sessions.map { session in
            PillSurfaceCandidate(
                id: session.stableId,
                phase: pillSurfacePhase(for: session.phase),
                sortDate: SessionPriority.sortDate(for: session),
                statusDate: session.phaseChangedAt,
                navigationDate: SessionNavigationRecencyStore.shared.date(for: session),
                isHidden: false,
                isTitleless: isTitleless(session),
                readyAcknowledgedAt: SessionNavigationRecencyStore.shared.readyAcknowledgedAt(for: session)
            )
        }
        return PillSurfacePolicy.select(candidates: candidates, now: now)
    }

    private static func isTitleless(_ session: SessionState) -> Bool {
        let isTitleless = SidebarTitlelessPolicy.shouldHide(
            isSelected: false,
            needsAttention: session.phase.isWaitingForApproval,
            agentID: session.agentID,
            terminalHost: session.terminalHost,
            hasTTY: session.tty != nil,
            hasSessionName: !(session.sessionName ?? "").isEmpty,
            hasFirstUserMessage: !(session.conversationInfo.firstUserMessage ?? "").isEmpty,
            hasChatItems: !session.chatItems.isEmpty,
            hasLastActivityDate: session.conversationInfo.lastActivityDate != nil
        )
        return SidebarSessionVisibilityPolicy.shouldHideInPills(
            isEnded: false,
            isTitleless: isTitleless,
            isIdle: false
        )
    }

    private static func pillSurfacePhase(for phase: SessionPhase) -> PillSurfacePhase {
        switch phase {
        case .waitingForApproval:
            return .needsAttention
        case .waitingForInput:
            return .ready
        case .processing, .compacting:
            return .working
        case .idle:
            return .idle
        case .ended:
            return .ended
        }
    }
}

// MARK: - Session Priority Helper

/// Shared logic for session sorting and priority
enum SessionPriority {
    /// Returns the highest-priority session for display and navigation
    static func prioritySession(from sessions: [SessionState]) -> SessionState? {
        sortedByPriority(sessions).first
    }

    /// Sort sessions by priority (same order as dots are rendered).
    /// Within the same priority tier, most recently active sessions come first.
    static func sortedByPriority(_ sessions: [SessionState]) -> [SessionState] {
        sessions.sorted { a, b in
            let da = sortDate(for: a)
            let db = sortDate(for: b)
            let aPri = phasePriority(a.phase)
            let bPri = phasePriority(b.phase)
            return SidebarRecency.precedes(
                lhsDate: da,
                rhsDate: db,
                lhsPhasePriority: aPri,
                rhsPhasePriority: bPri,
                lhsID: a.sessionId,
                rhsID: b.sessionId
            )
        }
    }

    static func sortDate(for session: SessionState) -> Date {
        SidebarRecency.sortDate(
            lastActivityDate: session.lastActivityDate,
            lastUserMessageDate: session.lastUserMessageDate,
            lastActivity: session.lastActivity
        )
    }

    static func phasePriority(_ phase: SessionPhase) -> Int {
        return phase.displayPriority
    }
}
