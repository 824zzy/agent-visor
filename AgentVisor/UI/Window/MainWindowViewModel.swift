//
//  MainWindowViewModel.swift
//  AgentVisor
//
//  Search-first Sessions browser. Merges live/recent SessionStore rows
//  with the full navigable Codex Desktop catalog, then delegates filtering
//  and ordering to the pure-Core SessionBrowserPolicy.
//

import AgentVisorCore
import Combine
import Foundation

/// Top-level mode for the main window. Sessions are the product surface;
/// settings remains a separate context inside the same NSWindow.
enum WindowMode {
    case sessions
    case settings
}

struct SessionBrowserScrollRequest: Equatable {
    let requestID: UInt64
    let sessionId: String
}

@MainActor
final class MainWindowViewModel: ObservableObject {
    /// Current live/recent session lookup. Browser rows carry only their
    /// lightweight `SessionBrowserItem`; this dictionary is consulted only
    /// for navigation and the explicit inspector.
    @Published private(set) var sessionsById: [String: SessionState] = [:]
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            rebuildBrowser(interaction: .queryResultsChanged)
        }
    }
    @Published private(set) var browserItemsById: [String: SessionBrowserItem] = [:]
    @Published private(set) var browserSelection = SessionBrowserSelection(
        isSearching: false,
        groups: [],
        orderedSessionIds: []
    )
    @Published private(set) var keyboardCursorSessionId: String?
    @Published private(set) var browserScrollRequest: SessionBrowserScrollRequest?
    @Published private(set) var isLoadingHistoricalSessions = false
    @Published private(set) var searchFocusRequest = 0
    @Published var selectedSettingsCategory: SettingsCategory = .general
    @Published private(set) var settingsUpdateRevealRequest = 0
    /// Sessions the user has hidden, for the settings "Hidden sessions" list.
    /// Sourced from persistence (hidden rows aren't in the published session
    /// array), refreshed on every hide/unhide.
    @Published private(set) var hiddenSessions: [HiddenSessionEntry] = MainWindowSettings.hiddenSessions()
    /// The selected id drives the explicit inspector sheet. Normal row
    /// activation opens the owning app and does not mutate this value.
    @Published var selectedSessionId: String? {
        didSet {
            if let id = selectedSessionId {
                MainWindowSettings.setLastSessionId(id)
                if let session = sessionsById[id] {
                    SessionNavigationRecencyStore.shared.record(session)
                }
            }
        }
    }
    @Published var mode: WindowMode = .sessions
    private var cancellables: Set<AnyCancellable> = []
    private var historicalCodexItemsById: [String: SessionBrowserItem] = [:]
    private var historicalLoadTask: Task<Void, Never>?
    private var historicalReloadPending = false
    private var nextBrowserScrollRequestID: UInt64 = 0
    /// Fingerprint of the last current-session snapshot merged into the browser.
    /// SessionStore publishes on every assistant token (lastActivity /
    /// lastContextTokens tick); without dedupe the browser would
    /// re-render at streaming frequency, and SwiftUI's per-row ForEach
    /// diff would deep-copy each SessionState (which contains the
    /// entire chatItems array) on every publish — pinning the main
    /// thread at 99% CPU.
    private var lastBrowserFingerprint: String = ""

    init() {
        // Boot with no inspected session so transcript work doesn't
        // auto-load a multi-hundred-megabyte JSONL on launch. This
        // matches Codex / Claude Desktop's "instant window, lazy
        // chat" boot. Inspection is always explicit.
        //
        // Test escape hatch: setting `AV_AUTOSELECT_LAST=1` in the
        // environment auto-restores the last session — used by the
        // pagination stress test to deterministically open a giant
        // session without UI scripting. Off by default in user
        // builds.
        if Foundation.ProcessInfo.processInfo.environment["AV_AUTOSELECT_LAST"] == "1",
           let stored = MainWindowSettings.lastSessionId() {
            selectedSessionId = stored
        } else {
            selectedSessionId = nil
        }
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.refresh(from: sessions)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .cvCodexCatalogDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshHistoricalSessions()
            }
            .store(in: &cancellables)
        refreshHistoricalSessions()
    }

    /// Only the fields the browser row and ordering policy render. Excludes
    /// rapidly-changing scalars (lastContextTokens, totalInputTokens,
    /// chatItems, etc.) so streaming doesn't republish.
    private static func browserFingerprint(_ sessions: [SessionState]) -> String {
        var s = ""
        s.reserveCapacity(sessions.count * 80)
        for state in sessions {
            s.append(state.sessionId)
            s.append("|")
            s.append(state.cwd)
            s.append("|")
            s.append(state.agentID.rawValue)
            s.append("|")
            s.append(state.terminalHost?.rawValue ?? "")
            s.append("|")
            s.append(state.tty ?? "")
            s.append("|")
            s.append(phaseTag(state.phase))
            s.append("|")
            s.append(state.sessionName ?? "")
            s.append("|")
            s.append(state.conversationInfo.firstUserMessage?.prefix(50).description ?? "")
            s.append("|")
            s.append(state.lastMessageRole ?? "")
            s.append("|")
            s.append((state.lastMessage ?? "").prefix(80).description)
            s.append("|")
            s.append(state.lastToolName ?? "")
            s.append("|")
            s.append(state.pendingToolName ?? "")
            s.append("|")
            s.append(state.pendingToolInput ?? "")
            s.append("|")
            s.append("\(state.lastActivityDate?.timeIntervalSinceReferenceDate.rounded() ?? -1)")
            s.append("|")
            s.append("\(state.lastUserMessageDate?.timeIntervalSinceReferenceDate.rounded() ?? -1)")
            s.append("|")
            s.append("\(state.lastActivity.timeIntervalSinceReferenceDate.rounded())")
            s.append("\n")
        }
        return s
    }

    private static func phaseTag(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .processing: return "processing"
        case .waitingForInput: return "waitingForInput"
        case .waitingForApproval: return "waitingForApproval"
        case .compacting: return "compacting"
        case .ended: return "ended"
        }
    }

    private func refresh(from rawSessions: [SessionState]) {
        let snapshot = SidebarSessionListBuilder.build(
            from: rawSessions,
            selectedSessionId: selectedSessionId
        )
        let fingerprint = Self.browserFingerprint(snapshot.visibleSessions)
        if fingerprint == lastBrowserFingerprint { return }
        lastBrowserFingerprint = fingerprint

        sessionsById = snapshot.sessionsById
        rebuildBrowser(interaction: .backgroundResultsChanged)

        let allIds = Set(browserItemsById.keys)
        if let current = selectedSessionId, !allIds.contains(current) {
            selectedSessionId = nil
        }
        // No auto-inspection on boot. Transcript work starts only after
        // the user explicitly asks for details.
    }

    func refreshHistoricalSessions() {
        guard historicalLoadTask == nil else {
            historicalReloadPending = true
            return
        }
        isLoadingHistoricalSessions = true
        historicalLoadTask = Task { [weak self] in
            let threads = await Task.detached(priority: .utility) {
                CodexThreadStore.browsableThreadCandidates()
            }.value
            guard let self else { return }

            historicalCodexItemsById = Dictionary(
                threads.map { thread in
                    let rawTitle = thread.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let project = ProjectDisplayNamePolicy.displayName(forCwd: thread.cwd)
                        ?? URL(fileURLWithPath: thread.cwd).lastPathComponent
                    let title = rawTitle.flatMap { $0.isEmpty ? nil : $0 } ?? project
                    let item = SessionBrowserItem(
                        sessionId: thread.id,
                        title: title,
                        preview: "",
                        projectName: project,
                        sourceName: "Codex",
                        ownerName: "Codex",
                        cwd: thread.cwd,
                        agentID: .codex,
                        terminalHost: nil,
                        section: .recent,
                        sortDate: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
                        isHistorical: true,
                        transcriptPath: thread.rolloutPath
                    )
                    return (thread.id, item)
                },
                uniquingKeysWith: { first, _ in first }
            )
            isLoadingHistoricalSessions = false
            historicalLoadTask = nil
            rebuildBrowser(interaction: .backgroundResultsChanged)
            if historicalReloadPending {
                historicalReloadPending = false
                refreshHistoricalSessions()
            }
        }
    }

    private func rebuildBrowser(interaction: SessionBrowserInteractionEvent) {
        let hiddenIds = MainWindowSettings.hiddenSessionIds()
        var items = historicalCodexItemsById.filter { !hiddenIds.contains($0.key) }

        for session in sessionsById.values where !hiddenIds.contains(session.sessionId) {
            items[session.sessionId] = browserItem(for: session)
        }

        let selection = SessionBrowserPolicy.select(
            candidates: items.values.map { item in
                SessionBrowserCandidate(
                    sessionId: item.sessionId,
                    title: item.title,
                    preview: item.preview,
                    project: item.projectName,
                    source: item.sourceName,
                    owner: item.ownerName,
                    path: item.cwd,
                    section: item.section,
                    sortDate: item.sortDate,
                    isHidden: hiddenIds.contains(item.sessionId),
                    isArchived: false
                )
            },
            query: searchQuery
        )

        browserItemsById = items
        browserSelection = selection
        applyInteraction(interaction)
    }

    private func browserItem(for session: SessionState) -> SessionBrowserItem {
        let sourceName = AgentRegistry.provider(for: session.agentID)?.displayName
            ?? session.agentID.rawValue
        let rawPreview = session.lastMessage ?? session.summary ?? session.firstUserMessage ?? ""
        return SessionBrowserItem(
            sessionId: session.sessionId,
            title: session.displayTitle,
            preview: SessionActivityExcerptFormatter.singleLine(rawPreview),
            projectName: session.bestProjectName,
            sourceName: sourceName,
            ownerName: ownerDisplayName(for: session, agentDisplayName: sourceName),
            cwd: session.cwd,
            agentID: session.agentID,
            terminalHost: session.terminalHost,
            section: browserSection(for: session.phase),
            sortDate: Self.sortKey(for: session),
            isHistorical: false,
            transcriptPath: nil
        )
    }

    private func ownerDisplayName(
        for session: SessionState,
        agentDisplayName: String
    ) -> String {
        if session.origin == .visorSpawned { return "Agent Visor" }
        if session.origin == .cursorObserved { return "Cursor" }
        if session.agentID == .codex, session.tty == nil { return "Codex" }
        if let host = SessionHostDisplayPolicy.displayHost(
            agentID: session.agentID,
            terminalHost: session.terminalHost
        ), host != .unknown {
            return HostMetadata.metadata(for: host).displayName
        }
        return agentDisplayName
    }

    private func browserSection(for phase: SessionPhase) -> SessionBrowserSection {
        switch phase {
        case .waitingForApproval: return .needsAttention
        case .waitingForInput: return .ready
        case .processing, .compacting: return .working
        case .idle, .ended: return .recent
        }
    }

    var visibleBrowserSessionIds: [String] {
        browserSelection.orderedSessionIds
    }

    var browserListElements: [SessionBrowserListElement] {
        SessionBrowserListPresentation.elements(
            for: browserSelection,
            keyboardCursorSessionID: keyboardCursorSessionId
        )
    }

    var browserSessionCount: Int {
        browserSelection.orderedSessionIds.count
    }

    func browserItem(_ sessionId: String) -> SessionBrowserItem? {
        browserItemsById[sessionId]
    }

    func moveKeyboardCursor(by offset: Int) {
        applyInteraction(.keyboardMove(offset: offset))
    }

    private func applyInteraction(_ event: SessionBrowserInteractionEvent) {
        let decision = SessionBrowserInteractionPolicy.reduce(
            currentCursorID: keyboardCursorSessionId,
            visibleSessionIDs: visibleBrowserSessionIds,
            event: event
        )
        keyboardCursorSessionId = decision.cursorSessionID
        guard let sessionID = decision.revealSessionID else { return }
        nextBrowserScrollRequestID &+= 1
        browserScrollRequest = SessionBrowserScrollRequest(
            requestID: nextBrowserScrollRequestID,
            sessionId: sessionID
        )
    }

    func openKeyboardCursor() {
        guard let keyboardCursorSessionId else { return }
        openOriginal(keyboardCursorSessionId)
    }

    func inspectKeyboardCursor() {
        guard let keyboardCursorSessionId else { return }
        inspectSession(keyboardCursorSessionId)
    }

    func openOriginal(_ sessionId: String) {
        guard let item = browserItemsById[sessionId] else { return }
        if let session = sessionsById[sessionId] {
            SessionNavigationRecencyStore.shared.record(session)
            SessionNavigator.navigateToSession(session)
        } else if item.agentID == .codex {
            CodexAgentProvider.openThreadInApp(sessionId)
        }
    }

    func inspectSession(_ sessionId: String) {
        guard browserItemsById[sessionId] != nil else { return }
        selectedSessionId = sessionId
    }

    func dismissInspector() {
        selectedSessionId = nil
    }

    func clearSearch() {
        searchQuery = ""
    }

    func prepareForSessionBrowser() {
        selectedSessionId = nil
        mode = .sessions
        searchFocusRequest &+= 1
    }

    func prepareForUpdateSettings() {
        selectedSettingsCategory = .general
        mode = .settings
        settingsUpdateRevealRequest &+= 1
    }

    func hideBrowserItem(_ sessionId: String) {
        guard let item = browserItemsById[sessionId] else { return }
        if sessionsById[sessionId] != nil {
            hideSession(sessionId)
            return
        }
        MainWindowSettings.hide(
            id: item.sessionId,
            title: item.title,
            agentRaw: item.agentID.rawValue
        )
        hiddenSessions = MainWindowSettings.hiddenSessions()
        if selectedSessionId == sessionId { selectedSessionId = nil }
        rebuildBrowser(interaction: .backgroundResultsChanged)
    }

    /// Browser recency and the rendered relative-time label share this key,
    /// so ordering and visible ages cannot disagree.
    private static func sortKey(for s: SessionState) -> Date {
        SidebarRecency.sortDate(
            lastActivityDate: s.lastActivityDate,
            lastUserMessageDate: s.lastUserMessageDate,
            lastActivity: s.lastActivity
        )
    }

    /// Cmd+N opens the owning app for the matching visible browser row.
    func selectByHotkeyPosition(_ position: Int) {
        let ids = visibleBrowserSessionIds
        guard position >= 0, position < ids.count else { return }
        openOriginal(ids[position])
    }

    func selectSession(_ sessionId: String) {
        if mode != .sessions {
            mode = .sessions
        }
        if selectedSessionId != sessionId {
            selectedSessionId = sessionId
        }
    }

    // MARK: - Hide / delete

    /// Hide a session locally (reversible). Captures the current title/agent
    /// so the settings list can label it after the row stops publishing.
    func hideSession(_ sessionId: String) {
        guard let session = sessionsById[sessionId] else { return }
        let title = session.displayTitle
        let agentRaw = session.agentID.rawValue
        if selectedSessionId == sessionId { selectedSessionId = nil }
        Task {
            await SessionStore.shared.hideSession(id: sessionId, title: title, agentRaw: agentRaw)
            await MainActor.run {
                self.hiddenSessions = MainWindowSettings.hiddenSessions()
                self.rebuildBrowser(interaction: .backgroundResultsChanged)
            }
        }
    }

    func unhideSession(_ sessionId: String) {
        Task {
            await SessionStore.shared.unhideSession(id: sessionId)
            await MainActor.run {
                self.hiddenSessions = MainWindowSettings.hiddenSessions()
                self.rebuildBrowser(interaction: .backgroundResultsChanged)
            }
        }
    }

    /// True only for phases where Claude is BLOCKED on user input,
    /// i.e. an approval prompt is showing. Differs from
    /// `SessionState.needsAttention`/`SessionPhase.needsAttention`
    /// which also includes `.waitingForInput` (a finished turn) —
    /// we don't want freshly-finished sessions to live under
    /// "Needs attention" forever, so only the genuinely-blocked
    /// `.waitingForApproval` qualifies.
    static func isAttentionRequired(_ phase: SessionPhase) -> Bool {
        if case .waitingForApproval = phase { return true }
        return false
    }
}

