//
//  SettingsWindowView.swift
//  AgentVisor
//
//  Full-window settings panel modeled on Codex Desktop. Replaces the
//  legacy popover in MainSplitView.
//
//  Layout: NavigationSplitView with a category sidebar on the left,
//  scrollable section content on the right. Top-left "← Back to app"
//  flips MainWindowViewModel.mode back to .chat.
//
//  All persistence still flows through `AppSettings` and the existing
//  selectors (AppearanceSelector, ScreenSelector, SoundSelector,
//  HotkeySelector, FullScreenPolicySelector) plus the new
//  ChatVisibilitySelector + PillsEnabledSelector. SettingsWindowView
//  is purely UI — it doesn't own any state of its own beyond the
//  selected category.
//

import ApplicationServices
import AgentVisorCore
import ServiceManagement
import SwiftUI

/// Top-level settings categories. Order matches the visual sidebar
/// from top to bottom; case-iterable so the sidebar can ForEach.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case pills
    case chat
    case notifications
    case hooks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .pills: return "Pills"
        case .chat: return "Chat"
        case .notifications: return "Notifications"
        case .hooks: return "Agents"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .pills: return "circle.grid.3x3.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .notifications: return "bell"
        case .hooks: return "person.2"
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var windowViewModel: MainWindowViewModel
    /// Force the entire settings surface to invalidate when the user
    /// flips Light/Dark from inside the Appearance section. Without
    /// this dependency, the canvas (`ChatTheme.headerBg`), sidebar
    /// (`Catppuccin.base`), and divider colors stay frozen at whatever
    /// flavor was active when settings first mounted — only the row
    /// directly observing AppearanceSelector inside AppearanceSection
    /// flipped, producing a half-themed window.
    @ObservedObject private var appearance = AppearanceSelector.shared

    var body: some View {
        // Paint the entire settings surface with the same Catppuccin
        // canvas the chat detail pane uses (`ChatTheme.headerBg` ==
        // `Catppuccin.mantle`). The sidebar is bumped down to
        // `Catppuccin.base` so it reads as one tonal step deeper than
        // the content pane — same relationship as the chat sidebar
        // vs. chat detail. This keeps the user inside one visual
        // system across mode switches; a system-themed panel here
        // would feel transplanted.
        ZStack {
            ChatTheme.headerBg.ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                    .background(Catppuccin.base)
                Divider()
                    .background(Catppuccin.surface0)
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .controlSize(.small)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: 720, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task(id: windowViewModel.settingsUpdateRevealRequest) {
                        guard windowViewModel.settingsUpdateRevealRequest > 0,
                              windowViewModel.selectedSettingsCategory == .general else { return }
                        await Task.yield()
                        proxy.scrollTo("settings-updates", anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackToAppButton { windowViewModel.prepareForSessionBrowser() }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SettingsCategory.allCases) { category in
                        CategoryRow(
                            category: category,
                            isSelected: windowViewModel.selectedSettingsCategory == category
                        ) {
                            windowViewModel.selectedSettingsCategory = category
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch windowViewModel.selectedSettingsCategory {
        case .general: GeneralSection(windowViewModel: windowViewModel)
        case .appearance: AppearanceSection()
        case .pills: PillsSection()
        case .chat: ChatSection()
        case .notifications: NotificationsSection()
        case .hooks: HooksSection()
        }
    }
}

// MARK: - Sidebar primitives

private struct BackToAppButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor)
                    .frame(width: 16)
                Text("Back to app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(textColor)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Catppuccin.surface0.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .keyboardShortcut(.escape, modifiers: [])
    }

    private var textColor: Color {
        isHovered ? ChatTheme.primary : ChatTheme.secondary
    }
}

private struct CategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .foregroundColor(iconColor)
                    .frame(width: 16)
                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? ChatTheme.primary : ChatTheme.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        if isSelected { return Catppuccin.lavender }
        return isHovered ? ChatTheme.primary : ChatTheme.tertiary
    }

    private var rowBackground: Color {
        if isSelected {
            return Catppuccin.surface0
        }
        if isHovered {
            return Catppuccin.surface0.opacity(0.5)
        }
        return Color.clear
    }
}

