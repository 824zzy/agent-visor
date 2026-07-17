//
//  ChatVisibilitySelector.swift
//  AgentVisor
//
//  Live mirror of `AppSettings.chatVisibility`. SwiftUI views observe
//  this so toggling a kind in Settings re-renders the chat without a
//  relaunch.
//
//  Source of truth lives in `AppSettings`; this object delegates writes
//  there and republishes for observation. Same shape as
//  `AppearanceSelector` / `FullScreenPolicySelector`.
//

import AgentVisorCore
import Combine
import Foundation

@MainActor
final class ChatVisibilitySelector: ObservableObject {
    static let shared = ChatVisibilitySelector()

    @Published var rules: ChatVisibilityRules = AppSettings.chatVisibility

    private init() {}

    func update(_ mutate: (inout ChatVisibilityRules) -> Void) {
        var next = rules
        mutate(&next)
        guard next != rules else { return }
        AppSettings.chatVisibility = next
        rules = next
    }

    func resetToDefaults() {
        guard rules != .defaults else { return }
        AppSettings.chatVisibility = .defaults
        rules = .defaults
    }
}
