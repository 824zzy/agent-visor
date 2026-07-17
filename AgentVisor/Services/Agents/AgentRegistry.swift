//
//  AgentRegistry.swift
//  AgentVisor
//
//  Static dispatch from AgentID to AgentProvider. Mirrors the
//  TerminalAdapterRegistry shape: callers ask for the provider by id
//  and stay agnostic to which concrete agent answers.
//

import Foundation
import AgentVisorCore

enum AgentRegistry {
    /// All known agent providers, in install order.
    nonisolated static let all: [any AgentProvider] = [
        ClaudeCodeAgentProvider(),
        AuggieAgentProvider(),
        CodexAgentProvider(),
        CursorAgentProvider(),
    ]

    /// Provider for a specific agent id, or nil if unsupported.
    nonisolated static func provider(for id: AgentID) -> (any AgentProvider)? {
        all.first { $0.id == id }
    }

    /// The provider used when an event arrives without an explicit
    /// agent stamp. Today that means a hook script that predates the
    /// multi-agent migration — i.e. claude-code's bundled script.
    nonisolated static var defaultProvider: any AgentProvider {
        ClaudeCodeAgentProvider()
    }
}