/// Lightweight, source-agnostic row model for the full Sessions browser.
/// Current sessions resolve back to `SessionState`; older Codex rows retain
/// just enough metadata for search, display, deep-link navigation, and an
/// explicit diagnostic preview.
struct SessionBrowserItem: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let title: String
    let preview: String
    let projectName: String
    let sourceName: String
    let ownerName: String
    let cwd: String
    let agentID: AgentID
    let terminalHost: TerminalHost?
    let section: SessionBrowserSection
    let sortDate: Date
    let isHistorical: Bool
    let transcriptPath: String?

    init(
        sessionId: String,
        title: String,
        preview: String,
        projectName: String,
        sourceName: String,
        ownerName: String,
        cwd: String,
        agentID: AgentID,
        terminalHost: TerminalHost?,
        section: SessionBrowserSection,
        sortDate: Date,
        isHistorical: Bool,
        transcriptPath: String?
    ) {
        self.id = sessionId
        self.sessionId = sessionId
        self.title = title
        self.preview = preview
        self.projectName = projectName
        self.sourceName = sourceName
        self.ownerName = ownerName
        self.cwd = cwd
        self.agentID = agentID
        self.terminalHost = terminalHost
        self.section = section
        self.sortDate = sortDate
        self.isHistorical = isHistorical
        self.transcriptPath = transcriptPath
    }
}

