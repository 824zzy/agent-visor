import AppKit
import Carbon.HIToolbox
import AgentVisorCore
import Combine
import os.log

@MainActor
final class GlobalSessionShortcutManager: ObservableObject {
    static let shared = GlobalSessionShortcutManager()

    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "SessionShortcut")

    @Published private(set) var shortcutPositions: [String: Int] = [:]
    @Published private(set) var family: SessionShortcutModifierFamily = .off
    @Published private(set) var isRevealingShortcuts = false
    var onNavigate: ((SessionState) -> Void)?
    var onToggleOverflow: (() -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hotKeyEventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var pressedHotKeyIDs: Set<UInt32> = []
    private var frozenSnapshot: GlobalSessionShortcutSnapshot?
    private var frozenPillsByID: [String: VisiblePill] = [:]

    private static let hotKeySignature: OSType = 0x41565348

    private init() {}

    func apply(_ newFamily: SessionShortcutModifierFamily) {
        guard newFamily != family || (newFamily != .off && (globalMonitor == nil || hotKeyRefs.isEmpty)) else { return }
        stopMonitors()
        family = newFamily
        guard newFamily != .off else { return }
        startMonitors()
        Self.logger.info("Session shortcuts applied: \(newFamily.rawValue, privacy: .public)")
    }

    func position(forStableID stableID: String) -> Int? {
        shortcutPositions[stableID]
    }

    private func startMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in
                _ = GlobalSessionShortcutManager.shared.handle(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        installHotKeyHandler()
        registerHotKeys()
    }

    private func stopMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        pressedHotKeyIDs.removeAll()
        if let hotKeyEventHandler {
            RemoveEventHandler(hotKeyEventHandler)
            self.hotKeyEventHandler = nil
        }
        clearSnapshot()
    }

    private func handle(_ event: NSEvent) -> Bool {
        let semantic: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let pressed = ModifierMask.fromNSEvent(event.modifierFlags.intersection(semantic))
        let isArmed = GlobalSessionShortcutPolicy.isArmed(
            pressedModifiers: pressed,
            family: family
        )

        switch event.type {
        case .flagsChanged:
            if isArmed {
                freezeRenderedPillsIfNeeded()
            } else {
                clearSnapshot()
            }
            return false
        default:
            return false
        }
    }

    private func installHotKeyHandler() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else { return parameterStatus }
                guard hotKeyID.signature == GlobalSessionShortcutManager.hotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                Task { @MainActor in
                    GlobalSessionShortcutManager.shared.handleRegisteredHotKey(
                        id: hotKeyID.id,
                        isPressed: isPressed
                    )
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            nil,
            &hotKeyEventHandler
        )
        if status != noErr {
            Self.logger.error("Failed to install session shortcut handler status=\(status, privacy: .public)")
        }
    }

    private func registerHotKeys() {
        guard hotKeyEventHandler != nil else { return }
        let modifiers = carbonModifiers(for: family)
        for shortcut in GlobalSessionShortcutPolicy.registeredHotKeys {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: shortcut.id)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                Self.logger.error(
                    "Failed to register session shortcut digit=\(shortcut.digit, privacy: .public) status=\(status, privacy: .public)"
                )
            }
        }
    }

    private func carbonModifiers(for family: SessionShortcutModifierFamily) -> UInt32 {
        let modifiers = family.modifiers
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func handleRegisteredHotKey(id: UInt32, isPressed: Bool) {
        if !isPressed {
            pressedHotKeyIDs.remove(id)
            return
        }
        guard pressedHotKeyIDs.insert(id).inserted,
              let action = GlobalSessionShortcutPolicy.action(forRegisteredHotKeyID: id)
        else { return }

        freezeRenderedPillsIfNeeded()
        switch action {
        case .navigate(let position):
            guard let sessionID = frozenSnapshot?.targetSessionID(forPosition: position),
                  let pill = frozenPillsByID[sessionID] else { return }
            Self.logger.notice(
                "Global session shortcut position=\(position + 1, privacy: .public) session=\(pill.session.sessionId, privacy: .public)"
            )
            onNavigate?(pill.session)
        case .toggleOverflow:
            Self.logger.notice("Global session shortcut toggling overflow")
            _ = onToggleOverflow?()
        }
    }

    private func freezeRenderedPillsIfNeeded() {
        isRevealingShortcuts = true
        guard frozenSnapshot == nil else { return }
        let store = PillBarSnapshotStore.shared
        let pills = PillBarSnapshotStore.shared.pillsInReadingOrder
        let snapshot = GlobalSessionShortcutSnapshot(
            leftVisibleSessionIDs: store.leftPills.map(\.id),
            rightVisibleSessionIDs: store.rightPills.map(\.id)
        )

        var pillsByID: [String: VisiblePill] = [:]
        var positions: [String: Int] = [:]
        for pill in pills {
            pillsByID[pill.id] = pill
            if let position = snapshot.displayPosition(forSessionID: pill.id) {
                positions[pill.id] = position
            }
        }
        frozenSnapshot = snapshot
        frozenPillsByID = pillsByID
        shortcutPositions = positions
    }

    private func clearSnapshot() {
        isRevealingShortcuts = false
        frozenSnapshot = nil
        frozenPillsByID = [:]
        shortcutPositions = [:]
    }
}