// MARK: - Section primitives

struct SettingsSectionTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(ChatTheme.primary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(ChatTheme.secondary)
            }
        }
        .padding(.bottom, 12)
    }
}

struct SettingsSubheading: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ChatTheme.primary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(ChatTheme.secondary)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }
}

/// One bordered card containing a single labeled toggle. Mirrors
/// Codex's per-setting row treatment: title on the left with a short
/// description, control on the right.
struct SettingsCard<Trailing: View>: View {
    let title: String
    let description: String?
    let trailing: Trailing

    init(
        title: String,
        description: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ChatTheme.primary)
                if let description = description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ChatTheme.cardBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(ChatTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Inset-grouped primitives (macOS System Settings style)
//
// One rounded container per section holds a vertical stack of rows with
// hairline dividers auto-inserted between them. Replaces the old mix of
// bordered `SettingsCard`s and bare picker rows, which looked stitched
// together. Rows render borderless — the enclosing `SettingsGroup` draws
// the single card.

/// A rounded container that stacks its child rows and draws a hairline
/// divider between each pair (never after the last). Uses `_VariadicView`
/// so callers just list rows: `SettingsGroup { rowA; rowB }`.
struct SettingsGroup<Content: View>: View {
    /// Leading inset for the inter-row dividers. 38 aligns the divider
    /// with row text in icon'd groups (12 pad + 16 icon + 10 spacing);
    /// 14 (default) suits icon-less groups (just past the card edge).
    var dividerInset: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        _VariadicView.Tree(SettingsGroupLayout(dividerInset: dividerInset)) {
            content()
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Self.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ChatTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Card fill that ELEVATES above the page (`headerBg` = mantle) in both
    /// modes. `ChatTheme.cardBg` (= `surface0`) only works in Mocha; in
    /// Latte the surfaces get *darker* than the page, so a surface0 card
    /// reads as a dark gray block sitting in a light window. Use the
    /// near-white `base` in light, the raised `surface0` in dark.
    static var cardFill: Color {
        AppSettings.appearance.resolved == .light ? Catppuccin.base : Catppuccin.surface0
    }
}

private struct SettingsGroupLayout: _VariadicView_MultiViewRoot {
    let dividerInset: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(ChatTheme.cardBorder)
                        .frame(height: 0.5)
                        .padding(.leading, dividerInset)
                }
            }
        }
    }
}

