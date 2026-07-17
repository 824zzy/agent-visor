import AppKit
import AgentVisorCore
import SwiftUI

struct MainSplitView: View {
    @StateObject private var viewModel: MainWindowViewModel
    @StateObject private var toastModel = AppToastModel()
    @ObservedObject private var commandKey = CommandKeyMonitor.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @ObservedObject private var appearance = AppearanceSelector.shared
    @AppStorage("chatFontScale") private var chatFontScaleStorage: Double = 1.0
    @FocusState private var searchFocused: Bool
    @State private var keyboardMonitor: Any?

    @MainActor
    init() {
        _viewModel = StateObject(wrappedValue: MainWindowViewModel())
    }

    @MainActor
    init(viewModel: MainWindowViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ZStack {
            sessionsBrowser
                .opacity(viewModel.mode == .sessions ? 1 : 0)
                .allowsHitTesting(viewModel.mode == .sessions)

            if viewModel.mode == .settings {
                SettingsWindowView(windowViewModel: viewModel)
                    .transition(.opacity)
            }

            AppToastView(model: toastModel)
        }
        .environment(\.chatFontScale, CGFloat(chatFontScaleStorage))
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: inspectorBinding) {
            inspectorSheet
        }
        .onAppear {
            installKeyboardMonitor()
            viewModel.refreshHistoricalSessions()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            DispatchQueue.main.async { searchFocused = true }
        }
        .onDisappear { removeKeyboardMonitor() }
    }

    private var preferredScheme: ColorScheme? {
        switch appearance.mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var sessionsBrowser: some View {
        VStack(spacing: 0) {
            browserHeader
            Divider().overlay(ChatTheme.cardBorder.opacity(0.8))
            browserResults
            browserFooter
        }
        .background(ChatTheme.headerBg)
    }

    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Sessions")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(ChatTheme.primary)
                    shortcutEducation
                }
                Spacer(minLength: 20)
                if viewModel.isLoadingHistoricalSessions {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing Codex history")
                }
                Button {
                    viewModel.mode = .settings
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(SessionBrowserChromeButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            HStack(alignment: .center, spacing: 12) {
                searchField
                    .frame(maxWidth: 680)
                Spacer(minLength: 0)
                if viewModel.browserSelection.isSearching {
                    Text(resultCountLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(ChatTheme.secondary)
                } else {
                    summaryStrip
                }
            }
        }
        .frame(maxWidth: 1060, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(ChatTheme.headerBg)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(searchFocused ? ChatTheme.link : ChatTheme.tertiary)
            TextField("Search sessions", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(ChatTheme.primary)
                .focused($searchFocused)
                .accessibilityLabel("Search sessions")
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(ChatTheme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(ChatTheme.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.7)))
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatTheme.cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            searchFocused ? ChatTheme.link.opacity(0.75) : ChatTheme.cardBorder,
                            lineWidth: searchFocused ? 1.2 : 0.7
                        )
                )
        )
    }

    private var shortcutEducation: some View {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(
            for: sessionShortcutManager.family
        )

        return HStack(spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ChatTheme.secondary)

            if let disabledMessage = presentation.disabledMessage {
                Text(disabledMessage)
                    .font(.system(size: 11))
                    .foregroundColor(ChatTheme.tertiary)
            } else {
                ForEach(Array(presentation.hints.enumerated()), id: \.offset) { _, hint in
                    shortcutEducationHint(hint)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func shortcutEducationHint(_ hint: SessionBrowserShortcutHint) -> some View {
        HStack(spacing: 5) {
            Text(hint.keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(ChatTheme.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.7)))
            Text(hint.label)
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 8) {
            ForEach(SessionBrowserSection.allCases, id: \.self) { section in
                let count = viewModel.browserCount(for: section)
                if count > 0 {
                    SessionBrowserSummaryChip(
                        title: section.shortTitle,
                        count: count,
                        tint: section.tint
                    )
                }
            }
        }
    }

    private var resultCountLabel: String {
        let count = viewModel.browserSessionCount
        return count == 1 ? "1 result" : "\(count) results"
    }

    private var browserResults: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if viewModel.visibleBrowserSessionIds.isEmpty {
                            emptyState
                        } else {
                            ForEach(viewModel.browserListElements) { element in
                                switch element {
                                case .searchResults(let count):
                                    sectionHeader("Results", count: count)
                                case .section(let section, let count):
                                    sectionHeader(section.displayTitle, count: count)
                                case .session(let sessionId, let section, let isKeyboardCursor):
                                    browserRow(
                                        sessionId,
                                        now: context.date,
                                        section: section,
                                        isHighlighted: isKeyboardCursor
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dimmedScroller()
                .onChange(of: viewModel.browserScrollRequest) { _, request in
                    guard let request else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(request.sessionId)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func browserRow(
        _ sessionId: String,
        now: Date,
        section: SessionBrowserSection?,
        isHighlighted: Bool
    ) -> some View {
        if let item = viewModel.browserItem(sessionId) {
            let hotkeyPosition = viewModel.visibleBrowserSessionIds
                .prefix(9)
                .firstIndex(of: sessionId)
            SessionBrowserRow(
                item: item,
                displaySection: section ?? item.section,
                now: now,
                isHighlighted: isHighlighted,
                hotkeyPosition: hotkeyPosition,
                isCommandHeld: hotkeyPosition != nil && commandKey.isCommandHeld,
                onOpen: { viewModel.openOriginal(sessionId) },
                onInspect: { viewModel.inspectSession(sessionId) },
                onHide: { viewModel.hideBrowserItem(sessionId) }
            )
            .id(sessionId)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ChatTheme.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(ChatTheme.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.55)))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 11)
        .padding(.bottom, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.searchQuery.isEmpty ? "rectangle.stack" : "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(ChatTheme.tertiary)
            Text(viewModel.searchQuery.isEmpty ? "No sessions available" : "No matching sessions")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(ChatTheme.primary)
            Text(viewModel.searchQuery.isEmpty
                 ? "Start a session in Codex, Claude Code, Cursor, or a terminal."
                 : "Try a title, project, source, or path.")
                .font(.system(size: 12))
                .foregroundColor(ChatTheme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
    }

    private var browserFooter: some View {
        HStack(spacing: 16) {
            keyboardHint(keys: "↑↓", label: "Navigate")
            keyboardHint(keys: "↩", label: "Open original")
            keyboardHint(keys: "⌥↩", label: "Inspect")
            Spacer(minLength: 12)
        }
        .frame(maxWidth: 1060)
        .padding(.horizontal, 28)
        .frame(height: 42)
        .frame(maxWidth: .infinity)
        .background(ChatTheme.headerBg)
        .overlay(alignment: .top) {
            Divider().overlay(ChatTheme.cardBorder.opacity(0.8))
        }
    }

    private func keyboardHint(keys: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(ChatTheme.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(ChatTheme.tertiary)
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.selectedSessionId != nil },
            set: { isPresented in
                if !isPresented { viewModel.dismissInspector() }
            }
        )
    }

    @ViewBuilder
    private var inspectorSheet: some View {
        if let id = viewModel.selectedSessionId,
           let item = viewModel.browserItem(id) {
            if viewModel.sessionsById[id] != nil {
                SessionWorkspaceDetail(sessionId: id)
                    .frame(minWidth: 760, minHeight: 560)
            } else {
                HistoricalSessionInspector(
                    item: item,
                    onOpen: { viewModel.openOriginal(id) }
                )
                .frame(minWidth: 680, minHeight: 440)
            }
        } else {
            EmptyView()
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let semantic: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let modifiers = event.modifierFlags.intersection(semantic)

            guard viewModel.mode == .sessions,
                  viewModel.selectedSessionId == nil else { return event }

            if modifiers == .command,
               let characters = event.charactersIgnoringModifiers,
               let position = SessionHotkeyMatcher.position(forKeyCharacter: characters) {
                DispatchQueue.main.async { viewModel.selectByHotkeyPosition(position) }
                return nil
            }

            switch event.keyCode {
            case 125 where modifiers.isEmpty:
                DispatchQueue.main.async { viewModel.moveKeyboardCursor(by: 1) }
                return nil
            case 126 where modifiers.isEmpty:
                DispatchQueue.main.async { viewModel.moveKeyboardCursor(by: -1) }
                return nil
            case 36 where modifiers.isEmpty:
                DispatchQueue.main.async { viewModel.openKeyboardCursor() }
                return nil
            case 36 where modifiers == .option:
                DispatchQueue.main.async { viewModel.inspectKeyboardCursor() }
                return nil
            case 3 where modifiers == .command:
                DispatchQueue.main.async { searchFocused = true }
                return nil
            case 53 where modifiers.isEmpty && !viewModel.searchQuery.isEmpty:
                DispatchQueue.main.async {
                    viewModel.clearSearch()
                    searchFocused = true
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
}

private struct SessionBrowserRow: View {
    let item: SessionBrowserItem
    let displaySection: SessionBrowserSection
    let now: Date
    let isHighlighted: Bool
    let hotkeyPosition: Int?
    let isCommandHeld: Bool
    let onOpen: () -> Void
    let onInspect: () -> Void
    let onHide: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    statusMark
                    AgentBrandLogo(agent: item.agentID, size: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 7) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(ChatTheme.primary)
                                .lineLimit(1)
                                .layoutPriority(2)
                            BrowserChip(
                                text: item.sourceName,
                                tint: AgentBrand.tint(for: item.agentID)
                            )
                            BrowserChip(text: item.projectName, tint: Catppuccin.lavender)
                            if item.ownerName != item.sourceName {
                                BrowserChip(text: item.ownerName, tint: Catppuccin.sky)
                            }
                            Spacer(minLength: 4)
                        }
                        Text(rowSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(ChatTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if let age = RelativeTimestampFormatter.format(since: item.sortDate, now: now) {
                        Text(age)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(ChatTheme.tertiary)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    hotkeyBadge
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)

            Button(action: onInspect) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered || isHighlighted ? ChatTheme.secondary : ChatTheme.tertiary)
                    .frame(width: 38, height: 42)
            }
            .buttonStyle(.plain)
            .help("Inspect session")
            .accessibilityLabel("Inspect \(item.title)")
        }
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isHighlighted ? ChatTheme.link.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Open in \(item.ownerName)", action: onOpen)
            Button("Inspect session", action: onInspect)
            Divider()
            Button("Hide session", action: onHide)
        }
    }

    private var rowBackground: Color {
        if isHighlighted { return ChatTheme.cardBg }
        if isHovered { return ChatTheme.cardBg.opacity(0.72) }
        return Color.clear
    }

    private var rowSubtitle: String {
        let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty { return preview }
        let path = ProjectDisplayNamePolicy.displayPath(
            forCwd: item.cwd,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        return item.isHistorical ? "From Codex history · \(path)" : path
    }

    private var statusMark: some View {
        Circle()
            .fill(statusTint)
            .frame(width: 8, height: 8)
            .frame(width: 10)
            .accessibilityHidden(true)
    }

    private var statusTint: Color {
        return displaySection.tint
    }

    @ViewBuilder
    private var hotkeyBadge: some View {
        ZStack {
            if let hotkeyPosition, isCommandHeld {
                Text("⌘\(hotkeyPosition + 1)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ChatTheme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.75)))
            }
        }
        .frame(width: 35, height: 24)
    }

    private var accessibilityLabel: String {
        "\(item.title), \(displaySection.displayTitle), \(item.sourceName), \(item.projectName)"
    }
}

private struct BrowserChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(ChatTheme.chipForeground(tint))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct SessionBrowserSummaryChip: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
            Text("\(count)")
                .foregroundColor(ChatTheme.primary)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(ChatTheme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(ChatTheme.cardBg))
    }
}

private struct SessionBrowserChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(ChatTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? ChatTheme.cardBorder : ChatTheme.cardBg)
            )
    }
}

private extension SessionBrowserSection {
    var shortTitle: String {
        switch self {
        case .needsAttention: return "Attention"
        case .ready: return "Ready"
        case .working: return "Working"
        case .recent: return "Recent"
        }
    }

    var tint: Color {
        switch self {
        case .needsAttention: return ChatTheme.statusPending
        case .ready: return ChatTheme.statusSuccess
        case .working: return ChatTheme.statusRunning
        case .recent: return ChatTheme.tertiary
        }
    }
}