/// Lightweight window-side group. Stores only row IDs/metadata, not
/// `SessionState`, so `ForEach` keypath reads stay cheap even when a
/// session has a very large chat history.
struct SidebarFlatRowGroup: Identifiable, Equatable {
    let id: String
    let kind: SidebarPathGroupKind
    let rows: [SidebarFlatRow]

    init(kind: SidebarPathGroupKind, rows: [SidebarFlatRow]) {
        self.kind = kind
        self.rows = rows
        switch kind {
        case .needsAttention: self.id = "needsAttention"
        case .working: self.id = "working"
        case .ready: self.id = "ready"
        case .recent: self.id = "recent"
        case .project(let name): self.id = "project:\(name)"
        case .other: self.id = "other"
        }
    }

    var displayTitle: String {
        kind.displayTitle
    }
}

/// Lightweight row metadata for the flat (recency-sorted) sidebar.
/// Holds only what the row needs — sessionId for resolution, project
/// name for the chip, attention flag for the leading-edge accent.
/// CRITICAL — `id` is STORED. ForEach reads
/// `\.id` per-frame; if it were computed, the keypath would deep-copy
/// the value type. See [[feedback_foreach_keypath_deep_copy]].
struct SidebarFlatRow: Identifiable, Equatable {
    let id: String   // == sessionId
    let sessionId: String
    /// cwd's last-component (e.g. "agent-visor-dev"). nil when the
    /// session's cwd doesn't resolve to a project key (catch-all
    /// "Other" rows in the old grouping).
    let projectName: String?
    let isAttention: Bool

