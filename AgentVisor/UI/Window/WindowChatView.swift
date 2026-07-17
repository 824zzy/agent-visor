//
//  WindowChatView.swift
//  AgentVisor
//
//  Window-mode chat detail pane. Mounts the SAME row primitives the
//  notch's ChatView uses (MessageItemView, ProcessingIndicatorView,
//  TimelineRow grouping) inside a top-down container. Inherits the
//  notch's full rendering: markdown, code blocks, LaTeX, tool call
//  cards, plan cards, edit hunk previews — automatically.
//
//  Differences from the notch ChatView:
//      - Top-down layout (no scaleEffect(y: -1) flip).
//      - No composer in this iteration (read-only). Composer +
//        approval bar arrive in a follow-up commit.
//      - No NotchViewModel dependency. Boot-clean: ChatHistoryManager
//        is the data source; SessionStore is the metadata source.
//      - Per-session @State so session switches in MainSplitView
//        recreate this view (via .id(sessionId)) and don't share
//        scroll/state with the previous session.
//

import AgentVisorCore
import Combine
import os.log
import SwiftUI

@MainActor
final class WindowChatViewModel: ObservableObject {
    @Published private(set) var rows: [TimelineRow] = []
    /// Flat row sequence consumed by the AppKit table. Rebuilt
    /// alongside `rows` so the table observes ONE published list and
    /// doesn't have to re-flatten on every diff tick.
    @Published private(set) var flatRows: [FlatChatRow] = []
    @Published private(set) var session: SessionState?
    @Published private(set) var isLoading: Bool = true
    /// Pagination state. The visible chat is the SUFFIX of the
    /// merged real+echoes timeline of length `pagination.visibleLimit`.
    /// Capped to `ChatPaginationWindow.defaultVisible` (500) on init
    /// so a 153k-line stress session doesn't try to render every
    /// row on first paint — that's the freeze we shipped this fix
    /// for. Tap "Load earlier messages" → `pagination.expanded(...)`
    /// → +500 rows per click.
    @Published private(set) var pagination: ChatPaginationWindow = ChatPaginationWindow()
    /// True when there are real items above the current visible
    /// slice. View renders a "Load earlier messages" button when
    /// this is true.
    @Published private(set) var hasMoreAbove: Bool = false
    /// Number of rows hidden above the current slice. Used in the
    /// button label ("Load 1,234 earlier messages").
    @Published private(set) var hiddenAboveCount: Int = 0
    /// Total real-item count (informational; UI may show "Showing
    /// last 500 of 12,345"). Includes echoes for visible-count
    /// purposes — keeping it simple, the small overcount during the
    /// echo flicker doesn't matter.
    @Published private(set) var totalItemCount: Int = 0
    /// Lightweight monotonic counter bumped on every histories publish
    /// for THIS session. Lets the view trigger an autoscroll on
    /// streaming text growth without reassigning `rows` (which would
    /// re-trigger LazyVStack's id-extraction-deep-copy thrash). The
    /// view observes via `.onChange(of: streamTick)` and calls
    /// `proxy.scrollTo("__bottom__")` — no row re-diff, no ForEach
    /// keypath cost, no layout invalidation feedback loop.
    @Published private(set) var streamTick: Int = 0
    private var cancellables: Set<AnyCancellable> = []
    private let sessionId: String

    /// Dedupe fingerprint for `ChatHistoryManager.$histories` pulses.
    /// See `HistorySliceFingerprint` for the rationale and Core
    /// tests. Skipping equal fingerprints kills LazyLayoutViewCache
    /// thrash from background sessions streaming events at 5-10 Hz.
    private var lastSliceFingerprint: HistorySliceFingerprint = .initial

    /// Fields that drive the detail pane's status, routing, and composer.
    /// Keeping this typed prevents a control-capability transition from
    /// being dropped while unrelated high-frequency metadata is deduped.
    private var lastPresentationFingerprint: WindowChatSessionPresentationFingerprint?

    /// Latest snapshot of real (JSONL-derived) items for THIS session.
    /// Cached so a pure-echo update (PendingEchoStore push) can rebuild
    /// rows without re-reading ChatHistoryManager.
    private var lastRealItems: [ChatHistoryItem] = []
    private var isHistoryLoadInFlight = false

    init(sessionId: String) {
        self.sessionId = sessionId

        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.refreshSessionMeta(from: sessions)
            }
            .store(in: &cancellables)

        ChatHistoryManager.shared.$histories
            .receive(on: DispatchQueue.main)
            .sink { [weak self] histories in
                self?.refreshHistory(from: histories)
            }
            .store(in: &cancellables)

