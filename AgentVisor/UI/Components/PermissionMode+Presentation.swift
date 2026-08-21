//
//  PermissionMode+Presentation.swift
//  AgentVisor
//
//  Colour for a permission mode. The mode is domain vocabulary and lives in
//  AgentVisorCore; naming a palette entry is presentation, so it stays here.
//

import SwiftUI
import AgentVisorCore

extension PermissionMode {
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
}