    init(sessionId: String, projectName: String?, isAttention: Bool) {
        self.id = sessionId
        self.sessionId = sessionId
        self.projectName = projectName
        self.isAttention = isAttention
    }
}

struct SidebarSessionListSnapshot {
    let visibleSessions: [SessionState]
    let groupedRows: [SidebarFlatRowGroup]
    let flatRows: [SidebarFlatRow]
    let sessionsById: [String: SessionState]
}

enum SidebarSessionListBuilder {
    static func build(
        from rawSessions: [SessionState],
        selectedSessionId: String?
    ) -> SidebarSessionListSnapshot {
        let sessions = rawSessions.filter {
            !isHiddenInWindow($0, selectedSessionId: selectedSessionId)
        }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        var sessionById: [String: SessionState] = [:]
        sessionById.reserveCapacity(sessions.count)
        for state in sessions {
            sessionById[state.sessionId] = state
        }

        let stateGroups = SidebarStateSectionPolicy.group(sessions.map { state in
            SidebarStateSectionCandidate(
                sessionId: state.sessionId,
                section: sectionKind(for: state.phase),
                sortDate: sortKey(for: state)
            )
        })

        let groupedRows = stateGroups.map { group in
            SidebarFlatRowGroup(
                kind: pathGroupKind(for: group.kind),
                rows: group.rows.compactMap { row in
                    guard let state = sessionById[row.sessionId] else { return nil }
                    return SidebarFlatRow(
                        sessionId: state.sessionId,
                        projectName: SidebarPathGrouper.projectKey(
                            forCwd: state.cwd,
                            homeDirectory: homeDir
                        ),
                        isAttention: group.kind == .needsAttention
                    )
                }
            )
        }

        return SidebarSessionListSnapshot(
            visibleSessions: sessions,
            groupedRows: groupedRows,
            flatRows: groupedRows.flatMap(\.rows),
            sessionsById: sessionById
        )
    }

