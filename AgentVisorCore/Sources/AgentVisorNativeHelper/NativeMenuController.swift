import AgentVisorCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

private final class NativePillButton: NSButton {
    var normalBackgroundColor = NSColor.black.withAlphaComponent(0.35)
    var onActivate: ((NSEvent.ModifierFlags) -> Void)?
    var onAccessibilityActivate: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let onAccessibilityActivate else { return super.accessibilityPerformPress() }
        onAccessibilityActivate()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = (
            flag ? NSColor.white.withAlphaComponent(0.25) : normalBackgroundColor
        ).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onActivate?(event.modifierFlags)
    }

    func flash() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.layer?.backgroundColor = self?.normalBackgroundColor.cgColor
        }
    }
}

private final class NativePillPanel: NSPanel {
    let pillButton = NativePillButton(frame: .zero)
    var renderKey = ""
    var renderedTitle = ""

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        pillButton.isBordered = false
        pillButton.focusRingType = .none
        pillButton.alignment = .center
        pillButton.imageScaling = .scaleNone
        pillButton.imagePosition = .imageLeading
        pillButton.imageHugsTitle = true
        pillButton.setAccessibilityElement(false)
        pillButton.wantsLayer = true
        pillButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        pillButton.layer?.cornerRadius = 12
        pillButton.layer?.masksToBounds = true
        contentView = pillButton
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func isAccessibilityElement() -> Bool { false }

    func place(frame: CGRect) {
        setFrame(frame, display: true)
        pillButton.frame = CGRect(origin: .zero, size: frame.size)
        pillButton.layer?.cornerRadius = frame.height / 2
        orderFrontRegardless()
    }
}

private struct NativeMenuSessionDetailView: View {
    let presentation: NativeMenuSessionDetailPresentation

    @Environment(\.colorScheme) private var colorScheme