        // Optimistic-echo subscription: when the composer pushes a
        // pending echo (or one self-evicts), rebuild rows so the
        // user's bubble appears instantly. Echoes self-evict via
        // `PendingEchoStore.reconcile` once the real JSONL row matches,
        // so this firehose stops cleanly without our intervention.
        PendingEchoStore.shared.$echoesBySession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRowsWithEchoes()
            }
            .store(in: &cancellables)

        // Chat-visibility subscription: when the user toggles a kind
        // in Settings, rebuild rows so the timeline reflects the new
        // filter without a relaunch. Skips the initial value (the
        // current rules already drive the first render) — `dropFirst`
        // avoids a redundant rebuild on subscription.
        ChatVisibilitySelector.shared.$rules
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRowsWithEchoes()
            }
            .store(in: &cancellables)

        // Turn-collapse subscription: tapping a "Worked for X" chevron
        // flips the session's expanded set; re-flatten so the planner
        // shows/hides that turn's step rows. dropFirst skips the initial
        // empty (collapsed-by-default) state already used by first paint.
        TurnExpansionStore.shared.$expandedBySession
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRowsWithEchoes()
            }
            .store(in: &cancellables)

        startHistoryLoadIfNeeded()
    }

    private func startHistoryLoadIfNeeded() {
        guard !isHistoryLoadInFlight,
              !ChatHistoryManager.shared.isFileLoaded(sessionId: sessionId) else { return }
        isHistoryLoadInFlight = true
        isLoading = true
        Task { [weak self] in
            await self?.loadHistoryIfNeeded()
        }
    }

    private func loadHistoryIfNeeded() async {
        defer { isHistoryLoadInFlight = false }
        let snapshot = await SessionStore.shared.currentSessions()
        guard let state = snapshot.first(where: { $0.sessionId == sessionId }) else {
            // The selected sidebar row can arrive one publish before
            // SessionStore's snapshot is visible to this view model.
            // Keep the loading state; refreshSessionMeta will retry when
            // the session appears.
            return
        }
        if ChatHistoryManager.shared.isFileLoaded(sessionId: sessionId) {
            self.refreshHistory(from: ChatHistoryManager.shared.histories)
            self.isLoading = false
            return
        }
        await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: state.cwd)
        self.refreshHistory(from: ChatHistoryManager.shared.histories)
        self.isLoading = false
    }

    private func refreshSessionMeta(from sessions: [SessionState]) {
        guard let next = sessions.first(where: { $0.sessionId == sessionId }) else {
            if session != nil { session = nil }
            return
        }
        // Structural fingerprint. Earlier version used
        // `\(next.phase)` which calls `String(describing:)` and for
        // `.waitingForApproval(PermissionContext)` interpolates the
        // entire context including a Date — different on every
        // SessionStore publish, so the dedupe never fired and `session`
        // was reassigned each tick. That re-rendered the entire chat
        // detail pane at SessionStore's republish frequency, which
        // compounded with the LazyVStack id-extraction cost during
        // streaming.
        // Bucket `lastContextTokens` by 1000 so the status bar's
        // context-% chip ticks visibly during streaming WITHOUT
        // republishing the whole session reference at every assistant
        // chunk (which would re-render the entire detail pane and
        // re-trigger the LazyVStack id-extraction cost on session
        // switch). 1000-token buckets = ≤1 republish per ~1s of
        // streaming, plenty granular for a percentage chip with a
        // 64pt-wide bar.
        let fingerprint = WindowChatSessionPresentationFingerprint(
            displayTitle: next.displayTitle,
            projectName: next.bestProjectName,
            phaseTag: phaseTag(next.phase),
            permissionMode: next.permissionMode,
            modelName: next.modelName,
            contextWindowTokens: next.contextWindowTokens,
            contextTokenBucket: next.lastContextTokens / 1000,
            effortLevel: next.effortLevel,
            cwd: next.cwd,
            agentID: next.agentID,
            originTag: next.origin.rawValue,
            codexControlCapability: next.codexControlCapability,
            tty: next.tty,
            terminalHost: next.terminalHost
        )
        if fingerprint != lastPresentationFingerprint {
            lastPresentationFingerprint = fingerprint
            session = next
        }
        if flatRows.isEmpty,
           !ChatHistoryManager.shared.isFileLoaded(sessionId: sessionId) {
            startHistoryLoadIfNeeded()
        }
    }

    /// Stable case-tag for `SessionPhase`. Stripped of associated
    /// values so semantically-equivalent phase publishes hash to the
    /// same key. The chat header doesn't need approval-context
    /// fields here — `interactiveSurface` reads them off `session`
    /// when an approval is actually pending.
    private func phaseTag(_ phase: SessionPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .processing: return "processing"
        case .waitingForInput: return "waitingForInput"
        case .waitingForApproval: return "waitingForApproval"
        case .compacting: return "compacting"
        case .ended: return "ended"
        }
    }

    private func refreshHistory(from histories: [String: [ChatHistoryItem]]) {
        let items = histories[sessionId] ?? []
        // Bump the stream tick on EVERY publish for this session.
        // Streaming chunks update the last item's text in place
        // without changing item count or last id — `rows` stays
        // stable (good: no LazyVStack diff), but the bottom of the
        // viewport needs to follow the growing text. This tick is
        // the "scroll, don't re-diff" signal.
        if histories[sessionId] != nil {
            streamTick &+= 1
        }
        // Reconcile pending echoes against real JSONL items BEFORE
        // the fingerprint dedupe — even if the slice fingerprint is
        // unchanged from a streaming-chunk republish, a freshly-
        // matched echo still needs to be evicted.
        PendingEchoStore.shared.reconcile(sessionId: sessionId, realItems: items)

        // Tail-aware fingerprint. (count, lastId)-only used to swallow
        // streaming text growth on items at non-tail positions —
        // typically an assistant text item shifted off `last` by a
        // subsequent tool placeholder. The chat would freeze until
        // the next user turn forced a count change. The tail-window
        // factory hashes the last few items' size/status signals so
        // those mid-tail mutations flip the fingerprint and the
        // rebuild fires.
        let next = HistorySliceFingerprint.from(items: items)
        let lastIdShort = String(items.last?.id.prefix(20) ?? "nil")
        if next == lastSliceFingerprint {
            ChatHistoryManager.regressionLog.notice(
                "WCV.refresh SKIP sid=\(self.sessionId.prefix(8), privacy: .public) count=\(items.count) lastId=\(lastIdShort, privacy: .public)"
            )
            // Real items haven't changed structurally, but echoes may
            // have. Rebuild rows from the cached real items so any
            // pending echo evictions land in the visible timeline.
            return
        }
        lastSliceFingerprint = next
        lastRealItems = items
        rebuildRowsWithEchoes()
        let flatLastId = String(flatRows.last?.id.prefix(20) ?? "nil")
        ChatHistoryManager.regressionLog.notice(
            "WCV.refresh REBUILD sid=\(self.sessionId.prefix(8), privacy: .public) raw=\(items.count) grouped=\(self.rows.count) flat=\(self.flatRows.count) rawLast=\(lastIdShort, privacy: .public) flatLast=\(flatLastId, privacy: .public)"
        )
    }

    /// Merge any pending echoes for this session into the cached
    /// real-items slice, then publish `rows`. Called both on JSONL
    /// updates (after `lastRealItems` is refreshed) and on echo-store
    /// publishes (with stale `lastRealItems`).
    private func rebuildRowsWithEchoes() {
        let echoes = PendingEchoStore.shared.echoesBySession[sessionId] ?? []
        let merged: [ChatHistoryItem]
        if echoes.isEmpty {
            merged = lastRealItems
        } else {
            // Echoes always sit at the visible BOTTOM — they're the
            // user's most recent send, posted after every real item
            // currently known. Appending preserves the natural newest-
            // last ordering groupedTimelineRows expects.
            merged = lastRealItems + echoes
        }
        // Apply the pagination window BEFORE grouping. groupedTimelineRows
        // is O(N) over its input — slicing first means a 153k-row session
        // does ~500 items of grouping work per rebuild instead of 153k.
        // Slicing the merged array (not lastRealItems) ensures echoes
        // always end up in the visible suffix even when the user has
        // expanded the window past the echo position.
        let total = merged.count
        totalItemCount = total
        let range = pagination.slice(totalItems: total)
        let sliced: [ChatHistoryItem]
        if range == 0..<total {
            sliced = merged
        } else {
            sliced = Array(merged[range])
        }
        hasMoreAbove = pagination.hasMore(totalItems: total)
        hiddenAboveCount = pagination.hiddenCount(totalItems: total)
        // Per-agent grouping:
        //   * Codex uses the prompt-boundary grouper (CodexTurnGrouper) when
        //     enabled — fold each turn's work behind a leading "Worked …"
        //     header, fold narration as children, keep only the final answer;
        //     the trailing live turn collapses into "Working…". When disabled,
        //     fall back to the legacy consecutive-tool-run coalescing.
        //   * Claude Code uses the trailing-turn_duration grouper
        //     (collapse work behind "Worked for X", keep only the final
        //     answer) when the user hasn't disabled it.
        //   * Everything else keeps today's flat grouping.
        let grouped: [TimelineRow]
        if session?.agentID == .codex,
           ChatVisibilitySelector.shared.rules.collapseCodexTurns {
            grouped = codexGroupedTimelineRows(
                from: sliced,
                sessionIsProcessing: session?.phase == .processing
            )
        } else if session?.agentID == .codex {
            grouped = groupedTimelineRows(from: Self.coalesceCodexToolRuns(sliced))
        } else if session?.agentID == .claudeCode,
                  ChatVisibilitySelector.shared.rules.collapseClaudeTurns {
            grouped = claudeGroupedTimelineRows(from: sliced)
        } else {
            grouped = groupedTimelineRows(from: sliced)
        }
        rows = grouped
        flatRows = FlatChatRow.flatten(
            grouped,
            expanded: TurnExpansionStore.shared.expanded(for: sessionId),
            agentID: session?.agentID
        )
        AgentDiscoveryUtilities.writeLog(
            "[WCV] \(sessionId.prefix(8)) agent=\(session?.agentID.rawValue ?? "?") real=\(lastRealItems.count) sliced=\(sliced.count) grouped=\(grouped.count) flat=\(flatRows.count)"
        )
    }

    /// Replace each maximal run of >=2 consecutive tool-call items with a
    /// single sentinel summary item ("Explored N files · Ran M commands").
    /// Singletons stay as normal rows so a lone command's text is still
    /// visible. Any non-tool item (narration, turn duration) breaks a run, so
    /// summaries never span turn or paragraph boundaries.
    static func coalesceCodexToolRuns(_ items: [ChatHistoryItem]) -> [ChatHistoryItem] {
        var out: [ChatHistoryItem] = []
        var run: [ChatHistoryItem] = []
        func flush() {
            guard !run.isEmpty else { return }
            if run.count >= 2 {
                out.append(makeCodexActivitySummary(from: run))
            } else {
                out.append(contentsOf: run)
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if case .toolCall = item.type {
                run.append(item)
            } else {
                flush()
                out.append(item)
            }
        }
        flush()
        return out
    }

    private static func makeCodexActivitySummary(from run: [ChatHistoryItem]) -> ChatHistoryItem {
        var explored = 0
        var ran = 0
        for item in run {
            guard case .toolCall(let tool) = item.type else { continue }
            if tool.name == "Shell",
               CodexToolActivitySummarizer.category(forCommand: tool.input["command"] ?? "") == .explore {
                explored += 1
            } else {
                ran += 1
            }
        }
        let summary = CodexToolActivity(exploredCount: explored, ranCount: ran).summary
        let sentinel = ToolCallItem(
            name: CodexActivitySummaryView.sentinelToolName,
            input: ["summary": summary],
            status: .success,
            result: nil,
            structuredResult: nil,
            subagentTools: []
        )
        let first = run[0]
        return ChatHistoryItem(
            id: first.id + "-codexgroup",
            type: .toolCall(sentinel),
            timestamp: first.timestamp
        )
    }

    /// Expand the visible window by one increment. Called when the
    /// user taps "Load earlier messages." Re-runs the rebuild so
    /// the new larger slice gets grouped + published.
    func loadEarlier() {
        pagination = pagination.expanded(totalItems: totalItemCount)
        rebuildRowsWithEchoes()
    }
}

