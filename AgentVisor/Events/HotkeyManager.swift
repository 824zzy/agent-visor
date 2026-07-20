//
//  HotkeyManager.swift
//  AgentVisor
//
//  Thin NSEvent shim that translates AppKit modifier events into the
//  pure `HotkeyDoubleTapDetector` state machine in AgentVisorCore.
//  All gesture logic (window timing, hold ceilings, chord aborts) lives
//  in the detector and is unit-tested there. This file only handles:
//    - which modifier flag we're watching (the .shift / .cmd / etc. picker)
//    - lifecycle of the global + local NSEvent monitors
//    - firing the `onTrigger` callback when the detector says so
//
//  Window tightened from 300ms → 200ms in v2.1.5 after user reports of
//  shift-shift mis-fires while typing prose. See HotkeyDoubleTapConfig.
//

import AppKit
import AgentVisorCore
import os.log

/// Detects a clean double-tap of the configured trigger modifier and
/// fires `onTrigger`. Delegates the state machine to
/// `HotkeyDoubleTapDetector`.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Hotkey")

    private let detector = HotkeyDoubleTapDetector(config: .standard)
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Currently active trigger. `.off` means no monitors installed.
    private(set) var trigger: HotkeyTrigger = .off

    /// Active custom combo, populated when `trigger == .custom`. Read
    /// at install time from `AppSettings.customCombo`; can be reapplied
    /// at runtime when the user records a new combo. `.custom` + nil
    /// behaves like `.off` (no monitors firing).
    private var customCombo: KeyCombo?

    /// Fired on the main actor when a clean double-tap is detected.
    var onTrigger: (() -> Void)?

    private init() {}

    /// Switch which modifier the manager listens for. Pass `.off` to
    /// disable. Idempotent — calling with the same trigger does nothing.
    func applyTrigger(_ newTrigger: HotkeyTrigger) {
        // Re-apply unconditionally when .custom because the combo may
        // have changed even when the trigger enum did not.
        if newTrigger == trigger && newTrigger != .custom {
            return
        }
        stop()
        trigger = newTrigger
        if newTrigger == .custom {
            customCombo = AppSettings.customCombo
            if customCombo != nil {
                startMonitors()
            }
        } else if newTrigger != .off {
            customCombo = nil
            startMonitors()
        }
        Self.logger.info("Hotkey trigger applied: \(newTrigger.rawValue, privacy: .public)")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        // Detector keeps internal state across hotkey-trigger swaps; an
        // explicit reset isn't required because `.foreignModifierHeld`
        // and idle drift restore `.idle` quickly. Tracking the reset
        // explicitly would require exposing detector internals.
    }

    func rearmAfterAccessibilityRecovery() {
        guard trigger != .off else { return }
        if trigger == .custom, customCombo == nil {
            return
        }
        stop()
        startMonitors()
        Self.logger.info("Hotkey monitors rearmed after Accessibility recovery")
    }

    // MARK: - Setup

    private func startMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Both monitors needed: global catches events going to other apps
        // (the common case, since the user invokes the hotkey while in
        // another app), local catches events going to AgentVisor itself
        // (hotkey pressed while notch is already focused).
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            Task { @MainActor in HotkeyManager.shared.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }

        if !AXIsProcessTrusted() {
            Self.logger.warning("Hotkey: AX not trusted, global monitor will silently no-op")
        }
    }

    // MARK: - Modifier Mapping

    /// Modifier flag we're watching for the current trigger. Nil when
    /// off or in custom mode (custom mode dispatches on keyDown, not
    /// flagsChanged).
    private var triggerFlag: NSEvent.ModifierFlags? {
        switch trigger {
        case .off, .custom: return nil
        case .cmd: return .command
        case .ctrl: return .control
        case .option: return .option
        case .shift: return .shift
        }
    }

    /// All semantic modifier flags MINUS the trigger. If any of these are
    /// held alongside the trigger, the user is doing a chord, not a tap.
    private var foreignFlags: NSEvent.ModifierFlags {
        let all: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard let triggerFlag = triggerFlag else { return all }
        return all.subtracting(triggerFlag)
    }

    // MARK: - Event Handling

    private func handle(_ event: NSEvent) {
        let now = Date()
        switch event.type {
        case .flagsChanged:
            // Custom mode ignores modifier transitions — the chord fires
            // on a real keyDown carrying the modifier flags inline.
            if trigger != .custom {
                handleFlagsChanged(event, now: now)
            }
        case .keyDown:
            if trigger == .custom {
                handleCustomKeyDown(event)
            } else {
                handleKeyDown()
            }
        default:
            break
        }
    }

    private func handleCustomKeyDown(_ event: NSEvent) {
        guard let target = customCombo else { return }
        guard event.keyCode == target.keyCode else { return }
        // Compare only the semantic mod flags (drop caps lock / fn /
        // numeric-pad / etc. that NSEvent carries in the upper bits).
        let semantic: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let pressed = ModifierMask.fromNSEvent(event.modifierFlags.intersection(semantic))
        guard pressed == target.modifiers else { return }
        Self.logger.info("Custom hotkey fired: \(target.serialized(), privacy: .public)")
        onTrigger?()
    }

    private func handleFlagsChanged(_ event: NSEvent, now: Date) {
        guard let triggerFlag = triggerFlag else { return }

        let mods = event.modifierFlags
        let triggerHeld = mods.contains(triggerFlag)
        // Caps lock and Fn don't represent intent; ignore them.
        let otherMods = mods.intersection(foreignFlags)

        let input: HotkeyDoubleTapDetector.Input
        if triggerHeld && otherMods.isEmpty {
            input = .triggerDown(at: now)
        } else if !triggerHeld {
            input = .triggerUp(at: now)
        } else {
            input = .foreignModifierHeld(at: now)
        }

        if detector.handle(input) == .fired {
            Self.logger.info("Double-tap detected: \(self.trigger.rawValue, privacy: .public)")
            onTrigger?()
        }
    }

    private func handleKeyDown() {
        // Pass through to the detector — it aborts pending gestures on
        // non-modifier keyDown. That's what kills the shift-shift-9
        // false positive (pressing `9` for `(` aborts before shift
        // releases).
        _ = detector.handle(.nonModifierKeyDown(at: Date()))
    }
}

extension ModifierMask {
    /// Bridge AppKit's `NSEvent.ModifierFlags` (which carries
    /// device-independent flags like caps lock in the same bitfield)
    /// into the Core enum. Caller is expected to have already
    /// intersected with the semantic-modifier subset.
    static func fromNSEvent(_ flags: NSEvent.ModifierFlags) -> ModifierMask {
        var result: ModifierMask = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option)  { result.insert(.option) }
        if flags.contains(.shift)   { result.insert(.shift) }
        return result
    }
}
