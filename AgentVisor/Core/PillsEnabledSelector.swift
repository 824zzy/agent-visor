//
//  PillsEnabledSelector.swift
//  AgentVisor
//
//  Live mirror of `AppSettings.pillsEnabled`. PillsStripWindow listens
//  via Combine and shows/hides itself when the toggle flips.
//

import Combine
import Foundation

@MainActor
final class PillsEnabledSelector: ObservableObject {
    static let shared = PillsEnabledSelector()

    @Published var enabled: Bool = AppSettings.pillsEnabled

    private init() {}

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        AppSettings.pillsEnabled = value
        enabled = value
    }
}