struct WindowChatView: View {
    let sessionId: String
    @StateObject private var viewModel: WindowChatViewModel
    @StateObject private var presentation = ChatPresentationState()
    /// Each WindowChatView is its own SwiftUI graph (a child of the
    /// detail pane). Observing here forces re-renders on theme flips
    /// so the composer's MultiLineInput.updateNSView fires and re-
    /// applies textColor / insertionPointColor under the new flavor.
    @ObservedObject private var appearance = AppearanceSelector.shared
    @ObservedObject private var codexConnectedLab = CodexConnectedRuntimeCoordinator.shared
    /// Stable handle to the AppKit chat-table coordinator. Set on
    /// table mount; used to drive explicit re-pinning on
    /// composer-height-changed events.
    @State private var tableProxy: ChatTableProxy?
    /// Whether the user has scrolled close to the top of the chat.
    /// Drives the visibility of the "Load N earlier messages"
    /// affordance — we only show the button when the user is near
    /// the top, matching Slack/ChatGPT. Coarse boolean (not raw
    /// pixel distance) so SwiftUI body doesn't re-evaluate on every
    /// scroll tick.
    @State private var isNearChatTop: Bool = false

    /// Local Cmd-+ / Cmd-= / Cmd-- / Cmd-0 monitor. Mirrors the
    /// notch ChatView's font-scale handler so window-mode users get
    /// the same zoom UX. Reads/writes `AppSettings.chatFontScale`,
    /// which the chat body picks up via `chatFontScaleStorage`.
    @State private var fontSizeMonitor: Any?
    /// Local ESC monitor. Unwinds drill-down overlays innermost-first
    /// (PendingEdit → Plan → ToolDetail) so ESC closes the deepest one
    /// without dismissing the window. NSTextView swallows ESC via
    /// `cancelOperation:`, so a local monitor — not a SwiftUI `.onKey`
    /// modifier — is required to catch it from the chat scrollback.
    @State private var escMonitor: Any?
    /// Local key monitor for keyboard scrolling of the chat
    /// scrollback (PgUp/PgDn, Home/End, Cmd+↑/Cmd+↓, fn+arrows). The
    /// monitor lives at the window level so the bindings work even
    /// while the user is typing in the composer — they're keys that
    /// never legitimately participate in text input, so intercepting
    /// them globally is safe and matches macOS doc-scrolling
    /// expectations.
    @State private var scrollKeyMonitor: Any?
    /// Polls Ghostty/iTerm AX every 1.5s for the live permission-mode
    /// chevron, so the status bar's mode chip reflects Shift+Tab cycles
    /// the user makes directly in the terminal — not just the (lagging)
    /// JSONL writes.
    @State private var modeProbeTimer: Timer?
    @AppStorage("chatFontScale") private var chatFontScaleStorage: Double = 1.0