    private var statusTint: Color {
        switch (presentation.phase, colorScheme) {
        case (.needsYou, .light): return Color(red: 0.874, green: 0.557, blue: 0.114)
        case (.ready, .light): return Color(red: 0.251, green: 0.627, blue: 0.169)
        case (.working, .light): return Color(red: 0.996, green: 0.392, blue: 0.043)
        case (.history, .light): return Color(red: 0.549, green: 0.561, blue: 0.631)
        case (.needsYou, .dark): return Color(red: 0.957, green: 0.757, blue: 0.078)
        case (.ready, .dark): return Color(red: 0.651, green: 0.890, blue: 0.631)
        case (.working, .dark): return Color(red: 0.851, green: 0.471, blue: 0.341)
        case (.history, .dark): return Color(red: 0.498, green: 0.518, blue: 0.612)
        @unknown default: return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var contextTint: Color {
        let percentage = presentation.context?.percentage ?? 0
        switch (percentage, colorScheme) {
        case (..<75, .light): return Color(red: 0.251, green: 0.627, blue: 0.169)
        case (..<90, .light): return Color(red: 0.874, green: 0.557, blue: 0.114)
        case (_, .light): return Color(red: 0.824, green: 0.059, blue: 0.224)
        case (..<75, .dark): return Color(red: 0.651, green: 0.890, blue: 0.631)
        case (..<90, .dark): return Color(red: 0.976, green: 0.886, blue: 0.686)
        case (_, .dark): return Color(red: 0.953, green: 0.545, blue: 0.659)
        @unknown default: return statusTint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(presentation.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(2)
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 6, height: 6)
                    Text(presentation.status)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(statusTint.opacity(0.14)))
                .fixedSize()
            }
            Divider().overlay(Color(nsColor: .separatorColor))
            ForEach(presentation.rows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 62, alignment: .leading)
                    Text(row.value)
                        .font(.system(
                            size: 10,
                            weight: .medium,
                            design: row.label == "Project" ? .monospaced : .default
                        ))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .lineLimit(row.label == "Access" ? 2 : 1)
                        .truncationMode(row.label == "Project" ? .middle : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let context = presentation.context {
                contextRow(context)
            }
            if let shortcutLabel = presentation.shortcutLabel {
                Divider().overlay(Color(nsColor: .separatorColor))
                HStack(spacing: 7) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    Text(shortcutLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Text("Open directly")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .labelColor).opacity(colorScheme == .dark ? 0.40 : 0.35),
                    lineWidth: 1
                )
        )
    }

    private func contextRow(_ context: SessionHoverContextPresentation) -> some View {
        HStack(spacing: 8) {
            Text("Context")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 62, alignment: .leading)
            Text("\(context.usedLabel) / \(context.windowLabel)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(contextTint)
                        .frame(width: max(2, geometry.size.width * CGFloat(context.percentage) / 100))
                }
            }
            .frame(height: 6)
            Text("\(context.percentage)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(contextTint)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct NativeMenuUsageView: View {
    let glances: [NativeHelperUsageGlance]

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(glances.enumerated()), id: \.element.id) { index, glance in
                    if index > 0 { Divider().opacity(0.4) }
                    provider(glance, now: context.date)
                }
            }
            .padding(14)
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func provider(_ glance: NativeHelperUsageGlance, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(glance.heading ?? "Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                Spacer()
                if let observedAt = date(glance.observedAt) {
                    Text("\(glance.stale == true ? "Refresh failed; updated" : "Updated") \(relative(observedAt, now: now))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            let windows = glance.windows ?? []
            if windows.isEmpty {
                Text(glance.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    if index > 0 { Divider().opacity(0.4) }
                    windowRow(window, now: now)
                }
            }
            if let credits = glance.resetCreditsAvailable, credits > 0 {
                Divider().opacity(0.4)
                Text("\(credits) usage reset \(credits == 1 ? "credit" : "credits") available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
    }

    private func windowRow(
        _ window: NativeHelperUsageWindow,
        now: Date
    ) -> some View {
        let title = window.title
        let resetText = date(window.resetsAt).map {
            "Resets \(relative($0, now: now))"
        }
        let resetLabel = resetText.map { ", \($0.lowercased())" } ?? ""
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(window.remainingPercent)% left")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tone(window.tone ?? .normal))
            }
            ProgressView(value: Double(window.remainingPercent), total: 100)
                .tint(tone(window.tone ?? .normal))
            if let resetText {
                Text(resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(title), \(window.remainingPercent) percent remaining\(resetLabel)"
        )
    }

    private func tone(_ tone: NativeHelperUsageTone) -> Color {
        switch tone {
        case .critical: return Color(nsColor: .systemRed)
        case .warning: return Color(nsColor: .systemYellow)
        case .normal: return Color(nsColor: .secondaryLabelColor)
        }
    }

    private func date(_ value: String?) -> Date? {
        value.flatMap { try? Date($0, strategy: .iso8601) }
    }

    private func relative(_ date: Date, now: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }
}

private struct NativeMenuPanelHitSnapshot {
    let orderedSessionIDs: [String]
    let sessionFrames: [String: CGRect]
    let overflowFrame: CGRect?
    let orderedUsageIDs: [String]
    let usageFrames: [String: CGRect]
}

@MainActor
final class NativeMenuController: NSObject {
    var emit: (NativeHelperEvent) -> Void = { _ in }

    private let stableItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessionPanels: [String: NativePillPanel] = [:]
    private var sessionPresentations: [String: NativeHelperPill] = [:]
    private var navigatorPills: [NativeHelperPill] = []
    private var displayedSessionIDs: [String] = []
    private var visibleSessionIDs = Set<String>()
    private var readyAttention = NativeMenuReadyAttention()
    private var usagePanels: [String: NativePillPanel] = [:]
    private var usagePresentations: [String: NativeHelperUsageGlance] = [:]
    private var displayedUsageIDs: [String] = []
    private var usagePopover: NSPopover?
    private var overflowPanel: NativePillPanel?
    private var overflowPopover: NSPopover?
    private var currentOverflowCount = 0
    private var shortcutSessionIDs: [String] = []
    private var shortcutSnapshot: NativeMenuShortcutSnapshot?
    private var hotKeyPressState = NativeMenuHotKeyPressState()
    private var hotKeys: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var shortcutModifierFamily = SessionShortcutModifierFamily.defaultFamily
    private var pillScreen = NativeHelperPillScreen.automatic
    private var fullScreenPolicy = FullScreenPillPolicy.onDemand
    private var hotkeyState = NativeMenuHotkeyState()
    private var density: PillBarPacker.Density = .standard
    private var readyPulseTimer: Timer?
    private var readyFadeTimer: Timer?
    private var layoutTimer: Timer?
    private var layoutObservers: [NSObjectProtocol] = []
    private var renderedDisplayID: CGDirectDisplayID?
    private var renderedScreenFrame: CGRect?
    private var panelHitSnapshot: NativeMenuPanelHitSnapshot?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var fullScreenPointerHideWorkItem: DispatchWorkItem?
    private var fullScreenShortcutHideWorkItem: DispatchWorkItem?
    private var isFullScreenActive = false
    private var isFullScreenPointerRevealActive = false
    private var isFullScreenShortcutRevealActive = false
    private var explicitPopoverRevealActive = false
    private var presentationIsVisible = true
    private var fullScreenProbeRunning = false
    private var fullScreenProbePending = false
    private var lastFullScreenProbeAt: TimeInterval = 0
    private let fullScreenScanQueue = DispatchQueue(
        label: "com.824zzy.AgentVisor.fullscreen-detect",
        qos: .userInitiated
    )
    private var lastActivation: (id: String, at: TimeInterval)?
    private var lastOverflowActivation: TimeInterval?
    private var sessionHoverState = NativeMenuSessionHoverState()
    private var sessionHoverWorkItem: DispatchWorkItem?
    private var sessionPopover: NSPopover?
    private var sessionPopoverID: String?

    private let pillHeight: CGFloat = 24
    private let standardSpacing: CGFloat = 4
    private let pressureSpacing: CGFloat = 3
    private let standardPadding: CGFloat = 7
    private let pressurePadding: CGFloat = 5
    private let edgePadding: CGFloat = 8

    override init() {
        super.init()
        configureStableItem()
        registerShortcuts()
        startLayoutUpdates()
        startClickMonitoring()
        startShortcutRevealMonitoring()
        startFullScreenPointerMonitoring()
    }

    func present(
        pills: [NativeHelperPill],
        navigatorPills: [NativeHelperPill],
        usageGlances: [NativeHelperUsageGlance],
        shortcutModifierFamily: SessionShortcutModifierFamily?,
        pillScreen: NativeHelperPillScreen?,
        fullScreenPolicy: FullScreenPillPolicy?,
        hotkeyTrigger: NativeHelperHotkeyTrigger?,
        customHotkeyCombo: KeyCombo?
    ) {
        if let hotkeyTrigger {
            hotkeyState.configure(trigger: hotkeyTrigger, customCombo: customHotkeyCombo)
        }
        if let pillScreen, pillScreen != self.pillScreen {
            self.pillScreen = pillScreen
            isFullScreenActive = false
            lastFullScreenProbeAt = 0
        }
        if let fullScreenPolicy { self.fullScreenPolicy = fullScreenPolicy }
        syncFullScreenRevealState()
        if let shortcutModifierFamily,
           shortcutModifierFamily != self.shortcutModifierFamily {
            self.shortcutModifierFamily = shortcutModifierFamily
            clearShortcutSnapshot()
            registerShortcuts()
        }

        var seenSessionIDs = Set<String>()
        let orderedPills = pills.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.filter { seenSessionIDs.insert($0.id).inserted }
        let previousPhases = sessionPresentations.mapValues(\.phase)
        let pillsByID = Dictionary(uniqueKeysWithValues: orderedPills.map { ($0.id, $0) })
        readyAttention.present(
            previousPhases: previousPhases,
            pills: orderedPills,
            now: Date()
        )
        displayedSessionIDs = NativeMenuSessionOrder.resolve(
            displayedIDs: displayedSessionIDs,
            previousPhases: previousPhases,
            presentedPills: orderedPills
        )
        displayedSessionIDs = NativeMenuSessionOrder.applyingReadyAcknowledgments(
            displayedIDs: displayedSessionIDs,
            phases: pillsByID.mapValues(\.phase),
            acknowledgedReadyIDs: readyAttention.acknowledgedReadyIDs
        )
        for id in sessionPanels.keys where pillsByID[id] == nil {
            if sessionPopoverID == id { dismissSessionPopover() }
            sessionPanels.removeValue(forKey: id)?.close()
        }
        for id in pillsByID.keys where sessionPanels[id] == nil {
            sessionPanels[id] = NativePillPanel()
        }
        sessionPresentations = pillsByID
        sessionHoverState.retain(sessionIDs: Set(pillsByID.keys))
        var seenNavigatorIDs = Set<String>()
        self.navigatorPills = navigatorPills.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.filter { seenNavigatorIDs.insert($0.id).inserted }

        var seenUsageIDs = Set<String>()
        let orderedUsage = usageGlances.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.filter { seenUsageIDs.insert($0.id).inserted }
        displayedUsageIDs = orderedUsage.map(\.id)
        let usageByID = Dictionary(
            orderedUsage.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in usagePanels.keys where usageByID[id] == nil {
            usagePanels.removeValue(forKey: id)?.close()
        }
        for id in usageByID.keys where usagePanels[id] == nil {
            usagePanels[id] = NativePillPanel()
        }
        usagePresentations = usageByID
        if usageByID.isEmpty {
            dismissUsagePopover()
        } else if usagePopover?.isShown == true,
                  let content = usagePopover?.contentViewController
                    as? NSHostingController<NativeMenuUsageView> {
            content.rootView = NativeMenuUsageView(
                glances: displayedUsageIDs.compactMap { usagePresentations[$0] }
            )
            usagePopover?.contentSize = content.view.fittingSize
        }

        layoutPresentation()
        refreshReadyPulse()
        refreshReadyFade()
    }

    private func refreshReadyPulse() {
        let now = Date()
        updateReadyPulse(now: now)
        guard readyAttention.hasActivePulse(
            pills: Array(sessionPresentations.values),
            now: now
        ) else {
            stopReadyPulse()
            return
        }
        guard readyPulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickReadyPulse() }
        }
        readyPulseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tickReadyPulse() {
        let now = Date()
        updateReadyPulse(now: now)
        if !readyAttention.hasActivePulse(
            pills: Array(sessionPresentations.values),
            now: now
        ) {
            stopReadyPulse()
        }
    }

    private func updateReadyPulse(now: Date) {
        for (id, pill) in sessionPresentations
        where pill.phase == .ready && shortcutSnapshot?.positions[id] == nil {
            let color = sessionPanels[id]?.pillButton.contentTintColor
                ?? statusColor(for: pill, now: now)
            sessionPanels[id]?.pillButton.contentTintColor = color.withAlphaComponent(
                readyAttention.opacity(id: id, phase: pill.phase, now: now)
            )
        }
    }

    private func stopReadyPulse() {
        readyPulseTimer?.invalidate()
        readyPulseTimer = nil
    }

    private func refreshReadyFade() {
        let now = Date()
        updateReadyFade(now: now)
        guard sessionPresentations.values.contains(where: {
            $0.phase == .ready && $0.inspector != nil
                && readyAttention.statusStaleness(pill: $0, now: now) < 1
        }) else {
            readyFadeTimer?.invalidate()
            readyFadeTimer = nil
            return
        }
        guard readyFadeTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshReadyFade() }
        }
        readyFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateReadyFade(now: Date) {
        for (id, pill) in sessionPresentations
        where pill.phase == .ready && shortcutSnapshot?.positions[id] == nil {
            sessionPanels[id]?.pillButton.contentTintColor = statusColor(for: pill, now: now)
                .withAlphaComponent(readyAttention.opacity(id: id, phase: pill.phase, now: now))
        }
    }

    private func startClickMonitoring() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.handleClick(at: NSEvent.mouseLocation, modifiers: event.modifierFlags)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            let point = NSEvent.mouseLocation
            let modifiers = event.modifierFlags
            Task { @MainActor in self?.handleClick(at: point, modifiers: modifiers) }
        }
    }

    private func handleClick(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let isInsidePopover = popover(overflowPopover, contains: point)
            || popover(usagePopover, contains: point)
        guard presentationIsVisible else { return }
        guard renderedGeometryIsFresh() else {
            if !isInsidePopover {
                dismissOverflowPopover()
                dismissUsagePopover()
            }
            return
        }
        guard let panelHitSnapshot else { return }
        switch NativeMenuPanelHitTest.resolve(
            point: point,
            orderedSessionIDs: panelHitSnapshot.orderedSessionIDs,
            sessionFrames: panelHitSnapshot.sessionFrames,
            overflowFrame: panelHitSnapshot.overflowFrame,
            orderedUsageIDs: panelHitSnapshot.orderedUsageIDs,
            usageFrames: panelHitSnapshot.usageFrames
        ) {
        case .session(let id): activateSession(id, intent: activationIntent(for: modifiers))
        case .overflow: activateOverflow()
        case .usage(let id): activateUsage(id)
        case .none:
            if !isInsidePopover {
                dismissOverflowPopover()
                dismissUsagePopover()
            }
        }
    }

    private func capturePanelHitSnapshot() {
        let sessionFrames = Dictionary(
            uniqueKeysWithValues: sessionPanels.compactMap { id, panel in
                panel.isVisible ? (id, panel.frame) : nil
            }
        )
        let usageFrames = Dictionary(
            uniqueKeysWithValues: usagePanels.compactMap { id, panel in
                panel.isVisible ? (id, panel.frame) : nil
            }
        )
        panelHitSnapshot = NativeMenuPanelHitSnapshot(
            orderedSessionIDs: displayedSessionIDs,
            sessionFrames: sessionFrames,
            overflowFrame: overflowPanel.flatMap { $0.isVisible ? $0.frame : nil },
            orderedUsageIDs: displayedUsageIDs,
            usageFrames: usageFrames
        )
    }

    private func handleSessionHover(_ id: String, hovering: Bool) {
        sessionHoverWorkItem?.cancel()
        if hovering {
            sessionHoverState.pointerEntered(id, at: ProcessInfo.processInfo.systemUptime)
            dismissSessionPopover()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.showSessionPopover(for: id) }
            }
            sessionHoverWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NativeMenuSessionHoverState.delay,
                execute: work
            )
        } else {
            sessionHoverState.pointerExited(id)
            dismissSessionPopover()
        }
    }

    private func showSessionPopover(for id: String) {
        let shortcutPosition = shortcutSnapshot?.positions[id]
            ?? shortcutSessionIDs.firstIndex(of: id).map { $0 + 1 }
        let shortcutLabel = shortcutPosition.flatMap {
            GlobalSessionShortcutPolicy.displayLabel(
                forPosition: $0,
                family: shortcutModifierFamily
            )
        }
        guard let panel = sessionPanels[id], panel.isVisible,
              let presentation = sessionHoverState.presentation(
                pills: sessionPresentations,
                at: ProcessInfo.processInfo.systemUptime,
                shortcutLabel: shortcutLabel
              ), presentation.id == id else { return }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let content = NSHostingController(
            rootView: NativeMenuSessionDetailView(presentation: presentation)
        )
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
        popover.show(relativeTo: panel.pillButton.bounds, of: panel.pillButton, preferredEdge: .minY)
        sessionPopover = popover
        sessionPopoverID = id
        updatePresentationVisibility()
    }

    private func dismissSessionPopover() {
        sessionHoverWorkItem?.cancel()
        sessionHoverWorkItem = nil
        sessionPopover?.close()
        sessionPopover = nil
        sessionPopoverID = nil
        updatePresentationVisibility()
    }

    private func activationIntent(
        for modifiers: NSEvent.ModifierFlags
    ) -> NativeHelperPillActivationIntent {
        modifiers.contains(.option) ? .chat : .standard
    }

    private func activateSession(
        _ id: String,
        intent: NativeHelperPillActivationIntent = .standard
    ) {
        sessionHoverState.pointerExited(id)
        dismissSessionPopover()
        dismissOverflowPopover()
        dismissUsagePopover()
        let now = ProcessInfo.processInfo.systemUptime
        if let lastActivation,
           lastActivation.id == id,
           now - lastActivation.at < 0.2 { return }
        lastActivation = (id, now)
        if sessionPresentations[id]?.phase == .ready {
            readyAttention.acknowledgeReady(id: id)
            displayedSessionIDs = NativeMenuSessionOrder.applyingReadyAcknowledgments(
                displayedIDs: displayedSessionIDs,
                phases: sessionPresentations.mapValues(\.phase),
                acknowledgedReadyIDs: readyAttention.acknowledgedReadyIDs
            )
            layoutPresentation()
            refreshReadyPulse()
        }
        sessionPanels[id]?.pillButton.flash()
        emit(.activatePill(sessionId: id, intent: intent))
    }

    private func activateOverflow() {
        dismissUsagePopover()
        let now = ProcessInfo.processInfo.systemUptime
        if let lastOverflowActivation, now - lastOverflowActivation < 0.2 { return }
        lastOverflowActivation = now
        overflowPanel?.pillButton.flash()
        if overflowPopover?.isShown == true {
            dismissOverflowPopover()
            return
        }
        guard let panel = overflowPanel, panel.isVisible else { return }
        let snapshot = NativeMenuOverflowSnapshot(
            menuPills: displayedSessionIDs.compactMap { sessionPresentations[$0] },
            navigatorPills: navigatorPills,
            visibleSessionIDs: visibleSessionIDs
        )
        guard !snapshot.overflowSessionIDs.isEmpty else { return }
        dismissSessionPopover()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let content = NSHostingController(rootView: NativeMenuOverflowView(
            snapshot: snapshot,
            onSelect: { [weak self] id in
                self?.dismissOverflowPopover()
                self?.activateSession(id)
            },
            onSelectChat: { [weak self] id in
                self?.dismissOverflowPopover()
                self?.activateSession(id, intent: .chat)
            },
            onOpenSessions: { [weak self] in
                self?.dismissOverflowPopover()
                self?.emit(.openSessions)
            },
            onOpenSettings: { [weak self] in
                self?.dismissOverflowPopover()
                self?.emit(.openSettings)
            },
            onDismiss: { [weak self] in self?.dismissOverflowPopover() }
        ))
        popover.contentViewController = content
        explicitPopoverRevealActive = true
        updatePresentationVisibility()
        let fittingSize = content.view.fittingSize
        popover.contentSize = NSSize(
            width: fittingSize.width,
            height: min(fittingSize.height, 620)
        )
        popover.show(
            relativeTo: panel.pillButton.bounds,
            of: panel.pillButton,
            preferredEdge: .minY
        )
        overflowPopover = popover
    }

    private func dismissOverflowPopover() {
        overflowPopover?.close()
        overflowPopover = nil
        if usagePopover?.isShown != true { explicitPopoverRevealActive = false }
        updatePresentationVisibility()
    }

    private func activateUsage(_ id: String) {
        usagePanels[id]?.pillButton.flash()
        if usagePopover?.isShown == true {
            dismissUsagePopover()
            return
        }
        guard let panel = usagePanels[id], panel.isVisible else { return }
        let glances = displayedUsageIDs.compactMap { usagePresentations[$0] }
        guard !glances.isEmpty else { return }
        dismissSessionPopover()
        dismissOverflowPopover()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let content = NSHostingController(rootView: NativeMenuUsageView(glances: glances))
        popover.contentViewController = content
        explicitPopoverRevealActive = true
        updatePresentationVisibility()
        popover.contentSize = content.view.fittingSize
        popover.show(
            relativeTo: panel.pillButton.bounds,
            of: panel.pillButton,
            preferredEdge: .minY
        )
        usagePopover = popover
        emit(.refreshUsage)
    }

    private func dismissUsagePopover() {
        usagePopover?.close()
        usagePopover = nil
        if overflowPopover?.isShown != true { explicitPopoverRevealActive = false }
        updatePresentationVisibility()
    }

    private func popover(_ popover: NSPopover?, contains point: CGPoint) -> Bool {
        guard let popover, popover.isShown,
              let window = popover.contentViewController?.view.window else { return false }
        return window.frame.contains(point)
    }

    private func startShortcutRevealMonitoring() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.handleShortcutEvent(event)
            return event
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            let type = event.type
            let flags = event.modifierFlags
            let keyCode = event.keyCode
            Task { @MainActor in
                self?.handleShortcutEvent(type: type, flags: flags, keyCode: keyCode)
            }
        }
    }

    private func handleShortcutEvent(_ event: NSEvent) {
        handleShortcutEvent(
            type: event.type,
            flags: event.modifierFlags,
            keyCode: event.keyCode
        )
    }

    private func handleShortcutEvent(
        type: NSEvent.EventType,
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) {
        switch type {
        case .flagsChanged:
            handleModifierFlags(flags)
            handleHotkeyModifierFlags(flags)
        case .keyDown:
            handleHotkeyKeyDown(keyCode: keyCode, flags: flags)
        default:
            break
        }
    }

    private func handleHotkeyModifierFlags(_ flags: NSEvent.ModifierFlags) {
        if hotkeyState.modifierFlagsChanged(modifierMask(flags), at: Date()) {
            emit(.toggleSessions)
        }
    }

    private func handleHotkeyKeyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if hotkeyState.keyDown(
            keyCode: keyCode,
            modifiers: modifierMask(flags),
            at: Date()
        ) {
            emit(.toggleSessions)
        }
    }

    private func handleModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let isArmed = shortcutsAreArmed(flags)
        updateFullScreenShortcutReveal(isRevealing: isArmed)
        if isArmed, shortcutSnapshot == nil {
            shortcutSnapshot = NativeMenuShortcutSnapshot(
                visibleSessionIDs: shortcutSessionIDs
            )
            refreshShortcutRendering()
        } else if !isArmed {
            clearShortcutSnapshot()
        }
    }

    private func shortcutsAreArmed(_ flags: NSEvent.ModifierFlags) -> Bool {
        GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: modifierMask(flags),
            family: shortcutModifierFamily
        )
    }

    private func modifierMask(_ flags: NSEvent.ModifierFlags) -> ModifierMask {
        var mask: ModifierMask = []
        if flags.contains(.shift) { mask.insert(.shift) }
        if flags.contains(.control) { mask.insert(.control) }
        if flags.contains(.option) { mask.insert(.option) }
        if flags.contains(.command) { mask.insert(.command) }
        return mask
    }

    private func clearShortcutSnapshot() {
        guard shortcutSnapshot != nil else { return }
        shortcutSnapshot = nil
        refreshShortcutRendering()
    }

    private func refreshShortcutRendering() {
        for id in displayedSessionIDs {
            guard let panel = sessionPanels[id],
                  panel.isVisible,
                  !panel.renderedTitle.isEmpty,
                  let pill = sessionPresentations[id] else { continue }
            panel.renderKey = ""
            renderSession(panel, pill: pill, label: panel.renderedTitle)
        }
        if currentOverflowCount > 0, let panel = overflowPanel, panel.isVisible {
            panel.renderKey = ""
            renderOverflow(panel, count: currentOverflowCount)
        }
    }

    private func startFullScreenPointerMonitoring() {
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) {
            [weak self] event in
            self?.updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) {
            [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.updateFullScreenPointerReveal(at: point) }
        }
    }

    private func syncFullScreenRevealState() {
        guard isFullScreenActive, fullScreenPolicy == .onDemand else {
            fullScreenPointerHideWorkItem?.cancel()
            fullScreenPointerHideWorkItem = nil
            fullScreenShortcutHideWorkItem?.cancel()
            fullScreenShortcutHideWorkItem = nil
            isFullScreenPointerRevealActive = false
            isFullScreenShortcutRevealActive = false
            updatePresentationVisibility()
            return
        }
        updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
        updateFullScreenShortcutReveal(isRevealing: shortcutsAreArmed(NSEvent.modifierFlags))
        updatePresentationVisibility()
    }

    private func updateFullScreenPointerReveal(at point: CGPoint) {
        guard isFullScreenActive, fullScreenPolicy == .onDemand,
              let screen = targetScreen() else {
            fullScreenPointerHideWorkItem?.cancel()
            fullScreenPointerHideWorkItem = nil
            isFullScreenPointerRevealActive = false
            updatePresentationVisibility()
            return
        }
        if FullScreenPillPointerZonePolicy.contains(
            pointer: point,
            screenRect: screen.frame,
            isRevealed: isFullScreenPointerRevealActive
        ) {
            fullScreenPointerHideWorkItem?.cancel()
            fullScreenPointerHideWorkItem = nil
            isFullScreenPointerRevealActive = true
            updatePresentationVisibility()
        } else if isFullScreenPointerRevealActive,
                  fullScreenPointerHideWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.fullScreenPointerHideWorkItem = nil
                self?.isFullScreenPointerRevealActive = false
                self?.updatePresentationVisibility()
            }
            fullScreenPointerHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
        }
    }

    private func updateFullScreenShortcutReveal(isRevealing: Bool) {
        guard isFullScreenActive, fullScreenPolicy == .onDemand else {
            fullScreenShortcutHideWorkItem?.cancel()
            fullScreenShortcutHideWorkItem = nil
            isFullScreenShortcutRevealActive = false
            updatePresentationVisibility()
            return
        }
        if isRevealing {
            fullScreenShortcutHideWorkItem?.cancel()
            fullScreenShortcutHideWorkItem = nil
            isFullScreenShortcutRevealActive = true
            updatePresentationVisibility()
        } else if isFullScreenShortcutRevealActive,
                  fullScreenShortcutHideWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.fullScreenShortcutHideWorkItem = nil
                self?.isFullScreenShortcutRevealActive = false
                self?.updatePresentationVisibility()
            }
            fullScreenShortcutHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }
    }

    private func updatePresentationVisibility() {
        let visible = FullScreenPillVisibilityPolicy.isVisible(
            isFullScreenActive: isFullScreenActive,
            policy: fullScreenPolicy,
            pointerRevealActive: isFullScreenPointerRevealActive,
            shortcutRevealActive: isFullScreenShortcutRevealActive,
            popoverPresented: explicitPopoverRevealActive
                || sessionPopover?.isShown == true
                || overflowPopover?.isShown == true
                || usagePopover?.isShown == true
        )
        let panels = Array(sessionPanels.values) + Array(usagePanels.values)
            + [overflowPanel].compactMap { $0 }
        panels.forEach { $0.ignoresMouseEvents = !visible }
        if visible == presentationIsVisible {
            panels.forEach { $0.alphaValue = visible ? 1 : 0 }
        } else {
            presentationIsVisible = visible
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panels.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
            }
        }
    }

    private func refreshFullScreenState(on screen: NSScreen, force: Bool = false) {
        guard !sessionPresentations.isEmpty || !usagePresentations.isEmpty else { return }
        if fullScreenProbeRunning {
            if force { fullScreenProbePending = true }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastFullScreenProbeAt >= 1 else { return }
        guard let displayId = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value else { return }
        fullScreenProbeRunning = true
        lastFullScreenProbeAt = now
        let screenFrame = screen.frame
        let screenRect = cgScreenRect(for: screen)
        fullScreenScanQueue.async { [weak self] in
            let active = FullScreenWindowDetector.ownerPID(intersecting: screenRect) != nil
            Task { @MainActor in
                guard let self else { return }
                self.fullScreenProbeRunning = false
                let repeatProbe = self.fullScreenProbePending
                self.fullScreenProbePending = false
                guard let liveScreen = self.targetScreen(),
                      (liveScreen.deviceDescription[
                        NSDeviceDescriptionKey("NSScreenNumber")
                      ] as? NSNumber)?.uint32Value == displayId,
                      MenuBarGeometryFreshness.isFresh(
                        captured: screenFrame,
                        live: liveScreen.frame
                      ) else {
                    if let screen = self.targetScreen() {
                        self.refreshFullScreenState(on: screen, force: true)
                    }
                    return
                }
                if self.isFullScreenActive != active {
                    self.isFullScreenActive = active
                    self.syncFullScreenRevealState()
                }
                if repeatProbe {
                    self.refreshFullScreenState(on: liveScreen, force: true)
                }
            }
        }
    }

    private func startLayoutUpdates() {
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.layoutPresentation() }
        }
        layoutTimer?.tolerance = 0.1
        layoutObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPresentation() }
        })
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            layoutObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.layoutPresentation()
                    if let screen = self.targetScreen() {
                        self.refreshFullScreenState(on: screen, force: true)
                    }
                }
            })
        }
    }

    private func layoutPresentation() {
        if shortcutSnapshot != nil, !shortcutsAreArmed(NSEvent.modifierFlags) {
            clearShortcutSnapshot()
        }
        guard let screen = targetScreen() else {
            hidePresentation()
            return
        }
        refreshFullScreenState(on: screen)
        if isFullScreenActive, fullScreenPolicy == .onDemand {
            updateFullScreenPointerReveal(at: NSEvent.mouseLocation)
        }
        let bounds = layoutBounds(on: screen)
        guard bounds.leftWidth > 0 || bounds.rightWidth > 0 else {
            hidePresentation()
            return
        }
        guard let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value else {
            hidePresentation()
            return
        }
        renderedDisplayID = displayID
        renderedScreenFrame = screen.frame

        let orderedPills = displayedSessionIDs.compactMap { sessionPresentations[$0] }
        let labels = Dictionary(uniqueKeysWithValues: orderedPills.map {
            ($0.id, fullTitle($0.title))
        })
        let candidates = orderedPills.compactMap { pill -> PillBarPacker.Candidate? in
            guard let label = labels[pill.id] else { return nil }
            return PillBarPacker.Candidate(
                id: pill.id,
                pillWidth: capsuleWidth(label, includesDot: true, padding: standardPadding)
            )
        }

        let usage = displayedUsageIDs.compactMap { usagePresentations[$0] }
        let usageWidths = usage.map {
            $0.width.map { CGFloat($0) }
                ?? capsuleWidth($0.label, includesDot: false, padding: standardPadding)
        }
        let usageWidth = totalWidth(usageWidths, spacing: standardSpacing)
        let showsUsage = !usage.isEmpty && usageWidth <= bounds.rightWidth
        let rightSessionWidth = max(
            0,
            bounds.rightWidth - (showsUsage ? usageWidth + standardSpacing : 0)
        )
        let result = PillBarPacker.pack(
            candidates: candidates,
            leftMax: bounds.leftWidth,
            rightMax: rightSessionWidth,
            standardProfile: .init(
                density: .standard,
                pillSpacing: standardSpacing,
                widthReduction: 0
            ),
            pressureProfile: .init(
                density: .pressure,
                pillSpacing: pressureSpacing,
                widthReduction: 2 * (standardPadding - pressurePadding)
            ),
            currentDensity: density,
            releaseHeadroom: 8,
            overflowPillWidthFor: { [standardPadding] count in
                capsuleWidth("+\(count)", includesDot: false, padding: standardPadding)
            }
        )
        density = result.density
        currentOverflowCount = result.hiddenCount
        let spacing = result.density == .pressure ? pressureSpacing : standardSpacing
        let padding = result.density == .pressure ? pressurePadding : standardPadding

        let visibleSessionIDs = result.leftVisibleIds + result.rightVisibleIds
        self.visibleSessionIDs = Set(visibleSessionIDs)
        if shortcutSnapshot == nil {
            shortcutSessionIDs = Array(visibleSessionIDs.prefix(9))
        }
        let visibleIDs = Set(visibleSessionIDs)
        for (id, panel) in sessionPanels where !visibleIDs.contains(id) {
            panel.orderOut(nil)
        }
        for (id, panel) in usagePanels where !showsUsage || !displayedUsageIDs.contains(id) {
            panel.orderOut(nil)
        }
        if !showsUsage { dismissUsagePopover() }

        let leftElements = pillElements(
            ids: result.leftVisibleIds,
            labels: labels,
            padding: padding
        ) + (result.hiddenCount > 0 && result.overflowSide == .left
            ? [.overflow(result.hiddenCount, overflowWidth(result.hiddenCount, padding: padding))]
            : [])
        var rightElements = pillElements(
            ids: result.rightVisibleIds,
            labels: labels,
            padding: padding
        )
        if result.hiddenCount > 0 && result.overflowSide == .right {
            rightElements.append(.overflow(
                result.hiddenCount,
                overflowWidth(result.hiddenCount, padding: padding)
            ))
        }
        if showsUsage {
            rightElements.append(contentsOf: usage.enumerated().map { index, glance in
                .usage(glance.id, usageWidths[index])
            })
        }

        let leftStart = bounds.leftInnerEdge
            - bounds.innerPadding
            - totalWidth(leftElements.map(\.width), spacing: spacing)
        place(
            elements: leftElements,
            startX: leftStart,
            y: bounds.y,
            spacing: spacing,
            labels: labels,
            padding: padding
        )
        place(
            elements: rightElements,
            startX: bounds.rightInnerEdge + bounds.innerPadding,
            y: bounds.y,
            spacing: spacing,
            labels: labels,
            padding: padding
        )

        if result.hiddenCount == 0 {
            overflowPanel?.orderOut(nil)
            dismissOverflowPopover()
        }
        capturePanelHitSnapshot()
        updatePresentationVisibility()
    }

    private enum LayoutElement {
        case session(String, CGFloat)
        case overflow(Int, CGFloat)
        case usage(String, CGFloat)

        var width: CGFloat {
            switch self {
            case .session(_, let width), .overflow(_, let width), .usage(_, let width): width
            }
        }
    }

    private func pillElements(
        ids: [String],
        labels: [String: String],
        padding: CGFloat
    ) -> [LayoutElement] {
        ids.compactMap { id in
            labels[id].map {
                .session(id, capsuleWidth($0, includesDot: true, padding: padding))
            }
        }
    }

    private func place(
        elements: [LayoutElement],
        startX: CGFloat,
        y: CGFloat,
        spacing: CGFloat,
        labels: [String: String],
        padding: CGFloat
    ) {
        var x = startX
        for element in elements {
            let frame = CGRect(x: x, y: y, width: element.width, height: pillHeight)
            switch element {
            case .session(let id, _):
                guard let pill = sessionPresentations[id], let panel = sessionPanels[id] else { break }
                renderSession(panel, pill: pill, label: labels[id] ?? fullTitle(pill.title))
                panel.place(frame: frame)
            case .overflow(let count, _):
                let panel = overflowPanel ?? NativePillPanel()
                overflowPanel = panel
                renderOverflow(panel, count: count)
                panel.place(frame: frame)
            case .usage(let id, _):
                guard let glance = usagePresentations[id], let panel = usagePanels[id] else { break }
                renderUsage(panel, glance: glance)
                panel.place(frame: frame)
            }
            x += element.width + spacing
        }
    }

    private func renderSession(_ panel: NativePillPanel, pill: NativeHelperPill, label: String) {
        let shortcutPosition = shortcutSnapshot?.positions[pill.id]
        let key = [
            pill.id,
            label,
            pill.phase.rawValue,
            shortcutPosition.map(String.init) ?? "",
        ].joined(separator: "|")
        guard panel.renderKey != key else { return }
        panel.renderKey = key
        let isRecent = pill.phase == .history
        configure(
            panel,
            title: label,
            fontSize: 11,
            foregroundColor: .white.withAlphaComponent(isRecent ? 0.62 : 0.85),
            image: shortcutPosition.map(keycapImage) ?? dotImage(),
            tooltip: nil,
            identifier: pill.id,
            backgroundAlpha: isRecent ? 0.24 : 0.35,
            borderAlpha: isRecent ? 0.07 : 0,
            onActivate: { [weak self] modifiers in
                self?.activateSession(
                    pill.id,
                    intent: self?.activationIntent(for: modifiers) ?? .standard
                )
            },
            onHoverChange: { [weak self] hovering in
                self?.handleSessionHover(pill.id, hovering: hovering)
            }
        )
        if shortcutPosition == nil {
            let now = Date()
            panel.pillButton.contentTintColor = statusColor(for: pill, now: now).withAlphaComponent(
                readyAttention.opacity(id: pill.id, phase: pill.phase, now: now)
            )
        }
    }

    private func renderUsage(_ panel: NativePillPanel, glance: NativeHelperUsageGlance) {
        let key = [glance.id, glance.label, glance.detail, glance.tone.rawValue].joined(separator: "|")
        guard panel.renderKey != key else { return }
        panel.renderKey = key
        configure(
            panel,
            title: glance.label,
            fontSize: 10.5,
            foregroundColor: color(for: glance.tone),
            image: nil,
            tooltip: glance.detail,
            identifier: glance.id,
            onActivate: nil,
            accessibilityLabel: glance.accessibilityLabel,
            accessibilityAction: { [weak self] in self?.activateUsage(glance.id) }
        )
    }

    private func renderOverflow(_ panel: NativePillPanel, count: Int) {
        let title = "+\(count)"
        let showsShortcut = shortcutSnapshot != nil
        let key = "\(title)|\(showsShortcut)"
        guard panel.renderKey != key else { return }
        panel.renderKey = key
        configure(
            panel,
            title: showsShortcut ? "" : title,
            fontSize: 11,
            foregroundColor: .white.withAlphaComponent(0.85),
            image: showsShortcut ? keycapImage(0) : nil,
            tooltip: "Open \(count) more sessions",
            identifier: "overflow",
            onActivate: { [weak self] _ in self?.activateOverflow() }
        )
    }

    private func configure(
        _ panel: NativePillPanel,
        title: String,
        fontSize: CGFloat,
        foregroundColor: NSColor,
        image: NSImage?,
        tooltip: String?,
        identifier: String,
        backgroundAlpha: CGFloat = 0.35,
        borderAlpha: CGFloat = 0,
        onActivate: ((NSEvent.ModifierFlags) -> Void)?,
        accessibilityLabel: String? = nil,
        accessibilityAction: (() -> Void)? = nil,
        onHoverChange: ((Bool) -> Void)? = nil
    ) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        panel.renderedTitle = title
        panel.pillButton.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font, .foregroundColor: foregroundColor]
        )
        panel.pillButton.image = image
        panel.pillButton.toolTip = tooltip
        panel.pillButton.identifier = NSUserInterfaceItemIdentifier(identifier)
        panel.pillButton.setAccessibilityElement(accessibilityLabel != nil)
        panel.pillButton.setAccessibilityLabel(accessibilityLabel)
        panel.pillButton.setAccessibilityHelp(
            accessibilityLabel == nil ? nil : "Open usage details"
        )
        panel.pillButton.onAccessibilityActivate = accessibilityAction
        panel.pillButton.normalBackgroundColor = .black.withAlphaComponent(backgroundAlpha)
        panel.pillButton.layer?.backgroundColor = panel.pillButton.normalBackgroundColor.cgColor
        panel.pillButton.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlpha).cgColor
        panel.pillButton.layer?.borderWidth = borderAlpha > 0 ? 1 : 0
        panel.pillButton.target = nil
        panel.pillButton.action = nil
        panel.pillButton.onActivate = onActivate
        panel.pillButton.onHoverChange = onHoverChange
    }

    private struct LayoutBounds {
        let leftInnerEdge: CGFloat
        let rightInnerEdge: CGFloat
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let innerPadding: CGFloat
        let y: CGFloat
    }

    private func layoutBounds(on screen: NSScreen) -> LayoutBounds {
        let screenFrame = screen.frame
        var leftInnerEdge = screenFrame.midX
        var rightInnerEdge = screenFrame.midX
        var hasNotch = false
        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX - left.maxX > 4 {
            leftInnerEdge = left.maxX
            rightInnerEdge = right.minX
            hasNotch = true
        }
        let innerPadding = hasNotch ? edgePadding : standardSpacing / 2
        let appMenuEdge = activeApplicationMenuRightEdge(on: screen)
            ?? screenFrame.minX + min(520, screenFrame.width * 0.4)
        let stableTrayEdge = stableItem.button?.window.flatMap {
            $0.screen == screen ? $0.frame.minX : nil
        }
        let trayEdge = statusTrayLeftEdge(on: screen)
            ?? stableTrayEdge
            ?? screenFrame.maxX - min(360, screenFrame.width * 0.25)
        let menuHeight = min(
            40,
            max(pillHeight, screenFrame.maxY - screen.visibleFrame.maxY)
        )
        return LayoutBounds(
            leftInnerEdge: leftInnerEdge,
            rightInnerEdge: rightInnerEdge,
            leftWidth: max(0, leftInnerEdge - innerPadding - appMenuEdge),
            rightWidth: max(0, trayEdge - rightInnerEdge - innerPadding),
            innerPadding: innerPadding,
            y: screenFrame.maxY - menuHeight + (menuHeight - pillHeight) / 2
        )
    }

    private func activeApplicationMenuRightEdge(on screen: NSScreen) -> CGFloat? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXMenuBarAttribute as CFString,
            &menuBarValue
        ) == .success,
        let menuBarValue else { return nil }
        let menuBar = menuBarValue as! AXUIElement
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            menuBar,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else { return nil }
        let target = cgScreenRect(for: screen)
        return children.compactMap(axFrame).filter {
            target.contains(CGPoint(x: $0.midX, y: $0.midY))
        }.map(\.maxX).max()
    }

    private func statusTrayLeftEdge(on screen: NSScreen) -> CGFloat? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowLayer as String] as? Int ?? 0) == 25,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        return StatusTrayLayoutPolicy.observedLeftEdge(
            targetScreenRect: cgScreenRect(for: screen),
            statusItemFrames: frames
        ).map { screen.frame.minX + $0 }
    }

    private func cgScreenRect(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(
            x: screen.frame.minX,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens.compactMap { screen -> NativeHelperScreen? in
            guard let displayId = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber)?.uint32Value else { return nil }
            return NativeHelperScreen(
                displayId: displayId,
                name: screen.localizedName,
                isBuiltIn: CGDisplayIsBuiltin(displayId) != 0,
                frame: nativeRectangle(screen.frame),
                visibleFrame: nativeRectangle(screen.visibleFrame),
                scale: screen.backingScaleFactor,
                isMain: screen == NSScreen.main
            )
        }
        guard let displayId = NativeMenuScreenSelectionPolicy.resolve(
            preference: pillScreen,
            screens: screens
        ) else { return nil }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayId
        }
    }

    private func nativeRectangle(_ value: CGRect) -> NativeHelperRectangle {
        NativeHelperRectangle(
            x: value.origin.x,
            y: value.origin.y,
            width: value.width,
            height: value.height
        )
    }

    private func renderedGeometryIsFresh() -> Bool {
        guard let renderedDisplayID, let renderedScreenFrame else { return false }
        let liveFrame = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == renderedDisplayID
        }?.frame
        return MenuBarGeometryFreshness.isFresh(
            captured: renderedScreenFrame,
            live: liveFrame
        )
    }

    private func hidePresentation() {
        renderedDisplayID = nil
        renderedScreenFrame = nil
        panelHitSnapshot = nil
        sessionPanels.values.forEach { $0.orderOut(nil) }
        usagePanels.values.forEach { $0.orderOut(nil) }
        overflowPanel?.orderOut(nil)
        dismissOverflowPopover()
        dismissUsagePopover()
    }

    private func capsuleWidth(
        _ title: String,
        includesDot: Bool,
        padding: CGFloat
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: includesDot ? 11 : 10.5, weight: .medium)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        return max(28, textWidth + (includesDot ? 9 : 0) + 2 * padding)
    }

    private func overflowWidth(_ count: Int, padding: CGFloat) -> CGFloat {
        capsuleWidth("+\(count)", includesDot: false, padding: padding)
    }

    private func totalWidth(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + CGFloat(widths.count - 1) * spacing
    }

    private func fullTitle(_ title: String) -> String {
        truncate(title, threshold: 22, prefix: 20)
    }

    private func truncate(_ title: String, threshold: Int, prefix: Int) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > threshold ? String(clean.prefix(prefix)) + "..." : clean
    }

    private func configureStableItem() {
        guard let button = stableItem.button else { return }
        button.image = NSImage(
            systemSymbolName: "rectangle.stack",
            accessibilityDescription: nil
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(openSessions)
        button.toolTip = "Open Agent Visor sessions"
        button.setAccessibilityLabel("Agent Visor sessions")
        button.setAccessibilityHelp("Opens the session browser")
    }

    private func dotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { bounds in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: bounds).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func keycapImage(_ position: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 12), flipped: false) { bounds in
            NSColor.white.withAlphaComponent(0.88).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            let text = "\(position)" as NSString
            let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black.withAlphaComponent(0.8),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: (bounds.width - size.width) / 2,
                    y: (bounds.height - size.height) / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = false
        return image
    }

    private func statusColor(for pill: NativeHelperPill, now: Date) -> NSColor {
        let fresh = color(for: pill.phase)
        let staleness = readyAttention.statusStaleness(pill: pill, now: now)
        guard staleness > 0 else { return fresh }
        return fresh.blended(
            withFraction: staleness,
            of: srgb(0x7F, 0x84, 0x9C)
        ) ?? fresh
    }

    private func color(for phase: NativeHelperPillPhase) -> NSColor {
        switch phase {
        case .needsYou: return srgb(0xF4, 0xC1, 0x14)
        case .ready: return srgb(0xA6, 0xE3, 0xA1)
        case .working: return srgb(0xD9, 0x78, 0x57)
        case .history: return srgb(0x7F, 0x84, 0x9C).withAlphaComponent(0.55)
        }
    }

    private func color(for tone: NativeHelperUsageTone) -> NSColor {
        switch tone {
        case .normal: return .white.withAlphaComponent(0.85)
        case .warning: return srgb(0xF9, 0xE2, 0xAF)
        case .critical: return srgb(0xF3, 0x8B, 0xA8)
        }
    }

    private func srgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    @objc private func openSessions() {
        emit(.openSessions)
    }

    private func registerShortcuts() {
        hotKeys.forEach { reference in
            if let reference { UnregisterEventHotKey(reference) }
        }
        hotKeys.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        hotKeyPressState = NativeMenuHotKeyPressState()
        guard shortcutModifierFamily != .off else { return }

        var specifications = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        specifications.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, context in
                    guard let event, let context else { return noErr }
                    var id = EventHotKeyID()
                    let status = GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &id
                    )
                    guard status == noErr else { return status }
                    let controller = Unmanaged<NativeMenuController>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                    Task { @MainActor in
                        controller.handleShortcut(id.id, isPressed: isPressed)
                    }
                    return noErr
                },
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }

        let signature = fourCharacterCode("AVSR")
        let modifiers: UInt32
        switch shortcutModifierFamily {
        case .off: return
        case .controlCommand: modifiers = UInt32(controlKey | cmdKey)
        case .optionCommand: modifiers = UInt32(optionKey | cmdKey)
        case .controlOptionCommand: modifiers = UInt32(controlKey | optionKey | cmdKey)
        }
        for hotKey in GlobalSessionShortcutPolicy.registeredHotKeys {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: hotKey.id)
            RegisterEventHotKey(
                hotKey.keyCode,
                modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            hotKeys.append(reference)
        }
    }

    private func handleShortcut(_ id: UInt32, isPressed: Bool) {
        guard hotKeyPressState.shouldHandle(id: id, isPressed: isPressed),
              let action = GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID: id) else {
            return
        }
        switch action {
        case .navigate(let position):
            let sessionID = shortcutSnapshot?.sessionID(at: position)
                ?? (shortcutSessionIDs.indices.contains(position) ? shortcutSessionIDs[position] : nil)
            guard let sessionID else { return }
            activateSession(sessionID)
        case .toggleOverflow:
            activateOverflow()
        }
    }
}

private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}
