//
//  SourceChip.swift
//  AgentVisor
//
//  Inline badge showing which terminal host owns the session
//  (e.g. "Ghostty", "Cursor", "iTerm2"). Uses a neutral lavender
//  tint to distinguish from model (green) and mode (varies).
//

import AgentVisorCore
import SwiftUI

struct SourceChip: View {
    let agentID: AgentID
    let terminalHost: TerminalHost?

    var body: some View {
        if let host = SessionHostDisplayPolicy.displayHost(agentID: agentID, terminalHost: terminalHost),
           host != .unknown {
            let meta = HostMetadata.metadata(for: host)
            Text(meta.displayName)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Catppuccin.lavender)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(Catppuccin.lavender.opacity(0.12))
                )
                .lineLimit(1)
        }
    }
}