    init(sessionId: String) {
        self.sessionId = sessionId
        _viewModel = StateObject(wrappedValue: WindowChatViewModel(sessionId: sessionId))
    }

    var body: some View {
        // Paint the entire detail pane with the notch's Catppuccin
        // canvas in a single bottom layer. Doing it once here (instead
        // of per-section .background modifiers) avoids feeding extra
        // size proposals into LazyVStack's placement cache, which
        // otherwise triggers a layout-thrash loop pinning the main
        // thread at 100% CPU (sampled trace:
        //   LazySubviewPlacements.placeSubviews ->
        //   LazyHVStack.lengthAndSpacing -> ViewLayoutEngine.sizeThatFits
        // re-firing every tick).
        ZStack {
            ChatTheme.headerBg.ignoresSafeArea()
            VStack(spacing: 0) {
                content
                if let session = viewModel.session {
                    interactiveSurface(session: session)
                    ChatStatusBar(
                        modelName: session.modelName,
                        projectName: displayPath(session.cwd),
                        contextTokens: session.lastContextTokens,
                        // Same fallback the notch uses: when the
                        // session hasn't had a token-counting JSONL
                        // line yet, contextWindowTokens is 0 and the
                        // % bar would divide by zero (renders 0%).
                        // Fall back to the model's known max window.
                        contextWindow: session.contextWindowTokens > 0
                            ? session.contextWindowTokens
                            : ModelContextWindow.tokens(for: session.modelName),
                        effortLevel: session.effortLevel,
                        // Match the notch: true for Claude (so
                        // ClaudeSettings.effortLevel back-fills the
                        // chip when the session has no per-session
                        // override), false only for Codex (whose
                        // effort comes from elsewhere).
                        useGlobalEffort: session.agentID != .codex,
                        permissionMode: session.permissionMode,
                        // Wire the cycler when the session has a TTY
                        // (Ghostty/iTerm pane to write OSC 7 + Shift-
                        // Tab keystroke to). Editor-host sessions
                        // (Cursor) skip this — same as notch.
                        onCycleMode: session.tty == nil ? nil : {
                            Task { await PermissionModeCycler.cycle(session: session) }
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                }
            }

            if let tool = currentPresentedTool {
                ToolResultDetailView(tool: tool, onDismiss: {
                    presentation.presentedToolId = nil
                })
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }

            if let plan = presentation.presentedPlan {
                PlanDetailView(plan: plan, onDismiss: {
                    presentation.presentedPlan = nil
                })
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }

            if let edit = presentation.presentedPendingEdit {
                PendingEditDetailView(context: edit, onDismiss: {
                    presentation.presentedPendingEdit = nil
                })
                .transition(.move(edge: .trailing))
                .zIndex(3)
            }
        }
        .environment(\.openToolDetail, { id in
            presentation.presentedToolId = id
        })
        .environment(\.openPendingEdit, { ctx in
            presentation.presentedPendingEdit = ctx
        })
        // Propagate the chat font scale to MessageItemView and
        // friends so Cmd-+ / Cmd-- / Cmd-0 visibly resize text
        // (the message subviews read \.chatFontScale).
        .environment(\.chatFontScale, CGFloat(chatFontScaleStorage))
        .onChange(of: chatFontScaleStorage) { _, _ in
            // Zoom flipped: SwiftUI re-renders each row's
            // MessageItemView taller/shorter, but the AppKit
            // document view caches per-row frame heights keyed off
            // the OLD sizeThatFits measurement. Without an explicit
            // re-measure here the next layout pass reuses stale
            // heights — rows overlap and gaps appear, only fixed
            // by switching sessions (which rebuilds the table).
            tableProxy?.invalidateRowHeights()
        }
        .onAppear {
            installFontSizeMonitor()
            installEscMonitor()
            installScrollKeyMonitor()
            startModeProbe()
        }
        .task(id: "\(sessionId)|\(codexConnectedLab.isRunning)") {
            await codexConnectedLab.attachIfLabActive(threadId: sessionId)
        }
        .onDisappear {
            removeFontSizeMonitor()
            removeEscMonitor()
            removeScrollKeyMonitor()
            stopModeProbe()
        }
    }

    /// Install local key monitor for chat scrolling. Bindings:
    ///   - PageUp / PageDown            → page-scroll
    ///   - Home / End                   → top / bottom of document
    ///   - Cmd+↑ / Cmd+↓                → top / bottom (Apple-standard)
    ///
    /// We DO NOT bind any form of plain ↑/↓ to scroll. The earlier
    /// "fn+↑/↓ → 1-line scroll" path was wrong: AppKit sets
    /// `NSEvent.ModifierFlags.function` on EVERY arrow press, not
    /// just when the fn modifier is held — so `(kc=126, fn=true)`
    /// matched plain ↑ too, stealing the keystroke from the focused
    /// composer NSTextView. Symptom: typing in a multi-line composer,
    /// pressing ↑ scrolled chat history instead of moving caret.
    /// PageUp/PageDown cover the line-scroll use case adequately.
    private func installScrollKeyMonitor() {
        guard scrollKeyMonitor == nil else { return }
        scrollKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let proxy = tableProxy else { return event }
            let kc = event.keyCode
            let mods = event.modifierFlags
            let hasCmd = mods.contains(.command)
            // Reject events with extra modifiers we don't bind, so
            // shortcuts like Cmd+Shift+End (text selection in the
            // composer) still work.
            switch (kc, hasCmd) {
            case (116, false):  // PgUp
                proxy.scrollPageUp(); return nil
            case (121, false):  // PgDn
                proxy.scrollPageDown(); return nil
            case (115, false):  // Home
                proxy.scrollToTop(); return nil
            case (119, false):  // End
                proxy.scrollToBottom(); return nil
            case (126, true):   // Cmd+Up
                proxy.scrollToTop(); return nil
            case (125, true):   // Cmd+Down
                proxy.scrollToBottom(); return nil
            default:
                return event
            }
        }
    }

    private func removeScrollKeyMonitor() {
        if let monitor = scrollKeyMonitor {
            NSEvent.removeMonitor(monitor)
            scrollKeyMonitor = nil
        }
    }

    /// Install local ESC monitor. ESC priority order (innermost first):
    ///   1. Close any drill-down overlay (PendingEdit → Plan → ToolDetail)
    ///   2. Cancel an in-flight query if the session is processing
    ///      (Codex/Claude Desktop pattern — ESC mid-stream interrupts)
    ///   3. Clear the composer draft
    /// Always consumes ESC so it never reaches NSTextView (whose
    /// `cancelOperation:` would only blur focus). Composer is reachable
    /// via NotificationCenter; we don't have a direct binding to its
    /// state from here.
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        let presentationRef = presentation
        let viewModelRef = viewModel
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            DispatchQueue.main.async {
                // 1. Drill-down overlays first — innermost wins.
                if presentationRef.presentedPendingEdit != nil {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        presentationRef.presentedPendingEdit = nil
                    }
                    return
                }
                if presentationRef.presentedPlan != nil {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        presentationRef.presentedPlan = nil
                    }
                    return
                }
                if presentationRef.presentedToolId != nil {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        presentationRef.presentedToolId = nil
                    }
                    return
                }
                // 2. Cancel in-flight query if processing.
                if case .processing = viewModelRef.session?.phase {
                    NotificationCenter.default.post(
                        name: WindowComposer.requestCancel,
                        object: nil
                    )
                    return
                }
                // 3. Else clear composer draft.
                NotificationCenter.default.post(
                    name: WindowComposer.requestClearDraft,
                    object: nil
                )
            }
            // Always consume ESC — every branch above does something
            // user-visible. Letting ESC fall through to NSTextView
            // would just blur focus, which collides with our intent.
            return nil
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    /// Poll Ghostty/iTerm AX every 1.5s for the live permission-mode
    /// chevron. Without this, the mode chip in the status bar lags
    /// 1-2s behind a Shift+Tab pressed inside the terminal because
    /// Claude Code only writes `permission-mode` to JSONL on the next
    /// prompt submission.
    private func startModeProbe() {
        guard modeProbeTimer == nil else { return }
        let capturedSessionId = sessionId
        modeProbeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in
                let sessions = await SessionStore.shared.currentSessions()
                guard let live = sessions.first(where: { $0.sessionId == capturedSessionId }) else {
                    return
                }
                if live.isInTmux { return }
                if live.tty == nil { return }
                DispatchQueue.global(qos: .utility).async {
                    let probeStartedAt = Date()
                    let mode: String? = TerminalAdapterRegistry.adapter(for: live) is ITermAdapter
                        ? ITermModeProbe.currentMode(for: live)
                        : GhosttyModeProbe.currentMode(for: live)
                    guard let mode else { return }
                    Task { @MainActor in
                        await SessionStore.shared.applyProbedMode(
                            sessionId: capturedSessionId,
                            mode: mode,
                            startedAt: probeStartedAt
                        )
                    }
                }
            }
        }
    }

    private func stopModeProbe() {
        modeProbeTimer?.invalidate()
        modeProbeTimer = nil
    }

    /// Install the local Cmd-+ / Cmd-= / Cmd-- / Cmd-0 monitor.
    /// Decision logic delegated to the pure-Core
    /// `ChatFontScaleCommand`, which is unit-tested. Local scope
    /// means the monitor only fires while the window is key — no
    /// accidental font-zooms from typing Cmd-+ in another app.
    private func installFontSizeMonitor() {
        guard fontSizeMonitor == nil else { return }
        fontSizeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let cmd = event.modifierFlags.contains(.command)
            let chars = event.charactersIgnoringModifiers ?? ""
            guard let command = ChatFontScaleCommand.decode(
                commandHeld: cmd,
                charactersIgnoringModifiers: chars
            ) else { return event }
            AppSettings.chatFontScale = command.apply(
                to: AppSettings.chatFontScale,
                step: AppSettings.chatFontScaleStep,
                min: AppSettings.chatFontScaleMin,
                max: AppSettings.chatFontScaleMax
            )
            return nil
        }
    }

    private func removeFontSizeMonitor() {
        if let monitor = fontSizeMonitor {
            NSEvent.removeMonitor(monitor)
            fontSizeMonitor = nil
        }
    }

    /// Currently-drilled-down tool, looked up by id from the live
    /// session state on demand. Hooked the same way the notch's
    /// ChatView does it — ToolCallView publishes tool ids via the
    /// `openToolDetail` environment key, and the parent looks the
    /// matching ToolCallItem out of the timeline. We look it up in
    /// the parsed history rows.
    private var currentPresentedTool: ToolCallItem? {
        guard let id = presentation.presentedToolId else { return nil }
        for row in viewModel.rows {
            if case .toolCall(let tool) = row.item.type, row.item.id == id {
                return tool
            }
            for child in row.children {
                if case .toolCall(let tool) = child.type, child.id == id {
                    return tool
                }
            }
        }
        return nil
    }

    /// Either the inline approval bar (when Claude is waiting for
    /// permission on a tool) OR the regular composer. Mirrors the
    /// notch's `inputBar` / `approvalBar` switch.
    @ViewBuilder
    private func interactiveSurface(session: SessionState) -> some View {
        // Codex / Cursor have no hook seam (so tool approvals can't be
        // intercepted), but they DO run as TTY processes — the SAME
        // routing that puts text into a claude-code TUI works for them.
        // Show the composer; only the approval bar is unavailable.
        if session.phase == .ended {
            // Session's cli process has exited; sending would fail
            // with "noTTY". Tell the user explicitly so they can
            // re-attach a terminal instead of typing into a black hole.
            EndedSessionBanner(agent: session.agentID)
        } else if session.agentID == .cursor && session.tty == nil {
            // Cursor IDE Agents Window session: lives inside Cursor.app's
            // webview. The prompt is a Chromium contenteditable that AX
            // doesn't expose, and there's no public IPC keyed by session
            // id. Best honest behavior: render read-only with a banner
            // pointing the user back to Cursor for input. Mirrors the
            // ended-session pattern but lives indefinitely (the session
            // can be live the whole time we're showing this).
            EndedSessionBanner(agent: session.agentID, kind: .readOnlyIDE(host: .cursor))
        } else if session.terminalHost == .zed {
            // Zed-hosted session: agent (claude-acp / codex-acp / cursor)
            // runs as an ACP child of Zed.app over stdio. We can read
            // the JSONL transcript Zed's adapter writes, but we can't
            // inject input into Zed's own GPUI prompt — Zed exposes no
            // public IPC. Read-only banner mirrors the Cursor-IDE case
            // but with Zed-specific copy.
            EndedSessionBanner(agent: session.agentID, kind: .readOnlyIDE(host: .zed))
        } else if session.terminalHost == .claudeDesktop {
            // Claude Desktop spawns claude CLI children over stdio for
            // its MCP server connections / tool runners. Same shape as
            // Zed/Cursor IDE: no TTY, no public IPC for prompt
            // injection. Render read-only banner; transcript is still
            // visible as the JSONL gets written.
            EndedSessionBanner(agent: session.agentID, kind: .readOnlyIDE(host: .claudeDesktop))
        } else if session.agentID == .codex,
                  session.codexControlCapability == .observed {
            // Externally-owned Codex sessions are mirrored here but driven
            // in their owning surface. Codex Desktop can be focused;
            // terminal-owned Codex focuses the terminal instead.
            let threadId = session.sessionId
            let decision = AgentControlSurfacePolicy.decision(
                agentID: session.agentID,
                ownership: codexControlSurfaceOwnership(for: session),
                lifecycle: controlSurfaceLifecycle(for: session),
                codexCapability: session.codexControlCapability
            )
            let action = controlSurfaceAction(for: decision, session: session, threadId: threadId)
            EndedSessionBanner(
                agent: session.agentID,
                kind: .controlSurface(decision: decision),
                onContinue: action,
                continueLabel: decision.primaryActionTitle
            )
        } else if case .waitingForApproval(let ctx) = session.phase,
                  session.agentID == .codex,
                  session.codexControlCapability != .observed {
            if ctx.toolName == "AskUserQuestion" {
                EmptyView()
            } else {
                // Codex app-server approval: the engine asked us to approve a
                // command / file change. Reuse the SAME approval bar as
                // claude-code, but route the decision through the Codex
                // approval bridge (which maps allow/deny to Codex's decision
                // vocabulary and answers the JSON-RPC request).
                codexApprovalBar(session: session, ctx: ctx)
            }
        } else if case .waitingForApproval(let ctx) = session.phase, session.agentID == .claudeCode {
            // AskUserQuestion is rendered inline INSIDE the chat scroll
            // by ToolCallView (AskUserQuestionPendingContent: the radio
            // group + Submit button + keyboard handling). The notch
            // ChatView shows NEITHER an approval bar NOR an input bar
            // while an AUQ is pending — the inline question UI owns
            // keyboard input (arrows / digits / enter / esc via its own
            // NSEvent monitor), and there's no ChatApprovalBar shape
            // that fits a question form. Mirror that here: if the
            // pending approval is AskUserQuestion, render nothing.
            if ctx.toolName == "AskUserQuestion" {
                EmptyView()
            } else {
                approvalBar(session: session, ctx: ctx)
            }
        } else {
            WindowComposer(
                session: session,
                isProcessing: session.phase == .processing || session.phase == .compacting
            )
        }
    }

    private func controlSurfaceLifecycle(for session: SessionState) -> AgentControlLifecycle {
        if session.phase == .ended {
            return .ended
        }
        if session.phase.isWaitingForApproval {
            return .waitingForApproval
        }
        return .live
    }

    private func codexControlSurfaceOwnership(for session: SessionState) -> AgentControlSessionOwnership {
        if session.origin == .codexAppServer {
            return .agentVisorAppServer
        }
        if session.tty != nil {
            return .terminal(host: session.terminalHost)
        }
        return .ownerApp(host: codexOwnerHost(for: session))
    }

    private func codexOwnerHost(for session: SessionState) -> TerminalHost? {
        switch session.terminalHost {
        case .codexApp:
            return .codexApp
        case .unknown, .none:
            return .codexApp
        default:
            return session.terminalHost
        }
    }

    private func controlSurfaceAction(
        for decision: AgentControlSurfaceDecision,
        session: SessionState,
        threadId: String
    ) -> (() -> Void)? {
        switch decision.primaryAction {
        case .openOwnerApp, .approveInOwnerApp:
            return { CodexAgentProvider.openThreadInApp(threadId) }
        case .focusHost:
            return { SessionNavigator.navigateToSession(session) }
        case .none:
            return nil
        }
    }

    /// Approval bar for a Codex app-server approval request. Same UI as
    /// the claude-code `approvalBar`, but the decisions are routed to
    /// `CodexAppServerApprovalBridge` (which maps allow/deny to Codex's
    /// per-request decision vocabulary and answers the JSON-RPC request)
    /// instead of the claude-code hook-socket monitor. The "persist /
    /// don't ask again" path maps to Codex's `acceptForSession`.
    @ViewBuilder
    private func codexApprovalBar(session: SessionState, ctx: PermissionContext) -> some View {
        let sessionId = session.sessionId
        ChatApprovalBar(
            tool: ctx.toolName,
            toolInput: ctx.formattedInput,
            rawInput: ctx.toolInput,
            upstreamSuggestionGateOpen: false,
            sessionCwd: session.cwd,
            onApprove: { _ in
                CodexAppServerApprovalBridge.shared.resolve(sessionId: sessionId, intent: .allow)
            },
            onDeny: { _ in
                CodexAppServerApprovalBridge.shared.resolve(sessionId: sessionId, intent: .deny)
            },
            onApproveAndPersist: { _ in
                CodexAppServerApprovalBridge.shared.resolve(sessionId: sessionId, intent: .allowForSession)
            },
            onUltraplan: {
                CodexAppServerApprovalBridge.shared.resolve(sessionId: sessionId, intent: .deny)
            },
            onExpandPlan: { plan in
                presentation.presentedPlan = plan
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func approvalBar(session: SessionState, ctx: PermissionContext) -> some View {
        ChatApprovalBar(
                tool: ctx.toolName,
                toolInput: ctx.formattedInput,
                rawInput: ctx.toolInput,
                upstreamSuggestionGateOpen: ctx.permissionSuggestions != nil,
                sessionCwd: session.cwd,
                onApprove: { reason in
                    let monitor = AppDelegate.shared?.sessionMonitor
                    monitor?.approvePermission(sessionId: session.sessionId)
                    if let reason, !reason.isEmpty {
                        Task {
                            await SessionSender.send(
                                text: reason,
                                attachments: [],
                                to: session,
                                keepFocusOnHost: false
                            )
                        }
                    }
                },
                onDeny: { reason in
                    let monitor = AppDelegate.shared?.sessionMonitor
                    monitor?.denyPermission(sessionId: session.sessionId, reason: reason)
                },
                onApproveAndPersist: { suggestions in
                    let monitor = AppDelegate.shared?.sessionMonitor
                    monitor?.approvePermission(
                        sessionId: session.sessionId,
                        updatedPermissions: suggestions
                    )
                },
                onUltraplan: {
                    // Ultraplan opens claude.ai web — same as notch.
                    if let url = URL(string: "https://claude.ai/new") {
                        NSWorkspace.shared.open(url)
                    }
                    // Also resolve the approval as deny so the session
                    // doesn't sit stuck waiting.
                    let monitor = AppDelegate.shared?.sessionMonitor
                    monitor?.denyPermission(sessionId: session.sessionId, reason: nil)
                },
                onExpandPlan: { plan in
                    presentation.presentedPlan = plan
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    // The per-pane header (session title + project) was redundant
    // with the selected sidebar row + bottom status bar. Removed in
    // favor of a clean detail pane. If we ever support sidebar
    // collapse, add the header back conditional on `columnVisibility
    // == .detailOnly`.

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.rows.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading chat history…")
                    .font(.caption)
                    .foregroundColor(ChatTheme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.rows.isEmpty {
            Text("No chat history yet")
                .font(.callout)
                .foregroundColor(ChatTheme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // AppKit-backed chat list. The legacy SwiftUI ScrollView +
            // LazyVStack path was structurally too expensive at scale:
            // SwiftUI maintains per-realized-child DisplayList.Item /
            // Update.Action arrays that reallocate on every layout
            // pass via LazyLayoutViewCache.updatePrefetchPhases. At
            // ~hundreds of rows + frequent invalidations (resize,
            // sidebar drag, streaming, font zoom), that pinned the
            // main thread at 99% CPU. NSTableView (view-based, single
            // column) handles row recycling and resize natively.
            // Each cell hosts a SwiftUI MessageItemView in its own
            // NSHostingView, so cascades stay local to one row.
            chatTable
        }
    }

    /// AppKit-backed chat list. The Load Earlier button and the
    /// processing indicator render as siblings ABOVE/BELOW the table
    /// rather than as scrollable rows. That matches modern chat UI
    /// (Slack/ChatGPT show the typing indicator pinned at the bottom
    /// of the conversation, not inside the scrollback) and keeps the
    /// table data source homogeneous — every row in the table is a
    /// real chat item.
    @ViewBuilder
    private var chatTable: some View {
        // Gate: show the load-earlier button only when (a) there are
        // hidden earlier messages AND (b) the user has scrolled near
        // the top of the chat. Matches Slack/ChatGPT — discovery
        // affordance at the natural endpoint of upward scroll, not a
        // permanent header.
        let showLoadEarlier = viewModel.hasMoreAbove && isNearChatTop
        VStack(alignment: .leading, spacing: 0) {
            ChatTableView(
                rows: viewModel.flatRows,
                sessionId: sessionId,
                streamTick: viewModel.streamTick,
                onMount: { proxy in
                    self.tableProxy = proxy
                    proxy.observeNearTop { nearTop in
                        // The coordinator only fires this on flips, so
                        // we don't churn @State on every scroll tick.
                        // Wrapping in withAnimation is fine — the flip
                        // happens at most a handful of times during a
                        // continuous scroll.
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isNearChatTop = nearTop
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.session?.phase == .processing || viewModel.session?.phase == .compacting {
                ProcessingIndicatorView(turnId: viewModel.rows.last?.id ?? sessionId)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The load-earlier affordance lives in the safe-area at
            // the TOP of the chat container. Using `safeAreaInset`
            // (not a ZStack overlay) reserves real layout space — so
            // the table's first row is positioned BELOW the button
            // when it's visible, never under it. When `showLoadEarlier`
            // is false we render an empty 0pt view, so the safe area
            // collapses and the chat reclaims the space.
            if showLoadEarlier {
                LoadEarlierMessagesButton(
                    hiddenCount: viewModel.hiddenAboveCount
                ) {
                    viewModel.loadEarlier()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(ChatTheme.headerBg)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: WindowComposer.composerHeightDidChange
        )) { _ in
            // Composer just grew/shrank — re-pin to the bottom ONLY
            // if the user was already there. Shift+Enter while the
            // user is scrolled up reading older context shouldn't
            // yank the chat downward; the unconditional version did
            // exactly that.
            DispatchQueue.main.async {
                tableProxy?.scrollToBottomIfNearBottom()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: WindowComposer.didSendMessage
        )) { note in
            // Submitting a query is an explicit user action: the
            // viewport must follow, even if the user had scrolled up.
            // Filter on session id so a send in another open chat
            // doesn't yank this one.
            guard (note.object as? String) == sessionId else { return }
            DispatchQueue.main.async {
                tableProxy?.scrollToBottom()
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

}

/// "Load earlier messages" affordance pinned at the top of the chat
/// list when the pagination window has hidden earlier rows.
///
/// Why a separate component: keeping it small and self-contained
/// means it's trivially memoizable by SwiftUI's view-graph
/// (re-renders only when `hiddenCount` changes), so the streaming
/// firehose at the bottom of the chat doesn't churn this row's
/// graph node.
private struct LoadEarlierMessagesButton: View {
    let hiddenCount: Int
    let action: () -> Void

    @State private var isHovered = false

    private var label: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSNumber(value: hiddenCount)) ?? "\(hiddenCount)"
        return "Load \(formatted) earlier message\(hiddenCount == 1 ? "" : "s")"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundColor(isHovered ? ChatTheme.primary : ChatTheme.secondary)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Catppuccin.surface0.opacity(0.7) : Catppuccin.surface0.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Catppuccin.surface1, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
