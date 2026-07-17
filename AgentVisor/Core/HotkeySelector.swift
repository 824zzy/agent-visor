//
//  HotkeySelector.swift
//  AgentVisor
//
//  Manages global-hotkey settings selection state for the menu.
//

import AgentVisorCore
import Combine
import Foundation

@MainActor
class HotkeySelector: ObservableObject {
    static let shared = HotkeySelector()

    @Published var isPickerExpanded: Bool = false

    /// Source of truth lives in `AppSettings.hotkeyTrigger`. The selector
    /// mirrors it so SwiftUI views can observe changes without polling.
    @Published var trigger: HotkeyTrigger = AppSettings.hotkeyTrigger

    /// Active custom combo when `trigger == .custom`. Nil means the
    /// user picked Custom but hasn't recorded a shortcut yet.
    @Published var customCombo: KeyCombo? = AppSettings.customCombo

    private let rowHeight: CGFloat = 32
    private let maxVisibleOptions = HotkeyTrigger.allCases.count

    private init() {}

    /// Extra height needed when the picker is expanded.
    var expandedPickerHeight: CGFloat {
        guard isPickerExpanded else { return 0 }
        let visible = min(HotkeyTrigger.allCases.count, maxVisibleOptions)
        return CGFloat(visible) * rowHeight + 8
    }

    /// Persist a selection and notify the running HotkeyManager.
    func setTrigger(_ newTrigger: HotkeyTrigger) {
        AppSettings.hotkeyTrigger = newTrigger
        trigger = newTrigger
        HotkeyManager.shared.applyTrigger(newTrigger)
    }

    /// Record a new custom combo. Persists, mirrors locally, and asks
    /// the running HotkeyManager to re-apply if the user is currently
    /// on the Custom mode (otherwise the new combo waits until they
    /// switch to it).
    func setCustomCombo(_ combo: KeyCombo) {
        AppSettings.customCombo = combo
        customCombo = combo
        if trigger == .custom {
            HotkeyManager.shared.applyTrigger(.custom)
        }
    }
}
