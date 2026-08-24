import AgentVisorCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

private final class NativePillButton: NSButton {
    var normalBackgroundColor = NSColor.black.withAlphaComponent(0.35)
    var onActivate: ((NSEvent.ModifierFlags) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

@MainActor
final class NativeMenuController: NSObject {
    var emit: (NativeHelperEvent) -> Void = { _ in }

    private let stableItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var sessionPanels: [String: NativePillPanel] = [:]
    private var sessionPresentations: [String: NativeHelperPill] = [:]
    private var displayedSessionIDs: [String] = []
    private var readyAttention = NativeMenuReadyAttention()
    private var usagePanels: [String: NativePillPanel] = [:]
    private var usagePresentations: [String: NativeHelperUsageGlance] = [:]
    private var displayedUsageIDs: [String] = []
    private var overflowPanel: NativePillPanel?
    private var shortcutSessionIDs: [String] = []
    private var shortcutSnapshot: NativeMenuShortcutSnapshot?
    private var hotKeys: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var shortcutModifierFamily = SessionShortcutModifierFamily.defaultFamily
    private var hotkeyState = NativeMenuHotkeyState()
    private var density: PillBarPacker.Density = .standard
    private var readyPulseTimer: Timer?
    private var layoutTimer: Timer?
    private var layoutObservers: [NSObjectProtocol] = []
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalFlagsMonitor: Any?
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
    }

    func present(
        pills: [NativeHelperPill],
        usageGlances: [NativeHelperUsageGlance],
        shortcutModifierFamily: SessionShortcutModifierFamily?,
        hotkeyTrigger: NativeHelperHotkeyTrigger?,
        customHotkeyCombo: KeyCombo?
    ) {
        if let hotkeyTrigger {
            hotkeyState.configure(trigger: hotkeyTrigger, customCombo: customHotkeyCombo)
        }
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

        layoutPresentation()
        refreshReadyPulse()
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
            sessionPanels[id]?.pillButton.contentTintColor = color(for: pill.phase)
                .withAlphaComponent(readyAttention.opacity(id: id, phase: pill.phase, now: now))
        }
    }

    private func stopReadyPulse() {
        readyPulseTimer?.invalidate()
        readyPulseTimer = nil
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
        let sessionFrames = Dictionary(
            uniqueKeysWithValues: sessionPanels.compactMap { id, panel in
                panel.isVisible ? (id, panel.frame) : nil
            }
        )
        let overflowFrame = overflowPanel.flatMap { $0.isVisible ? $0.frame : nil }
        switch NativeMenuPanelHitTest.resolve(
            point: point,
            orderedSessionIDs: displayedSessionIDs,
            sessionFrames: sessionFrames,
            overflowFrame: overflowFrame
        ) {
        case .session(let id): activateSession(id, intent: activationIntent(for: modifiers))
        case .overflow: activateOverflow()
        case .none: break
        }
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
    }

    private func dismissSessionPopover() {
        sessionHoverWorkItem?.cancel()
        sessionHoverWorkItem = nil
        sessionPopover?.close()
        sessionPopover = nil
        sessionPopoverID = nil
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
        let now = ProcessInfo.processInfo.systemUptime
        if let lastOverflowActivation, now - lastOverflowActivation < 0.2 { return }
        lastOverflowActivation = now
        overflowPanel?.pillButton.flash()
        emit(.openSessions)
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
        layoutObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPresentation() }
        })
    }

    private func layoutPresentation() {
        if shortcutSnapshot != nil, !shortcutsAreArmed(NSEvent.modifierFlags) {
            clearShortcutSnapshot()
        }
        guard let screen = targetScreen() else {
            hidePresentation()
            return
        }
        let bounds = layoutBounds(on: screen)
        guard bounds.leftWidth > 0 || bounds.rightWidth > 0 else {
            hidePresentation()
            return
        }

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
            capsuleWidth($0.label, includesDot: false, padding: standardPadding)
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
        let spacing = result.density == .pressure ? pressureSpacing : standardSpacing
        let padding = result.density == .pressure ? pressurePadding : standardPadding

        let visibleSessionIDs = result.leftVisibleIds + result.rightVisibleIds
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
        }
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
            panel.pillButton.contentTintColor = color(for: pill.phase).withAlphaComponent(
                readyAttention.opacity(id: pill.id, phase: pill.phase, now: Date())
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
            onActivate: nil
        )
    }

    private func renderOverflow(_ panel: NativePillPanel, count: Int) {
        let key = "+\(count)"
        guard panel.renderKey != key else { return }
        panel.renderKey = key
        configure(
            panel,
            title: key,
            fontSize: 11,
            foregroundColor: .white.withAlphaComponent(0.85),
            image: nil,
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
        let trayEdge = stableItem.button?.window?.frame.minX
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
        return children.compactMap(axFrame).map(\.maxX).max()
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
        if let frame = stableItem.button?.window?.frame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func hidePresentation() {
        sessionPanels.values.forEach { $0.orderOut(nil) }
        usagePanels.values.forEach { $0.orderOut(nil) }
        overflowPanel?.orderOut(nil)
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
        guard shortcutModifierFamily != .off else { return }

        var specification = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
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
                Task { @MainActor in controller.handleShortcut(id.id) }
                return noErr
            },
            1,
            &specification,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

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

    private func handleShortcut(_ id: UInt32) {
        guard let action = GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID: id) else {
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
