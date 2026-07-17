//
//  PermissionModeChip.swift
//  AgentVisor
//
//  Inline badge showing non-default permission modes (plan, auto, bypass,
//  accept-edits). Hidden when mode is nil or "default". Mirrors the style
//  of the mode chip in ChatStatusBar so the visual vocabulary is
//  consistent between the chat footer and the session row.
//

import SwiftUI

struct PermissionModeChip: View {
    let permissionMode: String?

    var body: some View {
        if let raw = permissionMode,
           let known = PermissionMode(rawValue: raw),
           known != .default {
            Text(known.displayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(known.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(known.accentColor.opacity(0.12))
                )
                .lineLimit(1)
        }
    }
}
