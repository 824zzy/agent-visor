//
//  ModelChip.swift
//  AgentVisor
//
//  Tiny inline badge showing the human-readable model name.
//  Used in the open-panel session rows and the pill hover popover.
//

import AgentVisorCore
import SwiftUI

struct ModelChip: View {
    let modelName: String?

    var body: some View {
        if let label = ModelDisplayName.format(modelName) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Catppuccin.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule()
                        .fill(Catppuccin.green.opacity(0.12))
                )
                .lineLimit(1)
        }
    }
}
