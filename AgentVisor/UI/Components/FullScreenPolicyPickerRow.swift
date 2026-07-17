//
//  FullScreenPolicyPickerRow.swift
//  AgentVisor
//
//  Settings-menu row for the full-screen pill-hide policy. Three-way
//  picker matching the style of `SoundPickerRow` / `HotkeyPickerRow`:
//  collapsed row shows the active selection; tapping expands an
//  inline option list.
//

import AppKit
import AgentVisorCore
import SwiftUI

struct FullScreenPolicyPickerRow: View {
    @ObservedObject var selector: FullScreenPolicySelector
    @State private var isHovered = false

    private var isExpanded: Bool {
        selector.isPickerExpanded
    }

    private func setExpanded(_ value: Bool) {
        selector.isPickerExpanded = value
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!isExpanded)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Full-screen Pills")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selector.policy.displayLabel)
                        .font(.system(size: 11))
                        .foregroundColor(ChatTheme.tertiary)
                        .lineLimit(1)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(ChatTheme.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Catppuccin.surface0.opacity(0.6) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(FullScreenPolicy.allCases, id: \.self) { option in
                        FullScreenPolicyOptionRow(
                            policy: option,
                            isSelected: selector.policy == option
                        ) {
                            selector.setPolicy(option)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
    }

    private var textColor: Color {
        isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}

private struct FullScreenPolicyOptionRow: View {
    let policy: FullScreenPolicy
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Catppuccin.surface2)
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(policy.displayLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHovered ? ChatTheme.primary : ChatTheme.secondary)

                    Text(policy.displayDetail)
                        .font(.system(size: 10))
                        .foregroundColor(ChatTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Catppuccin.surface0.opacity(0.4) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
