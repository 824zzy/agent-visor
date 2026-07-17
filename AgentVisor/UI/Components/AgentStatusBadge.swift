//
//  AgentStatusBadge.swift
//  AgentVisor
//
//  Agent identity badge used in the window-mode sidebar. Renders the
//  agent's brand glyph (Claude / Codex / Cursor / Auggie) inside a
//  tinted circular background. Status is conveyed elsewhere — by the
//  row's left-edge accent stripe (`SessionStatusStripe`) — so this
//  view is pure identity: glyph + tint, no ring, no motion.
//
//  Replaces the dual `SessionStatusDot` + `AgentChip` pair that
//  previously occupied separate slots in the row. Splitting status
//  off into a row-edge stripe frees the badge to carry agent
//  identity at a larger, more recognizable size and keeps motion
//  off the high-density part of the row.
//

import AgentVisorCore
import SwiftUI

struct AgentStatusBadge: View {
    let session: SessionState
    /// Total chip size. Sidebar uses 22 — large enough that the brand
    /// mark inside the rounded square reads cleanly without crowding
    /// the row's vertical rhythm.
    var pointSize: CGFloat = 22

    var body: some View {
        AgentBrandLogo(agent: session.agentID, size: pointSize)
    }
}

// MARK: - Agent brand metadata

enum AgentBrand {
    static func tint(for agent: AgentID) -> Color {
        switch agent {
        case .claudeCode: return BrandColors.claudeOrange
        case .codex:      return Catppuccin.green
        case .cursor:     return Catppuccin.sky
        case .auggie:     return Catppuccin.yellow
        }
    }
}
