//
//  WindowSidebarRow.swift
//  AgentVisor
//
//  Window-mode sidebar row. Composes the same primitives the notch's
//  `InstanceRow` uses (SessionStatusDot, SourceChip, IconButton,
//  inline approval), but tailored for a wide top-down list:
//      * Only SourceChip is rendered (model + permission chips
//        belong in the chat detail pane, not in a navigation row).
//      * Title is the session-distinguishing string (sessionName or
//        first user message preview), since the project name lives
//        in the section header instead of the row.
//      * Action icons (chat / terminal) are hover-only.
//

import AgentVisorCore
import SwiftUI

struct WindowSidebarRow: View {
    let session: SessionState
    let projectName: String?
    /// 0-based position in the flat sidebar — rows 0..8 carry a
    /// ⌘1..⌘9 badge that fades in while ⌘ is held. nil for rows
    /// 9+ (no hotkey assignment) and for the "no row exists" path.
    let hotkeyPosition: Int?
    /// True while ⌘ is held. Passed in from the sidebar container,
    /// NOT observed locally — observing `CommandKeyMonitor.shared`
    /// directly here would re-render every visible row on every
    /// modifier event (shift, option, etc.), turning a single ⌘
    /// press into N body evaluations × per-row downstream
    /// invalidations. Slow on big sidebars and visible as UI lag.
    /// Container-side observation lets SwiftUI's view diffing skip
    /// rows where the value didn't actually change (rows past
    /// position 8 always get `false` and never re-render on ⌘).
    let isCommandHeld: Bool
    let isSelected: Bool
    /// Whether removing this row deletes its transcript or only hides it —
    /// decided by `MainWindowViewModel.deletability(for:)`. Drives the hover
    /// button's icon (`trash` vs `xmark`) and which closure fires.
    let deletability: SessionDeletability
    let onChat: () -> Void
    /// Hide this session locally (reversible). Fires for `.hideOnly` rows.
    let onHide: () -> Void
    /// Delete this session's transcript (irreversible, confirmed). Fires for
    /// `.deletableTranscript` rows.
    let onDelete: () -> Void

    @State private var isHovered = false
    /// Tracks hover over the trailing removal button specifically (not the
    /// whole row) so the descriptive tooltip chip only appears once the
    /// cursor is actually on the button — Codex's "Archive chat" pattern.
    @State private var isRemovalButtonHovered = false
    @ObservedObject private var titleStore = CursorSessionTitleStore.shared

    /// Short, action-specific label for the removal button's tooltip +
    /// VoiceOver. Mirrors the icon: trash → delete, × → hide.
    private var removalActionLabel: String {
        deletability == .deletableTranscript ? "Delete transcript" : "Hide session"
    }

    /// Width reserved for the trailing slot, decided by
    /// [[SidebarTrailingSlotMetrics]]. Approval mode is wider; all
    /// other variants share the stable width so swapping content
    /// doesn't reflow the row.
    private var trailingSlotWidth: CGFloat {
        let variant: SidebarTrailingSlotMetrics.Variant
        if isCommandHeld, hotkeyPosition != nil {
            variant = .commandBadge
        } else {
            variant = .timestamp
        }
        return SidebarTrailingSlotMetrics.reservedWidth(for: variant)
    }

    /// Row title — prefer the user-set sessionName ⟶ Cursor's
    /// extension title ⟶ first user message preview ⟶ a "New
    /// session" placeholder when none of those exist yet (most
    /// commonly: a Claude Code session that registered via the
    /// MCP `initialize` hook before any user turn was sent, so
    /// no JSONL has been written to ~/.claude/projects yet).
    /// We deliberately NOT fall back to project name; that's
    /// already in the section header above. We also don't show
    /// the bare 8-char session id — it reads as "broken" rather
    /// than "fresh", and is meaningless to the user.
    private var rowTitle: String {
        SessionRowTitleResolver.title(for: session, titleStore: titleStore)
    }

    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    private var isInteractiveTool: Bool {
        guard let toolName = session.pendingToolName else { return false }
        return toolName == "AskUserQuestion"
    }

