import AppKit
import AgentVisorCore
import SwiftUI

struct MainSplitView: View {
    @StateObject private var viewModel: MainWindowViewModel
    @StateObject private var toastModel = AppToastModel()
    @ObservedObject private var commandKey = CommandKeyMonitor.shared
    @ObservedObject private var sessionShortcutManager = GlobalSessionShortcutManager.shared
    @ObservedObject private var appearance = AppearanceSelector.shared
    @ObservedObject private var permissionHealth = PermissionHealthMonitor.shared
    @AppStorage("chatFontScale") private var contentFontScaleStorage: Double = 1.0
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

            if viewModel.mode == .chat {
                chatDestination
                    .transition(.opacity)
            }

            if viewModel.mode == .settings {
                SettingsWindowView(windowViewModel: viewModel)
                    .transition(.opacity)
            }

            AppToastView(model: toastModel)
        }
        .environment(\.contentFontScale, CGFloat(contentFontScaleStorage))
        .preferredColorScheme(preferredScheme)
        .onAppear {
            installKeyboardMonitor()
            viewModel.refreshHistoricalSessions()
            if viewModel.mode == .sessions {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
        .onChange(of: viewModel.mode) { _, mode in
            DispatchQueue.main.async { searchFocused = mode == .sessions }
        }
        .onChange(of: viewModel.searchFocusRequest) { _, _ in
            guard viewModel.mode == .sessions else { return }
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

    @ViewBuilder
    private var chatDestination: some View {
        if let id = viewModel.selectedSessionId,
           let item = viewModel.browserItem(id),
           item.canEnterChat {
            SessionChatWorkspace(
                sessionId: id,
                ownerName: item.ownerName,
                canOpenOriginal: item.canOpenOriginal,
                onBack: { viewModel.leaveChat() },
                onOpenOriginal: { viewModel.openOriginal(id) }
            )
            .id(id)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        viewModel.leaveChat()
                    } label: {
                        Label("Sessions", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(ChatTheme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(height: 58)
                Divider().overlay(ChatTheme.cardBorder)
                ContentUnavailableView(
                    "Chat unavailable",
                    systemImage: "message.slash",
                    description: Text("This session no longer has renderable Chat content.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(ChatTheme.headerBg)
        }
    }

    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                searchField
                    .frame(maxWidth: .infinity)
                if viewModel.browserSelection.isSearching {
                    Text(resultCountLabel)
                        .contentScaledFont(size: 11, weight: .medium)
                        .foregroundColor(ChatTheme.tertiary)
                        .fixedSize()
                }
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
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(SessionBrowserChromeButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            if permissionHealth.health != .ready {
                permissionHealthBanner
            }
        }
        .padding(.vertical, 12)
        .mainContentRail(alignment: .leading)
        .background(ChatTheme.headerBg)
    }

    private var permissionHealthBanner: some View {
        let presentation = permissionHealth.presentation

        return HStack(spacing: 10) {
            if presentation.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(ChatTheme.statusPending)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .contentScaledFont(size: 12, weight: .semibold)
                    .foregroundColor(ChatTheme.primary)
                Text(presentation.detail)
                    .contentScaledFont(size: 11)
                    .foregroundColor(ChatTheme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if let actionTitle = presentation.actionTitle {
                VStack(alignment: .trailing, spacing: 5) {
                    Button {
                        permissionHealth.performPrimarySetupAction()
                    } label: {
                        permissionHealthActionLabel(actionTitle)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()

                    if permissionHealth.health == .needsAccessibility {
                        HStack(spacing: 10) {
                            Button("Open Settings") {
                                permissionHealth.openAccessibilitySettings()
                            }
                            Button("Reveal App") {
                                permissionHealth.revealRunningApp()
                            }
                        }
                        .buttonStyle(.plain)
                        .contentScaledFont(size: 10, weight: .medium)
                        .foregroundColor(ChatTheme.link)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ChatTheme.statusPending.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(ChatTheme.statusPending.opacity(0.35), lineWidth: 0.7)
                )
        )
    }

    private func permissionHealthActionLabel(_ title: String) -> some View {
        Text(title)
            .contentScaledFont(size: 11, weight: .medium)
            .foregroundColor(ChatTheme.link)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ChatTheme.link.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(ChatTheme.link.opacity(0.28), lineWidth: 0.7)
                    )
            )
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .contentScaledFont(size: 13, weight: .medium)
                .foregroundColor(searchFocused ? ChatTheme.link : ChatTheme.tertiary)
            TextField("Search all sessions", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .contentScaledFont(size: 14)
                .foregroundColor(ChatTheme.primary)
                .focused($searchFocused)
                .accessibilityLabel("Search sessions")
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .contentScaledFont(size: 13)
                        .foregroundColor(ChatTheme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            } else {
                Text("⌘F")
                    .contentScaledFont(size: 10, weight: .medium, design: .rounded)
                    .foregroundColor(ChatTheme.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.7)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
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

    private var footerShortcutEducation: some View {
        let presentation = SessionBrowserShortcutEducationPolicy.presentation(
            for: sessionShortcutManager.family
        )

        return HStack(spacing: 12) {
            if let disabledMessage = presentation.disabledMessage {
                Text(disabledMessage)
                    .contentScaledFont(size: 10)
                    .foregroundColor(ChatTheme.tertiary)
            } else {
                ForEach(Array(presentation.hints.enumerated()), id: \.offset) { _, hint in
                    footerShortcutHint(hint)
                }
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func footerShortcutHint(_ hint: SessionBrowserShortcutHint) -> some View {
        HStack(spacing: 5) {
            Text(hint.keys)
                .contentScaledFont(size: 10, weight: .semibold, design: .rounded)
                .foregroundColor(ChatTheme.secondary)
            Text(hint.label)
                .contentScaledFont(size: 10)
                .foregroundColor(ChatTheme.tertiary)
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
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                    .mainContentRail(alignment: .leading)
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
            let primaryAction = SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: item.canEnterChat,
                canOpenOriginal: item.canOpenOriginal
            )
            SessionBrowserRow(
                item: item,
                displaySection: section ?? item.section,
                now: now,
                isHighlighted: isHighlighted,
                hotkeyPosition: hotkeyPosition,
                isCommandHeld: hotkeyPosition != nil && commandKey.isCommandHeld,
                primaryAction: primaryAction,
                onActivate: {
                    viewModel.activateSession(
                        sessionId
                    )
                },
                onEnterChat: { viewModel.enterChat(sessionId) },
                onOpenOriginal: { viewModel.openOriginal(sessionId) },
                onHide: { viewModel.hideBrowserItem(sessionId) }
            )
            .id(sessionId)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .contentScaledFont(size: 12, weight: .semibold)
                .foregroundColor(ChatTheme.secondary)
            Text("\(count)")
                .contentScaledFont(size: 10, weight: .semibold, design: .rounded)
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
                .contentScaledFont(size: 16, weight: .semibold)
                .foregroundColor(ChatTheme.primary)
            Text(viewModel.searchQuery.isEmpty
                 ? "Start a session in Codex, Claude Code, Cursor, or a terminal."
                 : "Try a title, project, source, or path.")
                .contentScaledFont(size: 12)
                .foregroundColor(ChatTheme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 330)
    }

    private var browserFooter: some View {
        responsiveBrowserFooter
            .mainContentRail()
            .padding(.vertical, 5)
            .frame(minHeight: 42)
            .background(ChatTheme.headerBg)
            .overlay(alignment: .top) {
                Divider().overlay(ChatTheme.cardBorder.opacity(0.8))
            }
    }

    private var responsiveBrowserFooter: some View {
        let primaryAction = footerAction(alternate: false)
        let alternateAction = footerAction(alternate: true)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                browserLocalFooter(
                    primaryAction: primaryAction,
                    alternateAction: alternateAction
                )
                Spacer(minLength: 12)
                footerShortcutEducation
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    browserLocalFooter(
                        primaryAction: primaryAction,
                        alternateAction: alternateAction
                    )
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    footerShortcutEducation
                }
            }
        }
    }

    private func browserLocalFooter(
        primaryAction: SessionBrowserPrimaryAction,
        alternateAction: SessionBrowserPrimaryAction
    ) -> some View {
        HStack(spacing: 16) {
            keyboardHint(keys: "↑↓", label: "Navigate")
            keyboardHint(keys: "↩", label: footerLabel(for: primaryAction))
            if alternateAction != primaryAction, alternateAction != .none {
                keyboardHint(keys: "⇧↩", label: footerLabel(for: alternateAction))
            }
        }
    }

    private func footerAction(alternate: Bool) -> SessionBrowserPrimaryAction {
        guard let sessionId = viewModel.keyboardCursorSessionId,
              let item = viewModel.browserItem(sessionId) else {
            return SessionBrowserPrimaryActionPolicy.action(
                canEnterChat: true,
                canOpenOriginal: true,
                alternate: alternate
            )
        }
        return SessionBrowserPrimaryActionPolicy.action(
            canEnterChat: item.canEnterChat,
            canOpenOriginal: item.canOpenOriginal,
            alternate: alternate
        )
    }

    private func footerLabel(for action: SessionBrowserPrimaryAction) -> String {
        SessionBrowserPrimaryActionPolicy.footerLabel(for: action) ?? "Unavailable"
    }

    private func keyboardHint(keys: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .contentScaledFont(size: 10, weight: .semibold, design: .rounded)
                .foregroundColor(ChatTheme.secondary)
            Text(label)
                .contentScaledFont(size: 10)
                .foregroundColor(ChatTheme.tertiary)
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let semantic: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let modifiers = event.modifierFlags.intersection(semantic)

            guard viewModel.mode == .sessions else { return event }

            if let characters = event.charactersIgnoringModifiers,
               let command = ContentFontScaleCommand.decode(
                    commandHeld: modifiers.contains(.command),
                    optionHeld: modifiers.contains(.option),
                    controlHeld: modifiers.contains(.control),
                    charactersIgnoringModifiers: characters
               ) {
                AppSettings.contentFontScale = command.apply(
                    to: AppSettings.contentFontScale,
                    step: AppSettings.contentFontScaleStep,
                    min: AppSettings.contentFontScaleMin,
                    max: AppSettings.contentFontScaleMax
                )
                return nil
            }

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
                DispatchQueue.main.async {
                    viewModel.activateKeyboardCursor()
                }
                return nil
            case 36 where modifiers == .shift:
                DispatchQueue.main.async {
                    viewModel.activateKeyboardCursor(alternate: true)
                }
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
    let primaryAction: SessionBrowserPrimaryAction
    let onActivate: () -> Void
    let onEnterChat: () -> Void
    let onOpenOriginal: () -> Void
    let onHide: () -> Void
    @State private var isPrimaryHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onActivate) {
                HStack(spacing: 13) {
                    statusMark
                    AgentBrandLogo(agent: item.agentID, size: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        sessionIdentityLine
                        Text(rowSubtitle)
                            .contentScaledFont(size: 12)
                            .foregroundColor(ChatTheme.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if let age = RelativeTimestampFormatter.format(since: item.sortDate, now: now) {
                        Text(age)
                            .contentScaledFont(size: 11, weight: .medium, design: .rounded)
                            .foregroundColor(ChatTheme.tertiary)
                            .frame(minWidth: 28, alignment: .trailing)
                    }
                    hotkeyBadge
                    if primaryAction != .none {
                        primaryDestinationLabel
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.canEnterChat && !item.canOpenOriginal)
            .accessibilityLabel(primaryAccessibilityLabel)
            .frame(maxWidth: .infinity)
            .background(primaryRowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHighlighted ? ChatTheme.link.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .onHover { isPrimaryHovered = $0 }

            ZStack(alignment: .leading) {
                if item.canOpenOriginal && item.canEnterChat {
                    SessionBrowserAccessoryAction(
                        fullTitle: "Open Chat",
                        compactTitle: "Chat",
                        systemImage: "bubble.left",
                        action: onEnterChat
                    )
                    .accessibilityLabel("Open Chat for \(item.title)")
                }
            }
            .frame(width: 138, alignment: .leading)
            .padding(.trailing, 8)
        }
        .contextMenu {
            if item.canOpenOriginal {
                Button("Open in \(item.ownerName)", action: onOpenOriginal)
            }
            if item.canEnterChat {
                Button("Open Chat", action: onEnterChat)
            }
            Divider()
            Button("Hide session", action: onHide)
        }
    }

    private var sessionIdentityLine: some View {
        ViewThatFits(in: .horizontal) {
            identityLine(showsProject: true, showsOwner: true)
            identityLine(showsProject: true, showsOwner: false)
            identityLine(showsProject: false, showsOwner: false)
        }
    }

    private func identityLine(showsProject: Bool, showsOwner: Bool) -> some View {
        HStack(spacing: 7) {
            Text(item.title)
                .contentScaledFont(size: 14, weight: .semibold)
                .foregroundColor(ChatTheme.primary)
                .lineLimit(1)
                .layoutPriority(2)
            BrowserChip(
                text: item.sourceName,
                tint: AgentBrand.tint(for: item.agentID)
            )
            if showsProject {
                BrowserChip(text: item.projectName, tint: Catppuccin.lavender)
            }
            if showsOwner, primaryAction != .openOriginal, item.ownerName != item.sourceName {
                BrowserChip(text: item.ownerName, tint: Catppuccin.sky)
            }
            Spacer(minLength: 4)
        }
    }

    private var primaryRowBackground: Color {
        if isHighlighted { return ChatTheme.cardBg }
        if isPrimaryHovered { return ChatTheme.cardBg.opacity(0.72) }
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

    private var hotkeyBadge: some View {
        let isVisible = hotkeyPosition != nil && isCommandHeld
        let label = hotkeyPosition.map { "⌘\($0 + 1)" } ?? "⌘9"
        return Text(label)
            .contentScaledFont(size: 11, weight: .semibold, design: .rounded)
            .foregroundColor(ChatTheme.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(ChatTheme.cardBorder.opacity(0.75)))
            .opacity(isVisible ? 1 : 0)
            .fixedSize()
            .frame(minWidth: 35, minHeight: 24)
            .accessibilityHidden(!isVisible)
    }

    private var primaryDestinationLabel: some View {
        Group {
            switch primaryAction {
            case .enterChat:
                ViewThatFits(in: .horizontal) {
                    Label("Open Chat", systemImage: "bubble.left")
                    Image(systemName: "bubble.left")
                }
            case .openOriginal:
                ViewThatFits(in: .horizontal) {
                    Label("Open in \(item.ownerName)", systemImage: "arrow.up.forward.app")
                    Label(item.ownerName, systemImage: "arrow.up.forward.app")
                    Image(systemName: "arrow.up.forward.app")
                }
            case .none:
                EmptyView()
            }
        }
        .contentScaledFont(size: 11, weight: .semibold)
        .foregroundColor(isPrimaryHovered ? ChatTheme.link : ChatTheme.secondary)
        .lineLimit(1)
        .frame(width: 120, alignment: .leading)
        .frame(minHeight: 32, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var primaryAccessibilityLabel: String {
        let action: String
        switch primaryAction {
        case .enterChat:
            action = "Open Chat"
        case .openOriginal:
            action = "Open in \(item.ownerName)"
        case .none:
            action = "No available action"
        }
        return "\(item.title), \(displaySection.displayTitle), \(item.sourceName), \(item.projectName), \(action)"
    }
}

private struct SessionBrowserAccessoryAction: View {
    let fullTitle: String
    let compactTitle: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                actionLabel(fullTitle)
                actionLabel(compactTitle)
                Image(systemName: systemImage)
                    .frame(minWidth: 28, minHeight: 32)
            }
            .contentScaledFont(size: 11, weight: .semibold)
            .foregroundColor(isHovered ? ChatTheme.link : ChatTheme.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? ChatTheme.link.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
        .help(fullTitle)
    }

    private func actionLabel(_ title: String) -> some View {
        Label(title, systemImage: systemImage)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct BrowserChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .contentScaledFont(size: 10, weight: .medium)
            .foregroundColor(ChatTheme.chipForeground(tint))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
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
    var tint: Color {
        switch self {
        case .needsAttention: return ChatTheme.statusPending
        case .ready: return ChatTheme.statusSuccess
        case .working: return ChatTheme.statusRunning
        case .recent: return ChatTheme.tertiary
        }
    }
}
