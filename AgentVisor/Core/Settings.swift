//
//  Settings.swift
//  AgentVisor
//
//  App settings manager using UserDefaults
//

import AppKit
import AgentVisorCore
import Foundation

/// Available notification sounds
enum NotificationSound: String, CaseIterable {
    case none = "None"
    case pop = "Pop"
    case ping = "Ping"
    case tink = "Tink"
    case glass = "Glass"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case hero = "Hero"
    case morse = "Morse"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case basso = "Basso"

    /// The system sound name to use with NSSound, or nil for no sound
    var soundName: String? {
        self == .none ? nil : rawValue
    }
}

/// Which color flavor to render the app in. `system` follows macOS's
/// global appearance (so a user with Auto-switch sees the app flip with
/// sunset/sunrise); `dark` pins Catppuccin Mocha; `light` pins
/// Catppuccin Latte. Pills/menu-bar chrome stay dark in all modes.
enum AppearanceMode: String, CaseIterable {
    case system
    case dark
    case light

    var displayLabel: String {
        switch self {
        case .system: return "System"
        case .dark:   return "Dark"
        case .light:  return "Light"
        }
    }

    /// Resolve to a concrete light/dark choice. `.system` reads the
    /// current effective NSAppearance off the running app and reports
    /// the side that matches. This is the value `Catppuccin.active`
    /// keys on, so token reads stay in lockstep with native chrome.
    var resolved: ResolvedAppearance {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            return SystemAppearance.current()
        }
    }
}

/// Concrete light-or-dark outcome after `.system` resolution. Tokens
/// (`Catppuccin.active`, NSWindow.appearance) read from this, never
/// directly from `AppearanceMode`.
enum ResolvedAppearance: String {
    case light
    case dark
}

/// Reads the OS's effective appearance synchronously off main-actor.
/// Wraps `NSApp.effectiveAppearance.bestMatch(among:)` so the
/// `.system` case can resolve without taking a SwiftUI Environment
/// dependency (callers reach this from non-View contexts too).
enum SystemAppearance {
    static func current() -> ResolvedAppearance {
        // `NSApp` may be nil very early in launch; default to dark
        // (the app's historical default).
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .darkAqua)
        guard let appearance else { return .dark }
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }
}

typealias FullScreenPolicy = FullScreenPillPolicy

/// Which app the chat opens file links in. `auto` runs the detection
/// chain (Cursor → VS Code → VS Code Insiders → Zed → Xcode → finder
/// fallback) and picks the first installed candidate. The explicit
/// cases force-pin a specific editor regardless of detection.
enum EditorPreference: String, CaseIterable {
    case auto
    case cursor
    case vscode
    case vscodeInsiders = "vscode-insiders"
    case zed
    case xcode
    case systemDefault = "system-default"

    var displayLabel: String {
        switch self {
        case .auto: return "Auto-detect (Cursor, then VS Code)"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .vscodeInsiders: return "VS Code Insiders"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .systemDefault: return "System default"
        }
    }

    /// Bundle id used to launch via `NSWorkspace.openApplication`. Nil
    /// for `.auto` (chain handles it) and `.systemDefault` (uses
    /// `NSWorkspace.open` to defer to LaunchServices).
    var bundleID: String? {
        switch self {
        case .auto, .systemDefault: return nil
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .vscodeInsiders: return "com.microsoft.VSCodeInsiders"
        case .zed: return "dev.zed.Zed"
        case .xcode: return "com.apple.dt.Xcode"
        }
    }
}

/// Which modifier double-tap toggles the notch. `off` disables the
/// global hotkey entirely. `custom` switches to a single-press chord
/// stored in `AppSettings.customCombo`.
enum HotkeyTrigger: String, CaseIterable {
    case off
    case cmd
    case ctrl
    case option
    case shift
    case custom

    var displayLabel: String {
        switch self {
        case .off: return "Off"
        case .cmd: return "Double-tap \u{2318}"   // ⌘
        case .ctrl: return "Double-tap \u{2303}"  // ⌃
        case .option: return "Double-tap \u{2325}" // ⌥
        case .shift: return "Double-tap \u{21E7}" // ⇧
        case .custom: return "Custom shortcut"
        }
    }
}