/// A single borderless settings row: optional leading icon, a title with
/// an optional description, and a trailing control. Geometry matches the
/// collapsed picker rows (icon at x=12, 16pt frame) so icons line up when
/// pickers and plain rows share a group.
struct SettingsRow<Trailing: View>: View {
    var icon: String?
    var agentIcon: AgentID?
    let title: String
    var description: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        icon: String? = nil,
        agentIcon: AgentID? = nil,
        title: String,
        description: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.agentIcon = agentIcon
        self.title = title
        self.description = description
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let agentIcon {
                AgentBrandLogo(agent: agentIcon, size: 16)
                    .frame(width: 16)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(ChatTheme.secondary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(ChatTheme.primary)
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

// MARK: - Sections

private struct GeneralSection: View {
    @ObservedObject var windowViewModel: MainWindowViewModel
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @ObservedObject private var hotkeySelector = HotkeySelector.shared
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var editorPreference = EditorPreferenceSelector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle("General", subtitle: "How \(AppBranding.appName) starts up and stays accessible")

            SettingsSubheading("Startup")
            SettingsGroup(dividerInset: 38) {
                SettingsRow(
                    icon: "power",
                    title: "Launch at login",
                    description: "Open \(AppBranding.appName) automatically when you sign in"
                ) {
                    Toggle("", isOn: Binding(
                        get: { launchAtLogin },
                        set: { newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                                launchAtLogin = newValue
                            } catch {
                                // Refresh from system state — the toggle
                                // shouldn't lie if the SM call failed.
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsSubheading("Permissions")
            SettingsGroup(dividerInset: 38) {
                SettingsRow(
                    icon: "hand.raised",
                    title: "Accessibility",
                    description: "Required to read terminal output and inject keystrokes for approval prompts"
                ) {
                    if axTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.green)
                    } else {
                        Button("Open System Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSubheading("Hotkey", subtitle: "Show or hide the Agent Visor main window")
            SettingsGroup(dividerInset: 38) {
                HotkeyPickerRow(hotkeySelector: hotkeySelector)
            }

            SettingsSubheading("File links", subtitle: "Which app opens when you click a filename in chat")
            SettingsGroup(dividerInset: 38) {
                EditorPreferencePickerRow(selector: editorPreference)
            }

            SettingsSubheading("Updates")
            SettingsGroup(dividerInset: 38) {
                SettingsUpdateRow(updateManager: updateManager)
            }
            .id("settings-updates")

            SettingsSubheading("Hidden sessions", subtitle: "Sessions you dismissed from the sidebar and pills")
            SettingsGroup(dividerInset: 12) {
                if windowViewModel.hiddenSessions.isEmpty {
                    SettingsRow(
                        title: "No hidden sessions",
                        description: "Hover a session in the sidebar and click × to hide it"
                    ) { EmptyView() }
                } else {
                    ForEach(windowViewModel.hiddenSessions, id: \.id) { entry in
                        let agent = AgentID(rawValue: entry.agentRaw)
                        SettingsRow(
                            agentIcon: agent ?? .claudeCode,
                            title: entry.title.isEmpty ? String(entry.id.prefix(8)) : entry.title,
                            description: agent.flatMap { AgentRegistry.provider(for: $0)?.displayName } ?? entry.agentRaw
                        ) {
                            Button("Unhide") {
                                windowViewModel.unhideSession(entry.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
        }
    }
}

private struct AppearanceSection: View {
    @ObservedObject private var appearance = AppearanceSelector.shared
    @ObservedObject private var screenSelector = ScreenSelector.shared
    @ObservedObject private var fullScreenPolicy = FullScreenPolicySelector.shared
    @AppStorage("chatFontScale") private var chatFontScale: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle("Appearance", subtitle: "How the app looks across screens and content density")

            SettingsSubheading("Theme")
            ThemePickerTiles(selector: appearance)
                .padding(.bottom, 8)

            SettingsSubheading("Display")
            SettingsGroup(dividerInset: 38) {
                ScreenPickerRow(screenSelector: screenSelector)
                FullScreenPolicyPickerRow(selector: fullScreenPolicy)
            }

            SettingsSubheading("Chat font size", subtitle: "Use ⌘+ / ⌘− / ⌘0 inside the chat to change live")
            SettingsGroup(dividerInset: 38) {
                SettingsRow(
                    icon: "textformat.size",
                    title: "Scale",
                    description: "Multiplier applied to chat body text. Header, composer, and status bar stay fixed."
                ) {
                    HStack(spacing: 8) {
                        Text(String(format: "%.0f%%", chatFontScale * 100))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Slider(
                            value: $chatFontScale,
                            in: AppSettings.chatFontScaleMin...AppSettings.chatFontScaleMax,
                            step: AppSettings.chatFontScaleStep
                        )
                        .frame(width: 160)
                        Button("Reset") { chatFontScale = 1.0 }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct PillsSection: View {
    @ObservedObject private var pillsSelector = PillsEnabledSelector.shared
    @ObservedObject private var usageMonitor = CodexUsageMonitor.shared
    @ObservedObject private var fullScreenPolicy = FullScreenPolicySelector.shared
    @State private var sessionShortcutFamily = AppSettings.sessionShortcutModifierFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle("Pills", subtitle: "Menu-bar shortcuts for active and recent sessions")

            SettingsSubheading("Visibility")
            SettingsGroup(dividerInset: 38) {
                SettingsRow(
                    icon: "circle.grid.3x3.fill",
                    title: "Show session pills",
                    description: "When off, the menu-bar pill strip is hidden completely. Sessions still appear in the main window."
                ) {
                    Toggle("", isOn: Binding(
                        get: { pillsSelector.enabled },
                        set: { pillsSelector.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsRow(
                    icon: "gauge.with.dots.needle.33percent",
                    title: "Show Codex usage when available",
                    description: usageAvailabilityDescription
                ) {
                    Toggle("", isOn: Binding(
                        get: { usageMonitor.enabled },
                        set: { usageMonitor.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsSubheading("Session shortcuts")
            SettingsGroup(dividerInset: 38) {
                SettingsRow(
                    icon: "keyboard",
                    title: "Jump to visible pills",
                    description: "Hold the modifiers to reveal 1-9 and 0. Press 1-9 to open a visible pill, or 0 to toggle More Sessions."
                ) {
                    Picker("", selection: Binding(
                        get: { sessionShortcutFamily },
                        set: { newValue in
                            AppSettings.sessionShortcutModifierFamily = newValue
                            sessionShortcutFamily = newValue
                            GlobalSessionShortcutManager.shared.apply(newValue)
                        }
                    )) {
                        ForEach(SessionShortcutModifierFamily.allCases, id: \.self) { family in
                            Text(family.displayLabel).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }
            }

            SettingsSubheading("Full-screen behavior")
            SettingsGroup(dividerInset: 38) {
                FullScreenPolicyPickerRow(selector: fullScreenPolicy)
            }
        }
    }

    private var usageAvailabilityDescription: String {
        switch usageMonitor.availability {
        case .disabled:
            return "Turn on to show Codex's 5-hour and 7-day limits when the account provides them."
        case .checking:
            return "Checking whether this Codex account provides 5-hour or 7-day usage limits."
        case .available:
            return "Codex usage is available and shown as a fixed menu-bar pill."
        case .stale:
            return "Showing the last known Codex limits while the latest refresh is unavailable."
        case .unavailable:
            return "Hidden because Codex did not provide a supported usage window; it will appear automatically when available."
        }
    }
}

private struct ChatSection: View {
    @ObservedObject private var visibility = ChatVisibilitySelector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle(
                "Chat",
                subtitle: "What appears in the conversation timeline. Hide noisy categories to focus on prose and key actions."
            )

            HStack {
                Spacer()
                Button("Reset to defaults") {
                    ChatVisibilitySelector.shared.resetToDefaults()
                }
                .controlSize(.small)
            }
            .padding(.bottom, 4)

            SettingsSubheading("Layout")
            SettingsGroup {
                visibilityToggle(
                    "Group Claude Code turns",
                    description: "Collapse each completed turn's tool calls behind a \"Worked for X\" header and show only the final answer (Codex-style). Off shows the full flat transcript.",
                    keyPath: \.collapseClaudeTurns
                )
                visibilityToggle(
                    "Group Codex turns",
                    description: "Collapse each Codex turn's commentary and commands behind a \"Worked\" header and show only the final answer. Off shows the full flat transcript.",
                    keyPath: \.collapseCodexTurns
                )
            }

            SettingsSubheading("Messages")
            SettingsGroup {
                visibilityToggle(
                    "User messages",
                    description: "Your prompts.",
                    keyPath: \.showUserMessage
                )
                visibilityToggle(
                    "Assistant messages",
                    description: "Claude's prose responses.",
                    keyPath: \.showAssistantMessage
                )
                visibilityToggle(
                    "Thinking",
                    description: "Extended thinking blocks (when the model produces visible reasoning).",
                    keyPath: \.showThinking
                )
            }

            SettingsSubheading("Tools — Files")
            SettingsGroup {
                visibilityToggle("Read", keyPath: \.showRead)
                visibilityToggle("Edit", keyPath: \.showEdit)
                visibilityToggle("Write", keyPath: \.showWrite)
                visibilityToggle("Grep", keyPath: \.showGrep)
                visibilityToggle("Glob", keyPath: \.showGlob)
            }

            SettingsSubheading("Tools — Shell")
            SettingsGroup {
                visibilityToggle("Bash", keyPath: \.showBash)
                visibilityToggle("BashOutput", keyPath: \.showBashOutput)
                visibilityToggle("KillShell", keyPath: \.showKillShell)
            }

            SettingsSubheading("Tools — Web & Other")
            SettingsGroup {
                visibilityToggle("WebFetch", keyPath: \.showWebFetch)
                visibilityToggle("WebSearch", keyPath: \.showWebSearch)
                visibilityToggle("Task (subagents)", keyPath: \.showTask)
                visibilityToggle("TodoWrite", keyPath: \.showTodoWrite)
                visibilityToggle("AskUserQuestion", keyPath: \.showAskUserQuestion)
                visibilityToggle("Plan mode", keyPath: \.showPlanMode)
                visibilityToggle(
                    "MCP tools",
                    description: "Tools provided by MCP servers (Atlassian, Grafana, GitHub, etc.).",
                    keyPath: \.showMCP
                )
                visibilityToggle(
                    "Other tools",
                    description: "Custom or unrecognized tool calls.",
                    keyPath: \.showOtherTools
                )
            }

            SettingsSubheading("Session metadata")
            SettingsGroup {
                visibilityToggle(
                    "Turn duration",
                    description: "How long Claude took for each turn.",
                    keyPath: \.showTurnDuration
                )
                visibilityToggle(
                    "Recap rows",
                    description: "JSONL recap entries that summarize prior context.",
                    keyPath: \.showRecap
                )
                visibilityToggle(
                    "Compact boundaries",
                    description: "Markers showing where /compact compressed earlier history.",
                    keyPath: \.showCompactBoundary
                )
                visibilityToggle(
                    "Local command output",
                    description: "Output of slash commands run inside the TUI.",
                    keyPath: \.showLocalCommandOutput
                )
                visibilityToggle(
                    "Interrupted",
                    description: "[Request interrupted] markers.",
                    keyPath: \.showInterrupted
                )
            }
        }
    }

    @ViewBuilder
    private func visibilityToggle(
        _ title: String,
        description: String? = nil,
        keyPath: WritableKeyPath<ChatVisibilityRules, Bool>
    ) -> some View {
        SettingsRow(title: title, description: description) {
            Toggle("", isOn: Binding(
                get: { visibility.rules[keyPath: keyPath] },
                set: { newValue in
                    visibility.update { $0[keyPath: keyPath] = newValue }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
}

private struct NotificationsSection: View {
    @ObservedObject private var soundSelector = SoundSelector.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle("Notifications", subtitle: "Audio cues for session state changes")

            SettingsSubheading("Sound")
            SettingsGroup(dividerInset: 38) {
                SoundPickerRow(soundSelector: soundSelector)
            }
        }
    }
}

private struct HooksSection: View {
    /// Per-agent install state, refreshed after every toggle so the
    /// description text reflects what's actually on disk now.
    @State private var installed: [AgentID: Bool] = Self.snapshot()

    /// Observed-agent recency window, in whole hours. Key matches
    /// `AppSettings.Keys.observedWindowHours`; the Stepper range clamps
    /// writes to the same bounds AppSettings enforces on read.
    @AppStorage("observedWindowHours") private var observedWindowHours: Int =
        AppSettings.observedWindowHoursDefault

#if DEBUG
    @ObservedObject private var connectedLab = CodexConnectedRuntimeCoordinator.shared
#endif

    static func snapshot() -> [AgentID: Bool] {
        var out: [AgentID: Bool] = [:]
        for provider in AgentRegistry.all {
            out[provider.id] = provider.isInstalled()
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionTitle(
                "Agents",
                subtitle: "\(AppBranding.appName) observes multiple coding agents. Toggle hook-based agents to install their integration. Connected Codex sessions can also be controlled from Agent Visor."
            )

            SettingsSubheading("Connections")
            SettingsGroup {
                ForEach(AgentRegistry.all, id: \.id) { provider in
                    AgentConnectionRow(
                        provider: provider,
                        isInstalled: installed[provider.id] ?? false,
                        onToggle: { newValue in
                            if newValue {
                                try? provider.installHooks()
                            } else {
                                provider.uninstallHooks()
                            }
                            installed = Self.snapshot()
                        }
                    )
                }
            }

            SettingsSubheading(
                "Observed session window",
                subtitle: "Controls status tracking and the +N recent-session browser for observed threads. The Sessions window can still search saved Codex history."
            )
            SettingsGroup {
                SettingsRow(
                    title: "Window",
                    description: "How long observed threads remain in status and recent-session surfaces."
                ) {
                    HStack(spacing: 10) {
                        Text("\(observedWindowHours)h")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Stepper(
                            "",
                            value: $observedWindowHours,
                            in: AppSettings.observedWindowHoursMin...AppSettings.observedWindowHoursMax
                        )
                        .labelsHidden()
                    }
                }
            }


#if DEBUG
            SettingsSubheading(
                "Connected Codex",
                subtitle: "Experimental shared runtime. Turning it on never closes Codex; an already-open Codex connects on its next natural launch."
            )
            SettingsGroup {
                SettingsRow(
                    title: "Shared runtime",
                    description: connectedLab.statusText
                ) {
                    connectedLabControl
                }
            }
#endif
        }
    }

#if DEBUG
    @ViewBuilder
    private var connectedLabControl: some View {
        HStack(spacing: 8) {
            switch connectedLab.state {
            case .preparing, .reconnecting:
                ProgressView()
                    .controlSize(.small)
            case .requiresBackgroundApproval:
                Button("Open Login Items") {
                    connectedLab.openBackgroundItemsSettings()
                }
            case .failedObserved:
                Button("Retry") {
                    Task { await connectedLab.refresh() }
                }
            case .off, .waitingForNextCodexLaunch, .connected, .disconnectPending:
                EmptyView()
            }

            Toggle("", isOn: Binding(
                get: { connectedLab.isEnabled },
                set: { enabled in
                    Task { await connectedLab.setEnabled(enabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }
#endif
}

private struct AgentConnectionRow: View {
    let provider: AgentProvider
    let isInstalled: Bool
    let onToggle: (Bool) -> Void

    private var description: String {
        switch provider.id {
        case .claudeCode:
            return isInstalled
                ? "Hooks installed in ~/.claude/settings.json. Approvals can be answered from \(AppBranding.appName)."
                : "Not installed. Approval prompts will only be answerable in the terminal."
        case .codex:
            return isInstalled
                ? "Hooks installed in ~/.codex/hooks.json. Codex chat history mirrored here."
                : "Not installed. Toggle on to mirror Codex chat history in \(AppBranding.appName)."
        case .cursor:
            return "Read-only — Cursor exposes no hook seam. \(AppBranding.appName) mirrors transcripts from ~/.cursor/projects automatically when you run cursor-agent."
        case .auggie:
            return isInstalled
                ? "Hooks installed in ~/.augment/settings.json."
                : "Not installed."
        }
    }

    private var canToggle: Bool {
        // Cursor's "install" is just metadata — there's no hook script
        // to actually write. Disable the toggle so the user understands
        // the row is informational, not actionable.
        provider.id != .cursor
    }

    var body: some View {
        SettingsRow(
            title: provider.displayName,
            description: description
        ) {
            if canToggle {
                Toggle("", isOn: Binding(
                    get: { isInstalled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            } else {
                Text("Auto")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Catppuccin.surface1)
                    )
            }
        }
    }
}
