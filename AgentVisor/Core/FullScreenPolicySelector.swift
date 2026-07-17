//
//  FullScreenPolicySelector.swift
//  AgentVisor
//
//  Manages the full-screen pill visibility setting. Source of truth is
//  `AppSettings.fullScreenPolicy`.
//

import Combine
import Foundation

@MainActor
final class FullScreenPolicySelector: ObservableObject {
    static let shared = FullScreenPolicySelector()

    /// Mirrors `AppSettings.fullScreenPolicy` so every mounted pill surface
    /// updates immediately when the preference changes.
    @Published var policy: FullScreenPolicy = AppSettings.fullScreenPolicy

    /// Drives the menu picker's collapsed/expanded chrome, mirrored on
    /// other selectors via the same `isPickerExpanded` name.
    @Published var isPickerExpanded: Bool = false

    private init() {}

    func setPolicy(_ newPolicy: FullScreenPolicy) {
        guard newPolicy != policy else { return }
        AppSettings.fullScreenPolicy = newPolicy
        policy = newPolicy
    }
}
