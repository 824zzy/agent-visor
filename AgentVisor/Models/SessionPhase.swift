//
//  SessionPhase.swift
//  AgentVisor
//
//  Explicit state machine for Claude session lifecycle.
//  All state transitions are validated before being applied.
//

import AgentVisorCore
import Foundation

enum SessionPhaseEvidenceSource: String, Equatable, Sendable {
    case hook
    case transcriptMarker
    case transcriptHeuristic
    case rediscovery
    case localAction
}

/// Permission context for tools waiting for approval
struct PermissionContext: Sendable {
    let toolUseId: String
    let toolName: String
    let toolInput: [String: AnyCodable]?
    let receivedAt: Date
    /// Presence-only gate for the third "Yes, and don't ask again…"
    /// approval option. Mirrors `HookEvent.permissionSuggestions`:
    /// nil → claude-code's TUI hid option 2 (unsafe compound,
    /// ineligible tool) so we hide too; non-nil → safe to show, but
    /// the label + rule are derived locally by `PermissionSuggestionBuilder`
    /// (the array's contents are routinely Read rules even for Bash
    /// invocations and don't match what the user expects).
    let permissionSuggestions: [AnyCodable]?

    nonisolated init(
        toolUseId: String,
        toolName: String,
        toolInput: [String: AnyCodable]?,
        receivedAt: Date,
        permissionSuggestions: [AnyCodable]? = nil
    ) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.toolInput = toolInput
        self.receivedAt = receivedAt
        self.permissionSuggestions = permissionSuggestions
    }

    /// Format tool input for display.
    /// Renders strings in full — the approval bar wraps the result in a
    /// scrollable container so the user sees exactly what the terminal would
    /// show, no silent truncation. Stable key order so the same input always
    /// renders identically.
    nonisolated var formattedInput: String? {
        guard let input = toolInput else { return nil }
        let sortedKeys = input.keys.sorted()
        var parts: [String] = []
        for key in sortedKeys {
            guard let value = input[key] else { continue }
            let valueStr: String
            switch value.value {
            case let str as String:
                valueStr = str
            case let num as Int:
                valueStr = String(num)
            case let num as Double:
                valueStr = String(num)
            case let bool as Bool:
                valueStr = bool ? "true" : "false"
            default:
                valueStr = "\(value.value)"
            }
            parts.append("\(key): \(valueStr)")
        }
        return parts.joined(separator: "\n")
    }
}

extension PermissionContext: Equatable {
    nonisolated static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        // Compare by identity fields only (AnyCodable doesn't conform to Equatable)
        lhs.toolUseId == rhs.toolUseId &&
        lhs.toolName == rhs.toolName &&
        lhs.receivedAt == rhs.receivedAt
    }
}

/// Explicit session phases - the state machine
enum SessionPhase: Sendable {
    /// Session is idle, waiting for user input or new activity
    case idle

    /// Claude is actively processing (running tools, generating response)
    case processing

    /// Claude has finished and is waiting for user input
    case waitingForInput

    /// A tool is waiting for user permission approval
    case waitingForApproval(PermissionContext)

    /// Context is being compacted (auto or manual)
    case compacting

    /// Session has ended
    case ended

    // MARK: - State Machine Transitions

    /// Check if a transition to the target phase is valid
    nonisolated func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        // Terminal state - no transitions out
        case (.ended, _):
            return false

        // Any state can transition to ended
        case (_, .ended):
            return true

        // Idle transitions
        case (.idle, .processing):
            return true
        case (.idle, .waitingForApproval):
            return true  // Direct permission request on idle session
        case (.idle, .waitingForInput):
            return true  // Observed agent discovered already finished a turn
        case (.idle, .compacting):
            return true

        // Processing transitions
        case (.processing, .waitingForInput):
            return true
        case (.processing, .waitingForApproval):
            return true
        case (.processing, .compacting):
            return true
        case (.processing, .idle):
            return true  // Interrupt or quick completion

        // WaitingForInput transitions
        case (.waitingForInput, .processing):
            return true
        case (.waitingForInput, .idle):
            return true  // Can become idle
        case (.waitingForInput, .compacting):
            return true

        // WaitingForApproval transitions
        case (.waitingForApproval, .processing):
            return true  // Approved - tool will run
        case (.waitingForApproval, .idle):
            return true  // Denied or cancelled
        case (.waitingForApproval, .waitingForInput):
            return true  // Denied and Claude stopped
        case (.waitingForApproval, .waitingForApproval):
            return true  // Another tool needs approval (multiple pending permissions)

        // Compacting transitions
        case (.compacting, .processing):
            return true
        case (.compacting, .idle):
            return true
        case (.compacting, .waitingForInput):
            return true

        // Allow staying in same state (no-op transitions)
        default:
            return self == next
        }
    }

    /// Attempt to transition to a new phase, returns the new phase if valid
    nonisolated func transition(to next: SessionPhase) -> SessionPhase? {
        canTransition(to: next) ? next : nil
    }

    /// Whether this phase indicates the session needs user attention
    nonisolated var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput:
            return true
        default:
            return false
        }
    }

    /// Whether this phase indicates active processing
    nonisolated var isActive: Bool {
        switch self {
        case .processing, .compacting:
            return true
        default:
            return false
        }
    }

    /// Display ordering priority used by compact menu-bar pills.
    /// Lower numbers sort first.
    nonisolated var displayPriority: Int {
        switch self {
        case .waitingForApproval: return 0
        case .processing, .compacting: return 1
        case .waitingForInput: return 2
        case .idle, .ended: return 3
        }
    }

    /// Whether this is a waitingForApproval phase
    nonisolated var isWaitingForApproval: Bool {
        if case .waitingForApproval = self {
            return true
        }
        return false
    }

    /// Extract tool name if waiting for approval
    nonisolated var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self {
            return ctx.toolName
        }
        return nil
    }
}

// MARK: - Equatable

extension SessionPhase: Equatable {
    nonisolated static func == (lhs: SessionPhase, rhs: SessionPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.processing, .processing): return true
        case (.waitingForInput, .waitingForInput): return true
        case (.waitingForApproval(let ctx1), .waitingForApproval(let ctx2)):
            return ctx1 == ctx2
        case (.compacting, .compacting): return true
        case (.ended, .ended): return true
        default: return false
        }
    }
}

// MARK: - Debug Description

extension SessionPhase: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .idle:
            return "idle"
        case .processing:
            return "processing"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForApproval(let ctx):
            return "waitingForApproval(\(ctx.toolName))"
        case .compacting:
            return "compacting"
        case .ended:
            return "ended"
        }
    }
}
