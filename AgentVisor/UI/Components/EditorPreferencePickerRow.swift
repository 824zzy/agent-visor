//
//  EditorPreferencePickerRow.swift
//  AgentVisor
//
//  Settings row for which editor file-link clicks open files in.
//  Mirrors the look-and-feel of `FullScreenPolicyPickerRow` /
//  `SoundPickerRow`: a collapsed summary that expands an inline
//  option list. Greys out editors that aren't installed (so the
//  user doesn't pin a non-existent app and wonder why nothing
//  opens).
//

import AppKit
import SwiftUI

struct EditorPreferencePickerRow: View {
    @ObservedObject var selector: EditorPreferenceSelector
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
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("Open files in")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    Text(selector.preference.displayLabel)
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
                    ForEach(EditorPreference.allCases, id: \.self) { option in
                        EditorPreferenceOptionRow(
                            preference: option,
                            isSelected: selector.preference == option,
                            isInstalled: Self.isInstalled(option)
                        ) {
                            selector.setPreference(option)
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

    /// Whether the option's bundle id resolves to an installed app.
    /// `.auto` and `.systemDefault` are always "installed" — they
    /// don't pin a single app.
    fileprivate static func isInstalled(_ preference: EditorPreference) -> Bool {
        guard let bundleID = preference.bundleID else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

private struct EditorPreferenceOptionRow: View {
    let preference: EditorPreference
    let isSelected: Bool
    let isInstalled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Catppuccin.surface2)
                    .frame(width: 6, height: 6)

                Text(preference.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(labelColor)

                if !isInstalled {
                    Text("Not installed")
                        .font(.system(size: 10))
                        .foregroundColor(ChatTheme.tertiary)
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

    private var labelColor: Color {
        if !isInstalled {
            return ChatTheme.tertiary
        }
        return isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}
