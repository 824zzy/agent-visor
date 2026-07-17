//
//  WindowSettingsView.swift
//  AgentVisor
//
//  Row primitives shared by SettingsWindowView. The standalone popover
//  was removed in favor of a full-window settings panel (Codex pattern);
//  these primitives remain because SettingsWindowView reuses them.
//
//  - `SettingsToggleRow` / `SettingsLinkRow` / `SettingsAccessibilityRow`:
//    notch-era row treatments preserved for any callers still wanting
//    them.
//  - `SettingsUpdateRow`: the update-check pill, reused verbatim by
//    SettingsWindowView's General section.
//  - `SettingsSectionHeader`: small uppercase header, used by callers
//    that want to chunk a flat list.
//

import ApplicationServices
import AgentVisorCore
import ServiceManagement
import SwiftUI

// MARK: - Section header
//
// Tiny uppercase 10pt label that groups related rows. Matches the
// sidebar's section header style (MainSplitView.sectionHeader) so
// the popover reads as part of the same visual system rather than
// a transplant from a different window.

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }
}

// MARK: - Row primitives (renamed copies of MenuRow / MenuToggleRow /
// AccessibilityRow / UpdateRow from the deleted NotchMenuView. The
// notch-tinted naming is dropped; the visual treatment is identical
// because both surfaces share the same Catppuccin palette.)

struct SettingsLinkRow: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)
                Spacer()
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
    }

    private var textColor: Color {
        if isDestructive { return ChatTheme.statusError }
        return isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(textColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)
                Spacer()
                Circle()
                    .fill(isOn ? TerminalColors.green : Catppuccin.surface2)
                    .frame(width: 6, height: 6)
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 11))
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
    }

    private var textColor: Color {
        isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}

struct SettingsAccessibilityRow: View {
    let isEnabled: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .frame(width: 16)
            Text("Accessibility")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
            Spacer()
            if isEnabled {
                Circle()
                    .fill(TerminalColors.green)
                    .frame(width: 6, height: 6)
                Text("On")
                    .font(.system(size: 11))
                    .foregroundColor(ChatTheme.tertiary)
            } else {
                Button(action: openAccessibilitySettings) {
                    Text("Enable")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ChatTheme.headerBg)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(ChatTheme.primary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Catppuccin.surface0.opacity(0.6) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    private var textColor: Color {
        isHovered ? ChatTheme.primary : ChatTheme.secondary
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SettingsUpdateRow: View {
    @ObservedObject var updateManager: UpdateManager
    @State private var isHovered = false
    @State private var isSpinning = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(version) (\(build))"
    }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 10) {
                ZStack {
                    if case .installing = updateManager.state {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                            .foregroundColor(TerminalColors.blue)
                            .rotationEffect(.degrees(isSpinning ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isSpinning)
                            .onAppear { isSpinning = true }
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(iconColor)
                    }
                }
                .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(labelColor)

                Spacer()
                rightContent
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered && isInteractive ? Catppuccin.surface0.opacity(0.6) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: updateManager.state)
    }

    @ViewBuilder
    private var rightContent: some View {
        switch updateManager.state {
        case .idle:
            Text(appVersion)
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(TerminalColors.green)
                Text("Up to date")
                    .font(.system(size: 11))
                    .foregroundColor(TerminalColors.green)
            }
        case .checking, .installing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 12, height: 12)
        case .found(let version, _):
            HStack(spacing: 6) {
                Circle().fill(TerminalColors.green).frame(width: 6, height: 6)
                Text("v\(version)").font(.system(size: 11)).foregroundColor(TerminalColors.green)
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 60).tint(TerminalColors.blue)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.blue)
                    .frame(width: 32, alignment: .trailing)
            }
        case .extracting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 60).tint(TerminalColors.amber)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(TerminalColors.amber)
                    .frame(width: 32, alignment: .trailing)
            }
        case .readyToInstall(let version):
            HStack(spacing: 6) {
                Circle().fill(TerminalColors.green).frame(width: 6, height: 6)
                Text("v\(version)").font(.system(size: 11)).foregroundColor(TerminalColors.green)
            }
        case .error:
            Text("Retry")
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
        }
    }

    private var icon: String {
        switch updateManager.state {
        case .idle, .checking, .downloading: return "arrow.down.circle"
        case .upToDate, .readyToInstall: return "checkmark.circle.fill"
        case .found: return "arrow.down.circle.fill"
        case .extracting: return "doc.zipper"
        case .installing: return "gear"
        case .error: return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch updateManager.state {
        case .idle: return isHovered ? ChatTheme.primary : ChatTheme.secondary
        case .checking: return ChatTheme.secondary
        case .upToDate, .found, .readyToInstall: return TerminalColors.green
        case .downloading, .installing: return TerminalColors.blue
        case .extracting: return TerminalColors.amber
        case .error: return ChatTheme.statusError
        }
    }

    private var label: String {
        switch updateManager.state {
        case .idle, .upToDate: return "Check for Updates"
        case .checking: return "Checking..."
        case .found: return "Download Update"
        case .downloading: return "Downloading..."
        case .extracting: return "Extracting..."
        case .readyToInstall: return "Install & Relaunch"
        case .installing: return "Installing..."
        case .error: return "Update failed"
        }
    }

    private var labelColor: Color {
        switch updateManager.state {
        case .idle, .upToDate: return isHovered ? ChatTheme.primary : ChatTheme.secondary
        case .checking, .downloading, .extracting, .installing: return ChatTheme.primary
        case .found, .readyToInstall: return TerminalColors.green
        case .error: return ChatTheme.statusError
        }
    }

    private var isInteractive: Bool {
        switch updateManager.state {
        case .idle, .upToDate, .found, .readyToInstall, .error: return true
        case .checking, .downloading, .extracting, .installing: return false
        }
    }

    private func handleTap() {
        switch updateManager.state {
        case .idle, .upToDate, .error:
            updateManager.checkForUpdates()
        case .found:
            updateManager.downloadAndInstall()
        case .readyToInstall:
            updateManager.installAndRelaunch()
        default:
            break
        }
    }
}
