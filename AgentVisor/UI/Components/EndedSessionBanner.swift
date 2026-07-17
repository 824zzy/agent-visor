//
//  EndedSessionBanner.swift
//  AgentVisor
//
//  Replaces the composer for sessions that can't accept input from
//  agent-visor — either because the cli process exited (the .ended
//  phase) or because the session lives inside an opaque host (Cursor's
//  IDE Agents Window) where we have no programmatic send path.
//

import AgentVisorCore
import SwiftUI

enum EndedSessionBannerKind {
    /// The cli/agent process has exited. Re-attach a terminal to bring
    /// it back to life.
    case ended
    /// The session lives inside an opaque host's chat surface (Cursor's
    /// IDE Agents Window webview, Zed's GPUI thread pane). The host
    /// either has no public IPC or its input is a webview/Chromium
    /// contenteditable that AX can't reach. Read-only is the honest
    /// contract — the host name is surfaced so users know WHERE to type.
    case readOnlyIDE(host: TerminalHost?)
    /// The session is owned by a standalone agent app (Codex.app) that
    /// agent-visor observes but can't drive. Unlike `readOnlyIDE`, the
    /// owning app can be focused directly, so the banner offers a
    /// "Continue in <app>" action (wired by the caller).
    case readOnlyAgentApp
    case controlSurface(decision: AgentControlSurfaceDecision)
}

struct EndedSessionBanner: View {
    let agent: AgentID
    let kind: EndedSessionBannerKind
    /// Optional trailing action. When set, the banner renders a button
    /// (labelled `continueLabel`) — used by the agent-app read-only case
    /// to focus the owning app.
    let onContinue: (() -> Void)?
    let continueLabel: String?
    /// When true, the banner reads as "waiting for your approval" (yellow
    /// attention icon + approval copy) instead of the plain read-only
    /// message. Used for observed agents (Codex) whose phase is
    /// `.waitingForApproval` but whose approve/deny we can't drive — the
    /// user must answer in the owning app, so we surface the state and
    /// keep the focus button.
    let awaitingApproval: Bool

    init(
        agent: AgentID,
        kind: EndedSessionBannerKind = .ended,
        awaitingApproval: Bool = false,
        onContinue: (() -> Void)? = nil,
        continueLabel: String? = nil
    ) {
        self.agent = agent
        self.kind = kind
        self.awaitingApproval = awaitingApproval
        self.onContinue = onContinue
        self.continueLabel = continueLabel
    }

    private var agentName: String {
        switch agent {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .auggie: return "Auggie"
        }
    }

    /// Host display name for the read-only banner. Zed-hosted sessions
    /// say "Zed", Cursor's IDE Agents Window says "Cursor". Fallback
    /// "Host" for unknown hosts (defensive — every readOnlyIDE call
    /// site passes a real host today).
    private var hostDisplayName: String {
        guard case .readOnlyIDE(let host) = kind else { return "Host" }
        switch host {
        case .zed: return "Zed"
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .claudeDesktop: return "Claude Desktop"
        case .codexApp: return "Codex"
        case .ghostty, .iterm2, .terminalApp, .unknown, .none:
            return "Host"
        }
    }

    private var headline: String {
        if case .controlSurface(let decision) = kind {
            return decision.headline
        }
        if awaitingApproval {
            return "\(agentName) is waiting for your approval"
        }
        switch kind {
        case .ended:
            return "\(agentName) session has ended"
        case .readOnlyIDE(let host):
            switch host {
            case .zed:
                return "Zed thread — read-only"
            case .cursor:
                return "Cursor IDE Agents Window — read-only"
            default:
                return "\(hostDisplayName) — read-only"
            }
        case .readOnlyAgentApp:
            return "\(agentName) thread — read-only"
        case .controlSurface:
            return ""
        }
    }

    private var detail: String {
        if case .controlSurface(let decision) = kind {
            return decision.detail
        }
        if awaitingApproval {
            return "\(agentName) paused on a tool approval. Approve or deny it in the \(agentName) app; agent-visor mirrors the result here."
        }
        switch kind {
        case .ended:
            return "Chat history is preserved. Re-attach by running the CLI in this project's directory."
        case .readOnlyIDE(let host):
            switch host {
            case .zed:
                return "Zed's thread pane doesn't expose a public input. Type your query inside Zed; agent-visor will mirror the transcript."
            case .cursor:
                return "Cursor's Agents Window doesn't expose a public input. Type your query inside Cursor; agent-visor will mirror the transcript."
            default:
                return "\(hostDisplayName) doesn't expose a public input. Type your query inside \(hostDisplayName); agent-visor will mirror the transcript."
            }
        case .readOnlyAgentApp:
            return "This thread runs in the \(agentName) app. Open it there to continue; agent-visor mirrors the transcript here."
        case .controlSurface:
            return ""
        }
    }

    private var iconName: String {
        if case .controlSurface(let decision) = kind {
            return decision.primaryAction == .approveInOwnerApp ? "exclamationmark.circle.fill" : "eye"
        }
        if awaitingApproval { return "exclamationmark.circle.fill" }
        switch kind {
        case .ended: return "moon.zzz"
        case .readOnlyIDE, .readOnlyAgentApp: return "eye"
        case .controlSurface: return "eye"
        }
    }

    /// Yellow attention tint when awaiting approval, matching the status
    /// dot's `waitingForApproval` color; otherwise the muted tertiary.
    private var iconColor: Color {
        if case .controlSurface(let decision) = kind, decision.primaryAction == .approveInOwnerApp {
            return BrandColors.statusYellow
        }
        return awaitingApproval ? BrandColors.statusYellow : ChatTheme.tertiary
    }

    /// Convenience initializer for the legacy `kind: .readOnlyIDE` call
    /// sites that didn't supply a host. Keeps WindowChatView's previous
    /// shape working while the host-aware variant is rolled out.
    static func readOnly(agent: AgentID, host: TerminalHost?) -> EndedSessionBanner {
        EndedSessionBanner(agent: agent, kind: .readOnlyIDE(host: host))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .chatScaledFont(size: 12, weight: .medium)
                    .foregroundColor(ChatTheme.secondary)
                Text(detail)
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let onContinue, let continueLabel {
                Button(action: onContinue) {
                    HStack(spacing: 4) {
                        Text(continueLabel)
                            .chatScaledFont(size: 11, weight: .medium)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(Catppuccin.lavender)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Catppuccin.lavender.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Catppuccin.lavender.opacity(0.35), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Catppuccin.surface0.opacity(0.6))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