    /// Compact relative-time chip ("23h", "1w") rendered at the
    /// trailing edge when the row isn't hovered/in-approval. Uses
    /// `SidebarRecency.sortDate` — the exact key `MainWindowViewModel`
    /// sorts rows by — so the visible chip and row order stay monotonic
    /// (no "23h" appearing above "2h").
    private var relativeTimestampLabel: String? {
        let date = SidebarRecency.sortDate(
            lastActivityDate: session.lastActivityDate,
            lastUserMessageDate: session.lastUserMessageDate,
            lastActivity: session.lastActivity
        )
        return RelativeTimestampFormatter.format(since: date)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Status accent stripe at the leading edge. Overlay-style
            // (3pt thin rounded bar) — replaces the `SessionStatusDot`
            // that previously occupied a horizontal slot here.
            SessionStatusStripe(session: session)

            AgentStatusBadge(session: session, pointSize: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rowTitle)
                        .chatScaledFont(size: 13, weight: .medium)
                        .foregroundColor(ChatTheme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    SourceChip(agentID: session.agentID, terminalHost: session.terminalHost)
                    if session.agentID == .codex,
                       session.codexControlCapability == .connected {
                        Text("Connected")
                            .chatScaledFont(size: 10, weight: .medium)
                            .foregroundColor(ChatTheme.statusSuccess)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Catppuccin.green.opacity(0.12))
                            )
                    }
                    if let projectName, !projectName.isEmpty {
                        Text(projectName)
                            .chatScaledFont(size: 10, weight: .medium)
                            .foregroundColor(ChatTheme.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Catppuccin.surface1.opacity(0.7))
                            )
                    }
                }

                subtitle
            }

            Spacer(minLength: 4)

            // The sidebar is navigation-only: a pending approval is
            // flagged by the leading status stripe + amber subtitle, but
            // approve/deny is actioned in the chat detail pane (which
            // shows the full command). The trailing slot carries the
            // relative-timestamp chip ("23h", "1w") or the ⌘N badge while
            // ⌘ is held. The slot reserves a fixed width via
            // [[SidebarTrailingSlotMetrics]] so swaps don't reflow rows.
            Group {
                if isHovered, !isCommandHeld {
                    // Hover affordance: remove this session. Trash when we can
                    // delete the transcript (non-live Claude Code), × otherwise
                    // (Codex/Cursor/Zed or a live Claude session → hide). The
                    // Button swallows its own click so the row's onTapGesture
                    // (select) doesn't also fire.
                    Button(action: removeSession) {
                        Image(systemName: deletability == .deletableTranscript ? "trash" : "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(ChatTheme.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(removalActionLabel)
                    .onHover { isRemovalButtonHovered = $0 }
                } else if isCommandHeld, let pos = hotkeyPosition {
                    // ⌘N badge replaces the timestamp slot while ⌘ is
                    // held. No layout shift — same anchor, same size
                    // bracket. Only renders for rows 0..8 (positions
                    // 9+ have no hotkey).
                    // Scope the fade animation to JUST this branch's
                    // value, never the outer ZStack — see
                    // [[feedback_lazyvstack_count_animation]] for why
                    // wrapping LazyVStack in animation cascades into a
                    // 99% CPU pin.
                    Text("⌘\(pos + 1)")
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(ChatTheme.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Catppuccin.surface1)
                        )
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.10), value: isCommandHeld)
                } else if let label = relativeTimestampLabel {
                    Text(label)
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.10), value: isCommandHeld)
                }
            }
            .frame(
                minWidth: trailingSlotWidth,
                alignment: .trailing
            )
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        // Codex-style "Archive chat" tooltip: a styled chip floating just
        // above the row, its trailing edge at the row's right edge so the
        // removal icon (×/trash, ~10pt inset) tucks under the bubble's
        // right portion — instead of the bubble hanging far to the icon's
        // left. Anchored on the whole row (after trailing padding) so it
        // reuses that 10pt as rightward room; lifted clear of the row so
        // it overlaps the gap above, like Codex. Non-hit-testing so it
        // never eats the button's click; replaces the slow `.help`.
        .overlay(alignment: .topTrailing) {
            if isHovered, isRemovalButtonHovered, !isCommandHeld {
                removalTooltip
                    .fixedSize()
                    .offset(x: -2, y: -22)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.10), value: isRemovalButtonHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onChat() }
        .focusable()
        .onKeyPress(.return) {
            onChat()
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onChat() }
        .accessibilityAction(named: removalActionLabel) { removeSession() }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.gray.opacity(0.20)
                       : (isHovered ? Color.gray.opacity(0.08) : Color.clear))
        )
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isWaitingForApproval)
    }

    private func removeSession() {
        switch deletability {
        case .deletableTranscript: onDelete()
        case .hideOnly: onHide()
        }
    }

    /// Styled tooltip chip shown above the removal button on hover.
    /// Catppuccin surface card with a hairline border, matching the
    /// app's other floating chrome (no system-yellow tooltip look).
    private var removalTooltip: some View {
        Text(removalActionLabel)
            .chatScaledFont(size: 11, weight: .medium)
            .foregroundColor(ChatTheme.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Catppuccin.surface1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(ChatTheme.cardBorder, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            )
    }

    @ViewBuilder
    private var subtitle: some View {
        if isWaitingForApproval {
            HStack(spacing: 4) {
                if let toolName = PendingActionPresentation.contextualToolName(session.pendingToolName) {
                    Text(MCPToolFormatter.formatToolName(toolName))
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(TerminalColors.amber.opacity(0.9))
                }
                if isInteractiveTool || PendingActionPresentation.contextualToolName(session.pendingToolName) == nil {
                    Text("Needs your input")
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary)
                        .lineLimit(1)
                } else if let input = session.pendingToolInput {
                    Text(input)
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary)
                        .lineLimit(1)
                }
            }
        } else if let role = session.lastMessageRole {
            switch role {
            case "tool":
                HStack(spacing: 4) {
                    if let toolName = session.lastToolName {
                        Text(MCPToolFormatter.formatToolName(toolName))
                            .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                            .foregroundColor(ChatTheme.tertiary)
                    }
                    if let input = session.lastMessage {
                        Text(input)
                            .chatScaledFont(size: 11)
                            .foregroundColor(ChatTheme.tertiary)
                            .lineLimit(1)
                    }
                }
            case "user":
                HStack(spacing: 4) {
                    Text("You:")
                        .chatScaledFont(size: 11, weight: .medium)
                        .foregroundColor(ChatTheme.tertiary)
                    if let msg = session.lastMessage {
                        Text(SessionActivityExcerptFormatter.singleLine(msg))
                            .chatScaledFont(size: 11)
                            .foregroundColor(ChatTheme.tertiary)
                            .lineLimit(1)
                    }
                }
            default:
                if let msg = session.lastMessage {
                    Text(SessionActivityExcerptFormatter.singleLine(msg))
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary)
                        .lineLimit(1)
                }
            }
        } else if let lastMsg = session.lastMessage {
            Text(SessionActivityExcerptFormatter.singleLine(lastMsg))
                .chatScaledFont(size: 11)
                .foregroundColor(ChatTheme.tertiary)
                .lineLimit(1)
        }
    }
}

enum SessionRowTitleResolver {
    static func title(
        for session: SessionState,
        titleStore: CursorSessionTitleStore
    ) -> String {
        if let name = session.sessionName, !name.isEmpty {
            return name
        }
        if session.origin == .cursorObserved,
           let cursorTitle = titleStore.title(forSessionId: session.sessionId),
           !cursorTitle.isEmpty {
            return cursorTitle
        }
        if let firstUser = session.conversationInfo.firstUserMessage, !firstUser.isEmpty {
            return String(SessionActivityExcerptFormatter.singleLine(firstUser).prefix(50))
        }
        if session.terminalHost == .claudeDesktop {
            return "Claude Desktop helper"
        }
        return "New session"
    }
}
