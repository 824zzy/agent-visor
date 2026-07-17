//
//  PermissionMode.swift
//  AgentVisor
//
//  Claude Code permission/mode states. Tracked per-session by reading
//  `{"type":"permission-mode","permissionMode":"<mode>"}` lines from the
//  session JSONL.
//

import SwiftUI

enum PermissionMode: String, Sendable, CaseIterable {
    case `default`         = "default"
    case acceptEdits       = "acceptEdits"
    case plan              = "plan"
    case bypassPermissions = "bypassPermissions"
    case auto              = "auto"

    /// Compact label for the status bar chip.
    var displayName: String {
        switch self {
        case .default:           return "default"
        case .acceptEdits:       return "accept edits"
        case .plan:              return "plan"
        case .bypassPermissions: return "bypass"
        case .auto:              return "auto"
        }
    }

    /// Catppuccin accent ordered roughly by danger / autonomy level.
    var accentColor: Color {
        switch self {
        case .default:           return Catppuccin.overlay
        case .plan:              return Catppuccin.blue
        case .acceptEdits:       return Catppuccin.yellow
        case .auto:              return Catppuccin.mauve
        case .bypassPermissions: return Catppuccin.red
        }
    }

    /// Resolve a raw JSONL string. Returns nil for unknown values so the
    /// caller can render the raw string with a neutral fallback instead of
    /// crashing on a future Claude Code mode value we don't know about.
    static func from(raw: String?) -> PermissionMode? {
        guard let raw = raw else { return nil }
        return PermissionMode(rawValue: raw)
    }
}