enum AppSettings {
    private static let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let notificationSound = "notificationSound"
        static let hotkeyTrigger = "hotkeyTrigger"
        static let customHotkeyCombo = "customHotkeyCombo"
        static let sessionShortcutModifierFamily = "sessionShortcutModifierFamily"
        static let chatFontScale = "chatFontScale"
        static let appearance = "appearance"
        static let fullScreenPolicy = "fullScreenPolicy"
        static let pillsEnabled = "pillsEnabled"
        static let codexUsageGlanceEnabled = "codexUsageGlanceEnabled"
        static let chatVisibility = "chatVisibility"
        static let editorPreference = "editorPreference"
        static let connectedCodexEnabled = "connectedCodexEnabled"
        static let connectedCodexActivationDate = "connectedCodexActivationDate"
        static let connectedCodexLaunchEnvironmentOwned = "connectedCodexLaunchEnvironmentOwned"
        static let lastNotifiedUpdateVersion = "lastNotifiedUpdateVersion"
        nonisolated static let observedWindowHours = "observedWindowHours"
    }

    // MARK: - Chat Font Scale

    /// Multiplier applied to all text inside the chat scroll area
    /// (message bodies, tool-call labels, plan blocks, code blocks).
    /// Header / input / status bar stay fixed because they're chrome.
    /// Adjusted at runtime via Cmd-+ / Cmd-- / Cmd-0 in the chat panel.
    static let chatFontScaleMin: Double = 0.8
    static let chatFontScaleMax: Double = 2.5
    static let chatFontScaleStep: Double = 0.1

    static var chatFontScale: Double {
        get {
            let raw = defaults.object(forKey: Keys.chatFontScale) as? Double ?? 1.0
            return min(max(raw, chatFontScaleMin), chatFontScaleMax)
        }
        set {
            let clamped = min(max(newValue, chatFontScaleMin), chatFontScaleMax)
            // Round to 1 decimal so 0.1 increments don't accumulate float drift.
            let rounded = (clamped * 10).rounded() / 10
            defaults.set(rounded, forKey: Keys.chatFontScale)
        }
    }

    // MARK: - Notification Sound

    /// The sound to play when Claude finishes and is ready for input
    static var notificationSound: NotificationSound {
        get {
            guard let rawValue = defaults.string(forKey: Keys.notificationSound),
                  let sound = NotificationSound(rawValue: rawValue) else {
                return .pop // Default to Pop
            }
            return sound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.notificationSound)
        }
    }

    static var lastNotifiedUpdateVersion: String? {
        get { defaults.string(forKey: Keys.lastNotifiedUpdateVersion) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.lastNotifiedUpdateVersion)
            } else {
                defaults.removeObject(forKey: Keys.lastNotifiedUpdateVersion)
            }
        }
    }

    // MARK: - Global Hotkey

    /// Modifier whose double-tap toggles the notch. Defaults to `.shift`
    /// since it doesn't conflict with copy/paste or terminal interrupt.
    static var hotkeyTrigger: HotkeyTrigger {
        get {
            guard let raw = defaults.string(forKey: Keys.hotkeyTrigger),
                  let trigger = HotkeyTrigger(rawValue: raw) else {
                return .shift
            }
            return trigger
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.hotkeyTrigger)
        }
    }

    /// Single-press chord used when `hotkeyTrigger == .custom`. Nil
    /// means no combo recorded yet — the manager treats `.custom + nil`
    /// the same as `.off`.
    static var customCombo: KeyCombo? {
        get {
            guard let s = defaults.string(forKey: Keys.customHotkeyCombo) else { return nil }
            return KeyCombo.fromSerialized(s)
        }
        set {
            if let combo = newValue {
                defaults.set(combo.serialized(), forKey: Keys.customHotkeyCombo)
            } else {
                defaults.removeObject(forKey: Keys.customHotkeyCombo)
            }
        }
    }

    static var sessionShortcutModifierFamily: SessionShortcutModifierFamily {
        get {
            guard let raw = defaults.string(forKey: Keys.sessionShortcutModifierFamily),
                  let family = SessionShortcutModifierFamily(rawValue: raw) else {
                return .defaultFamily
            }
            return family
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.sessionShortcutModifierFamily)
        }
    }

    // MARK: - Appearance

    /// Light vs dark flavor for the notch panel. Defaults to `.dark`
    /// (Catppuccin Mocha) so existing users see no surprise on upgrade.
    /// Read off the main thread is safe — UserDefaults is thread-safe and
    /// `SelectionColorOverride`'s NSColor swizzle relies on this property
    /// without bouncing through the @MainActor `AppearanceSelector`.
    static var appearance: AppearanceMode {
        get {
            guard let raw = defaults.string(forKey: Keys.appearance),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .dark
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.appearance)
        }
    }

    // MARK: - Full-screen policy

    /// How the pill strip behaves on its configured screen while a native
    /// full-screen window is active. Legacy `media` and `never` values
    /// migrate to the safer on-demand default; `alwaysShow` must be selected
    /// explicitly under the current policy model.
    static var fullScreenPolicy: FullScreenPolicy {
        get {
            FullScreenPillPolicy.fromPersistedValue(
                defaults.string(forKey: Keys.fullScreenPolicy)
            )
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.fullScreenPolicy)
        }
    }

    // MARK: - Pills

    /// Whether the menu-bar pill strip renders. When false, the
    /// `PillsStripWindow` hides itself entirely so AX surface stays
    /// clean. The window-mode chat is the primary surface now, so
    /// some users prefer a quieter menu bar.
    static var pillsEnabled: Bool {
        get {
            // `bool(forKey:)` returns false for "no value yet", which
            // would silently disable pills on first launch — wrong
            // default. Use `object(forKey:)` to distinguish unset
            // from explicit false.
            guard let stored = defaults.object(forKey: Keys.pillsEnabled) as? Bool else {
                return true
            }
            return stored
        }
        set {
            defaults.set(newValue, forKey: Keys.pillsEnabled)
        }
    }

    static var codexUsageGlanceEnabled: Bool {
        get {
            guard let stored = defaults.object(forKey: Keys.codexUsageGlanceEnabled) as? Bool else {
                return true
            }
            return stored
        }
        set {
            defaults.set(newValue, forKey: Keys.codexUsageGlanceEnabled)
        }
    }

    // MARK: - Editor preference

    /// Which app file-link clicks (Edit/Write rows in the chat) open
    /// the file in. Defaults to `.auto`, which probes the install chain
    /// (Cursor → VS Code → Insiders → Zed → Xcode) and uses whichever
    /// is installed first. Power users can pin a specific editor.
    static var editorPreference: EditorPreference {
        get {
            guard let raw = defaults.string(forKey: Keys.editorPreference),
                  let value = EditorPreference(rawValue: raw) else {
                return .auto
            }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.editorPreference)
        }
    }

    // MARK: - Connected Codex

    static var connectedCodexEnabled: Bool {
        get {
            defaults.object(forKey: Keys.connectedCodexEnabled) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Keys.connectedCodexEnabled)
        }
    }

    static var connectedCodexActivationDate: Date? {
        get {
            defaults.object(forKey: Keys.connectedCodexActivationDate) as? Date
        }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.connectedCodexActivationDate)
            } else {
                defaults.removeObject(forKey: Keys.connectedCodexActivationDate)
            }
        }
    }

    static var connectedCodexLaunchEnvironmentOwned: Bool {
        get {
            defaults.object(forKey: Keys.connectedCodexLaunchEnvironmentOwned) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Keys.connectedCodexLaunchEnvironmentOwned)
        }
    }

    static var hasConnectedCodexLaunchEnvironmentOwnershipRecord: Bool {
        defaults.object(forKey: Keys.connectedCodexLaunchEnvironmentOwned) != nil
    }

    // MARK: - Observed-agent window

    /// How recently a Codex GUI thread, Cursor IDE thread, or Zed-hosted
    /// thread must have been active to count as "live". These run inside a
    /// shared app/agent process with no reliable per-thread PID, so liveness
    /// is a recency heuristic rather than a real signal — this window is that
    /// heuristic. Terminal claude-code sessions have real per-process PIDs
    /// and hook events, so they ignore this entirely. Stored in whole hours;
    /// clamped to a sane range.
    nonisolated static let observedWindowHoursMin: Int = 1
    nonisolated static let observedWindowHoursMax: Int = 168   // 1 week
    nonisolated static let observedWindowHoursDefault: Int = 42

    nonisolated static var observedWindowHours: Int {
        get {
            let raw = UserDefaults.standard.object(forKey: Keys.observedWindowHours) as? Int ?? observedWindowHoursDefault
            return min(max(raw, observedWindowHoursMin), observedWindowHoursMax)
        }
        set {
            let clamped = min(max(newValue, observedWindowHoursMin), observedWindowHoursMax)
            UserDefaults.standard.set(clamped, forKey: Keys.observedWindowHours)
        }
    }

    /// The observed-agent window in seconds, for discovery/prune liveness
    /// checks. Reads `observedWindowHours` so it's safe off the main thread
    /// (UserDefaults is thread-safe), which discovery/prune require.
    nonisolated static var observedWindowSeconds: TimeInterval {
        TimeInterval(observedWindowHours) * 3600
    }

    // MARK: - Chat Visibility

    /// Per-kind visibility rules for the chat timeline. Persisted as
    /// JSON-encoded `ChatVisibilityRules` so adding a new kind is a
    /// backwards-compatible field addition (the decoder fills missing
    /// keys with defaults — see `ChatVisibilityRules.init(from:)`).
    static var chatVisibility: ChatVisibilityRules {
        get {
            guard let data = defaults.data(forKey: Keys.chatVisibility),
                  let decoded = try? JSONDecoder().decode(ChatVisibilityRules.self, from: data) else {
                return .defaults
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Keys.chatVisibility)
            }
        }
    }
}
