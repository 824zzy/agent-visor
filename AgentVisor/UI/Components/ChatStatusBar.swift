//
//  ChatStatusBar.swift
//  AgentVisor
//
//  Ghostty-style status row that sits under the chat input.
//  Shows: model | effort | context bar % | project | usage bar %
//

import AppKit
import SwiftUI

struct ChatStatusBar: View {
    let modelDisplayName: String?
    let projectName: String
    let contextTokens: Int
    let contextWindow: Int
    let effortLevel: String?
    let useGlobalEffort: Bool
    let permissionMode: String?
    let onCycleMode: (() -> Void)?

    @ObservedObject private var settings = ClaudeSettings.shared
    @ObservedObject private var ccusage = CCUsageRunner.shared

    private var contextPercent: Double {
        guard contextWindow > 0 else { return 0 }
        return min(100, Double(contextTokens) / Double(contextWindow) * 100)
    }

    private var resolvedEffort: String? {
        if let effortLevel, !effortLevel.isEmpty {
            return effortLevel
        }
        guard useGlobalEffort else { return nil }
        return settings.effortLevel
    }

    var body: some View {
        HStack(spacing: 8) {
            modelChip
            UsageBar(percent: contextPercent, tint: Catppuccin.green)
                .frame(width: 64)
            Text("\(Int(contextPercent.rounded()))%")
                .chatScaledFont(size: 10, weight: .semibold, design: .monospaced)
                .foregroundColor(Catppuccin.green)
                .frame(width: 30, alignment: .leading)

            if permissionMode != nil {
                divider
                modeChip
            }

            divider

            Text(projectName)
                .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
                .foregroundColor(Catppuccin.lavender)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let pct = ccusage.activeBlockPercent {
                Text("Usage")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(Catppuccin.overlay)
                UsageBar(percent: pct, tint: Catppuccin.blue)
                    .frame(width: 64)
                Text("\(Int(pct.rounded()))%")
                    .chatScaledFont(size: 10, weight: .semibold, design: .monospaced)
                    .foregroundColor(Catppuccin.blue)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(ChatTheme.headerBg)
        .onAppear {
            settings.refresh()
            ccusage.refreshIfNeeded()
        }
    }

    @ViewBuilder
    private var modeChip: some View {
        if let raw = permissionMode {
            let known = PermissionMode(rawValue: raw)
            let label = known?.displayName ?? raw
            let color = known?.accentColor ?? Catppuccin.overlay
            if let onCycleMode = onCycleMode {
                ModeChipButton(label: label, color: color, onCycleMode: onCycleMode)
                    .help("Click or press Shift+Tab to cycle Claude Code mode")
            } else {
                // No cycle callback wired (editor-host sessions: cycling
                // depends on OSC 7 + AppleScript pane targeting which needs
                // a TTY). Show the mode as a static label so the user can
                // still see what mode claude is in, but without the
                // affordance that wouldn't do anything.
                Text(label)
                    .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .help("Cycle mode from inside Cursor (Shift+Tab in the chat input)")
            }
        }
    }

    @ViewBuilder
    private var modelChip: some View {
        if let display = modelDisplayName {
            HStack(spacing: 0) {
                Text(display)
                    .foregroundColor(Catppuccin.green)
                if let effort = resolvedEffort, !effort.isEmpty {
                    Text("|")
                        .foregroundColor(Catppuccin.surface1)
                        .padding(.horizontal, 3)
                    Text(effort)
                        .foregroundColor(Catppuccin.yellow)
                }
            }
            .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
            .lineLimit(1)
        } else if let effort = resolvedEffort, !effort.isEmpty {
            // No model resolved yet (new session, or only synthetic messages)
            // — still show the effort label so the bar doesn't go blank.
            Text(effort)
                .foregroundColor(Catppuccin.yellow)
                .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
                .lineLimit(1)
        }
    }

    private var divider: some View {
        Text("|")
            .chatScaledFont(size: 10, weight: .regular, design: .monospaced)
            .foregroundColor(Catppuccin.surface1)
    }
}

/// The cyclable mode chip — wraps the bare label in a hover pill so
/// users can SEE it's clickable. Hover only (no always-on border) to
/// keep the bar visually quiet at rest. Pointer cursor on hover plus
/// a faint surface-tinted background communicate the affordance.
private struct ModeChipButton: View {
    let label: String
    let color: Color
    let onCycleMode: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onCycleMode) {
            Text(label)
                .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
                .foregroundColor(color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isHovered ? Catppuccin.surface1.opacity(0.6) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            isHovered ? color.opacity(0.35) : Color.clear,
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

private struct UsageBar: View {
    let percent: Double  // 0-100
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Catppuccin.surface0)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * CGFloat(percent / 100)))
            }
        }
        .frame(height: 8)
    }
}
