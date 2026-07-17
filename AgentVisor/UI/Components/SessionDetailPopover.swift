//
//  SessionDetailPopover.swift
//  AgentVisor
//
//  Compact session inspector shown on hover over a menu-bar pill.
//

import AgentVisorCore
import SwiftUI

struct SessionDetailPopover: View {
    let session: SessionState
    let shortcutPosition: Int?
    let shortcutModifierFamily: SessionShortcutModifierFamily

    private var contextWindow: Int {
        session.contextWindowTokens > 0
            ? session.contextWindowTokens
            : ModelContextWindow.tokens(for: session.modelName)
    }

    private var presentation: SessionHoverDetailPresentation {
        SessionHoverDetailPolicy.presentation(
            phase: inspectorPhase,
            sourceDisplayName: SessionHoverDetailPolicy.sourceDisplayName(
                agentID: session.agentID,
                terminalHost: session.terminalHost
            ),
            modelDisplayName: ModelDisplayName.format(session.modelName),
            effortLevel: session.effortLevel,
            permissionMode: session.permissionMode,
            codexApprovalPolicy: session.conversationInfo.lastCodexApprovalPolicy,
            codexSandboxPolicyType: session.conversationInfo.lastCodexSandboxPolicyType,
            contextTokens: session.lastContextTokens,
            contextWindowTokens: contextWindow,
            shortcutModifierFamily: shortcutModifierFamily,
            shortcutPosition: shortcutPosition
        )
    }

    private var statusTint: Color {
        sessionStatusColor(
            for: session.phase,
            idleAge: session.statusIdleAge,
            scheme: .adaptive
        )
    }

    private var contextTint: Color {
        switch presentation.context?.percentage ?? 0 {
        case ..<75: return Catppuccin.green
        case ..<90: return Catppuccin.yellow
        default: return Catppuccin.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)
                statusBadge
            }

            Divider()
                .overlay(ChatTheme.cardBorder.opacity(0.55))

            detailRow(
                label: "Latest turn",
                value: presentation.runtimeItems.joined(separator: " · ")
            )

            ForEach(presentation.detailRows, id: \.label) { row in
                detailRow(label: row.label, value: row.value)
            }

            detailRow(
                label: "Project",
                value: displayPath(session.cwd),
                monospaced: true,
                truncationMode: .middle
            )

            if let context = presentation.context {
                contextRow(context)
            }

            detailRow(
                label: "Activity",
                value: relativeTime(session.lastActivity)
            )

            if let shortcutLabel = presentation.shortcutLabel {
                Divider()
                    .overlay(ChatTheme.cardBorder.opacity(0.55))
                shortcutHint(shortcutLabel)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusTint)
                .frame(width: 6, height: 6)
            Text(presentation.statusTitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ChatTheme.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusTint.opacity(0.12))
        )
    }

    private func detailRow(
        label: String,
        value: String,
        monospaced: Bool = false,
        truncationMode: Text.TruncationMode = .tail
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
                .frame(width: 62, alignment: .leading)

            Text(value)
                .font(.system(size: 10, weight: .medium, design: monospaced ? .monospaced : .default))
                .foregroundColor(ChatTheme.secondary)
                .lineLimit(label == "Access" ? 2 : 1)
                .truncationMode(truncationMode)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func contextRow(_ context: SessionHoverContextPresentation) -> some View {
        HStack(spacing: 8) {
            Text("Context")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
                .frame(width: 62, alignment: .leading)

            Text("\(context.usedLabel) / \(context.windowLabel)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(ChatTheme.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Catppuccin.surface0)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(contextTint)
                        .frame(
                            width: max(
                                2,
                                geometry.size.width * CGFloat(context.percentage) / 100
                            )
                        )
                }
            }
            .frame(height: 6)

            Text("\(context.percentage)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(contextTint)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func shortcutHint(_ shortcutLabel: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)

            Text(shortcutLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(ChatTheme.primary)

            Text("Open directly")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(ChatTheme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var inspectorPhase: SessionInspectorPhase {
        switch session.phase {
        case .waitingForApproval: return .needsAttention
        case .waitingForInput: return .ready
        case .processing: return .working
        case .compacting: return .compacting
        case .idle: return .recent
        case .ended: return .ended
        }
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "Just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