    private static func isHiddenInWindow(
        _ session: SessionState,
        selectedSessionId: String?
    ) -> Bool {
        let isTitleless = SidebarTitlelessPolicy.shouldHide(
            isSelected: session.sessionId == selectedSessionId,
            needsAttention: MainWindowViewModel.isAttentionRequired(session.phase),
            agentID: session.agentID,
            terminalHost: session.terminalHost,
            hasTTY: session.tty != nil,
            hasSessionName: !(session.sessionName ?? "").isEmpty,
            hasFirstUserMessage: !(session.conversationInfo.firstUserMessage ?? "").isEmpty,
            hasChatItems: !session.chatItems.isEmpty,
            hasLastActivityDate: session.conversationInfo.lastActivityDate != nil
        )
        return SidebarSessionVisibilityPolicy.shouldHideInWindow(
            isEnded: session.phase == .ended,
            isTitleless: isTitleless
        )
    }

    private static func sortKey(for session: SessionState) -> Date {
        SidebarRecency.sortDate(
            lastActivityDate: session.lastActivityDate,
            lastUserMessageDate: session.lastUserMessageDate,
            lastActivity: session.lastActivity
        )
    }

    private static func sectionKind(for phase: SessionPhase) -> SidebarStateSectionKind {
        switch phase {
        case .waitingForApproval: return .needsAttention
        case .processing, .compacting: return .working
        case .waitingForInput: return .ready
        case .idle, .ended: return .recent
        }
    }

    private static func pathGroupKind(for section: SidebarStateSectionKind) -> SidebarPathGroupKind {
        switch section {
        case .needsAttention: return .needsAttention
        case .working: return .working
        case .ready: return .ready
        case .recent: return .recent
        }
    }
}
