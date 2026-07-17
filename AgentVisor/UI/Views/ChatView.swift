//
//  ChatView.swift
//  AgentVisor
//
//  Redesigned chat interface with clean visual hierarchy
//

import ApplicationServices
import AgentVisorCore
import Combine
import os
import SwiftUI

// MARK: - Chat Font Scale Environment

/// Multiplier applied to text rendered inside the chat scroll area. Sourced
/// from `AppSettings.chatFontScale` and adjusted at runtime via Cmd-+/-/0.
/// Only views that opt in via `.chatScaledFont(...)` (or read the env
/// directly, like `MarkdownText`) react. Chrome (header, input, status bar,
/// approval bar) keeps `.font(...)` and stays at fixed sizes.
struct ChatFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var chatFontScale: CGFloat {
        get { self[ChatFontScaleKey.self] }
        set { self[ChatFontScaleKey.self] = newValue }
    }
}

private struct ChatScaledFont: ViewModifier {
    @Environment(\.chatFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    func chatScaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(ChatScaledFont(size: size, weight: weight, design: design))
    }
}

/// From-scratch bash syntax highlighter for inline rendering. Produces
/// a SwiftUI `AttributedString` directly from a command string, painting
/// colors via regex — *no* Highlightr, *no* NSAttributedString bridge.
/// Lives at file scope so both `ToolCallView` (compact chat-row, first
/// line only) and `ChatApprovalBar` (full multi-line command inside
/// the approval body) share one source of truth.
///
/// Going through Highlightr brought along enough AppKit-bridged metadata
/// that the chat's flipped LazyVStack measured intrinsic size wrong and
/// produced the empty-space gap, even after we stripped fonts. Pure
/// SwiftUI types end-to-end keeps the layout shape identical to the
/// plain `Text(...)` we used to render before highlighting.
///
/// Trade-off vs Highlightr: lose grammar-driven recognition of
/// variables, comments, and keywords. Offset by a quote-string regex at
/// the end so `"..."` and `'...'` still come out colored and override
/// any colors painted on the contents.
fileprivate enum BashHighlighter {
    /// Roles mirror the `BashTokenRole` enum in `MarkdownRenderer.swift`
    /// (the bash stdout path) so the command line and its stdout share
    /// the same hues. The extra `.quoted` case handles `"..."` / `'...'`
    /// strings, which the stdout path delegates to Highlightr's grammar
    /// but this path skips Highlightr entirely.
    ///
    /// CRITICAL: `color` is a *computed var*, not a stored let. Storing
    /// a Color in a stored property freezes the palette at first access
    /// (see the cautionary comment in `TerminalColors.swift`).
    enum Role {
        case number, path, flag, shellOp, command, quoted
        var color: Color {
            switch self {
            case .number:  return Catppuccin.peach    // Constants/Numbers → Peach
            case .path:    return Catppuccin.teal     // No spec; teal differentiates from blue/sky
            case .flag:    return Catppuccin.mauve    // Yellow has poor contrast on Latte mantle; mauve reads well in both modes
            case .shellOp: return Catppuccin.sky      // Operators → Sky
            case .command: return Catppuccin.blue     // Methods/Functions → Blue
            case .quoted:  return Catppuccin.green    // Strings → Green
            }
        }
    }

    /// Patterns mirror `bashEnrichmentSpecs` in `MarkdownRenderer.swift`
    /// (so colors stay consistent across header and stdout), with a
    /// quote-string pattern appended at the end that overrides whatever
    /// the previous patterns painted on string contents.
    ///
    /// The tuple stores a *role*, not a color. Colors are resolved at
    /// iteration time inside `attributedSingleLine(_:)` so flavor
    /// toggles take effect on the next render. Previously this stored
    /// `Color` values directly, which froze the palette at first
    /// access — see the cautionary comment in `TerminalColors.swift`
    /// above `enum Catppuccin`.
    static let patterns: [(NSRegularExpression?, Role)] = {
        let specs: [(String, Role)] = [
            // Standalone digits → peach.
            (#"\b\d+\b"#, .number),
            // Paths: anything containing at least one slash → teal.
            (#"(?:[\w.~-]*/)+[\w.~-]*"#, .path),
            // Long and short flags → mauve.
            (#"(?<=^|\s)-{1,2}[a-zA-Z_][\w-]*"#, .flag),
            // `2>&1` as one atomic operator (paint after numbers so the
            // leading `2` flips to sky).
            (#"2>&1"#, .shellOp),
            // Logical / grouping / pipeline operators.
            (#"&&|\|\|"#, .shellOp),
            (#"[|;&]"#, .shellOp),
            // Standalone redirect chars (after path matching so adjacent
            // path stays teal and only the `>` itself flips).
            (#"[<>]"#, .shellOp),
            // First identifier of a pipeline segment → blue. With per-
            // line iteration below, `^` matches the start of each line
            // so multi-line bash bodies highlight correctly.
            (#"(?:^|(?<=[;|&]\s))[a-zA-Z_][\w-]*"#, .command),
            // Quoted strings, last so they override interior colors.
            (#""[^"]*""#, .quoted),
            (#"'[^']*'"#, .quoted),
        ]
        return specs.map { (try? NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    /// Return an attributed string for the given bash command. When
    /// `firstLineOnly` is true, only the first line is highlighted —
    /// used by the compact chat-history row. Otherwise the full
    /// multi-line command is highlighted line-by-line, which is the
    /// approval-bar mode.
    static func attributedString(_ command: String, firstLineOnly: Bool = false) -> AttributedString {
        let lines: [String]
        if firstLineOnly {
            lines = [command.components(separatedBy: .newlines).first ?? command]
        } else {
            lines = command.components(separatedBy: .newlines)
        }
        var result = AttributedString("")
        for (i, line) in lines.enumerated() {
            if i > 0 { result.append(AttributedString("\n")) }
            result.append(attributedSingleLine(line))
        }
        return result
    }

    private static func attributedSingleLine(_ line: String) -> AttributedString {
        var attr = AttributedString(line)
        attr.foregroundColor = ChatTheme.secondary
        let nsRange = NSRange(location: 0, length: (line as NSString).length)
        for (regex, role) in patterns {
            guard let regex else { continue }
            // Resolve role to color HERE, at iteration time, so a theme
            // toggle between renders picks up the new palette.
            let color = role.color
            regex.enumerateMatches(in: line, range: nsRange) { match, _, _ in
                guard let match,
                      let stringRange = Range(match.range, in: line),
                      let lower = AttributedString.Index(stringRange.lowerBound, within: attr),
                      let upper = AttributedString.Index(stringRange.upperBound, within: attr) else { return }
                attr[lower..<upper].foregroundColor = color
            }
        }
        return attr
    }
}

/// Where the ChatView is being rendered. The notch panel hangs from
/// the menu bar so the chat is flipped (`scaleEffect(y: -1)`) and the
/// timeline is rendered newest-first; the main window scrolls
/// top-down conventionally. Defaults to `.notch` so the existing
/// notch path is unchanged.
enum ChatViewEmbedStyle {
    case notch
    case window
}

struct ChatView: View {
    let sessionId: String
    let initialSession: SessionState
    let sessionMonitor: ClaudeSessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    let embedStyle: ChatViewEmbedStyle

    @State private var inputText: String = ""
    @State private var history: [ChatHistoryItem] = []
    @State private var session: SessionState
    @State private var isLoading: Bool = true
    @State private var hasLoadedOnce: Bool = false
    @State private var shouldScrollToBottom: Bool = false
    /// Identity-based scroll anchor. SwiftUI 15's `.scrollPosition(id:)`
    /// tracks the id of the item at the chosen anchor as the user scrolls,
    /// and re-positions to that item on layout change. Replaces the prior
    /// pixel-offset save/restore (which drifted with LazyVStack height
    /// estimates) and the always-mount fixed-height approach (which also
    /// drifted). Because the anchor is the item id rather than a pixel
    /// number, layout changes (new messages, row realization) leave the
    /// anchored item visually fixed.
    ///
    /// Anchor `.bottom` of the unflipped viewport == visual TOP after the
    /// `.scaleEffect(y: -1)` flip, which is where the user's "I'm reading
    /// here" gaze sits. Persists across notch close/reopen because the
    /// contentView is always-mounted and ChatView's `@State` survives.
    @State private var anchorItemId: String? = nil
    @State private var isAutoscrollPaused: Bool = false
    @State private var isBottomVisible: Bool = true
    @State private var lastLocalSendTime: Date = .distantPast
    /// Last user-submitted text, kept around so a Ctrl+C cancel can
    /// restore it to the input field — mirrors claude-code's TUI auto-
    /// restore behavior. Persists across turns; the "input is empty"
    /// guard in `cancelQuery` is what prevents stale restores from
    /// clobbering text the user has started typing in the meantime.
    @State private var lastSubmittedText: String = ""
    @State private var attachments: [ImageAttachment] = []
    @State private var localEscMonitor: Any?
    @State private var localFontSizeMonitor: Any?
    @State private var localPageScrollMonitor: Any?
    @State private var modeProbeTimer: Timer?
    @StateObject private var inputFocus = InputFocusController()
    @FocusState private var isInputFocused: Bool
    @StateObject private var slashController = SlashCommandPopoverController()
    /// Holds the id of the tool whose result is currently drilled into.
    /// Lives in a class so NSEvent monitor closures can read its current
    /// value (struct @State captured in a closure goes stale).
    @StateObject private var presentation = ChatPresentationState()

    /// Font scale for the chat scroll area. Cmd-+/-/0 mutates
    /// `AppSettings.chatFontScale`; @AppStorage observes UserDefaults and
    /// rebuilds the body so the environment value flows through.
    @AppStorage("chatFontScale") private var chatFontScaleStorage: Double = 1.0

    init(sessionId: String, initialSession: SessionState, sessionMonitor: ClaudeSessionMonitor, viewModel: NotchViewModel, embedStyle: ChatViewEmbedStyle = .notch) {
        self.sessionId = sessionId
        self.initialSession = initialSession
        self.sessionMonitor = sessionMonitor
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.embedStyle = embedStyle
        self._session = State(initialValue: initialSession)

        // Initialize from cache if available (prevents loading flicker on view recreation)
        let cachedHistory = ChatHistoryManager.shared.history(for: sessionId)
        let alreadyLoaded = !cachedHistory.isEmpty
        self._history = State(initialValue: cachedHistory)
        self._isLoading = State(initialValue: !alreadyLoaded)
        self._hasLoadedOnce = State(initialValue: alreadyLoaded)

        // Restore any unsent draft saved when the chat view was last torn down
        // (notch closed, ESC pressed, or switched away). Drafts are per-session
        // and in-memory only, so they survive close/reopen within a launch.
        let draft = DraftStore.shared.load(sessionId: sessionId)
        self._inputText = State(initialValue: draft?.text ?? "")
        self._attachments = State(initialValue: draft?.attachments ?? [])
    }

    /// Whether we're waiting for approval
    private var isWaitingForApproval: Bool {
        session.phase.isWaitingForApproval
    }

    /// Extract the tool name if waiting for approval
    private var approvalTool: String? {
        session.phase.approvalToolName
    }


    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header is now rendered by NotchView's openedHeaderContent
                // (single chrome row with `< sessionTitle` on the leading
                // edge and `≡ ×` on the trailing edge). The previous
                // separate `chatHeader` row stacked a second 44 pt-tall
                // header beneath that, wasting vertical space.

                // Messages (with optional tool-detail overlay)
                ZStack {
                    Group {
                        if isLoading {
                            loadingState
                        } else if history.isEmpty {
                            emptyState
                        } else {
                            messageList
                        }
                    }
                    .allowsHitTesting(presentation.presentedToolId == nil && presentation.presentedPlan == nil && presentation.presentedPendingEdit == nil)

                    if let tool = currentPresentedTool {
                        ToolResultDetailView(tool: tool, onDismiss: dismissToolDetail)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }

                    if let plan = presentation.presentedPlan {
                        PlanDetailView(plan: plan, onDismiss: dismissPlan)
                            .transition(.move(edge: .trailing))
                            .zIndex(2)
                    }

                    if let edit = presentation.presentedPendingEdit {
                        PendingEditDetailView(context: edit, onDismiss: dismissPendingEdit)
                            .transition(.move(edge: .trailing))
                            .zIndex(3)
                    }
                }
                .environment(\.openToolDetail, openToolDetail)
                .environment(\.openPendingEdit, openPendingEdit)

                // Approval bar for tool permissions; input bar for chat.
                // AskUserQuestion shows neither — its rich inline rendering
                // above provides the question + nav hint, and an NSEvent
                // monitor on that view handles arrows / digits / enter /
                // esc. Adding the input bar back here would auto-focus
                // its TextField and intercept arrow keys before they
                // reach the question UI's monitor (regression we hit
                // when we tried this in option (a)).
                // While the plan drill-down is open, hide the bottom
                // bar so the plan reader owns the full notch height.
                // Restoring it on dismiss is automatic — the binding
                // flips back to nil.
                if presentation.presentedPlan == nil && presentation.presentedPendingEdit == nil {
                    // Animation scoped to just the approvalBar↔inputBar
                    // toggle. Previously a `.animation(value: isWaitingForApproval)`
                    // wrapped the entire ChatView, which propagated the
                    // 350ms spring to every descendant including the message
                    // list — combined with `.animation(value: isProcessing)`
                    // on the LazyVStack, two overlapping springs interpolated
                    // y-offsets across the whole chat history during
                    // streaming, perceived as the chat "slowly drifting up"
                    // after an AskUserQuestion submit (memory:
                    // feedback_lazyvstack_count_animation.md — same class
                    // of bug as the count-animation cascade, different
                    // trigger).
                    Group {
                        if let tool = approvalTool {
                            if tool != "AskUserQuestion" {
                                approvalBar(tool: tool)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                                        removal: .opacity
                                    ))
                            }
                            // else: render nothing so the question UI owns keyboard.
                        } else {
                            inputBar
                                .transition(.opacity)
                        }
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isWaitingForApproval)
                }

                // Ghostty-style status bar under the input. Cycle action is
                // wired only when the session has a TTY — the cycler writes
                // OSC 7 markers and queries pane indices via AppleScript,
                // both of which require a terminal pane. For editor hosts
                // (Cursor / VS Code extension) the status bar shows mode as
                // a static label; the user cycles via `Shift+Tab` inside
                // their IDE's chat input instead.
                ChatStatusBar(
                    modelName: session.modelName,
                    // Status bar's "location" slot — the working directory.
                    // Earlier this bound to `session.displayTitle`, which
                    // resolves to `sessionName` first (e.g. "agent-visor-dev"
                    // from /rename) and only falls through to the cwd if
                    // no session name is set. The header chrome already
                    // shows the session name on the leading edge of the
                    // open panel, so the status bar should be the cwd —
                    // tildified so a long absolute path fits.
                    projectName: ChatStatusLocationFormatter.displayPath(session.cwd),
                    contextTokens: session.lastContextTokens,
                    contextWindow: session.contextWindowTokens > 0
                        ? session.contextWindowTokens
                        : ModelContextWindow.tokens(for: session.modelName),
                    effortLevel: session.effortLevel,
                    useGlobalEffort: session.agentID != .codex,
                    permissionMode: session.permissionMode,
                    onCycleMode: session.tty == nil ? nil : {
                        Task { await PermissionModeCycler.cycle(session: session) }
                    }
                )
            }
        }
        .environment(\.chatFontScale, CGFloat(chatFontScaleStorage))
        .animation(nil, value: viewModel.status)
        .task {
            // Skip if already loaded (prevents redundant work on view recreation)
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true

            // If previously visited and fully loaded, use cached history
            if ChatHistoryManager.shared.isFileLoaded(sessionId: sessionId) {
                history = ChatHistoryManager.shared.history(for: sessionId)
                isLoading = false
                if embedStyle == .window { shouldScrollToBottom = true }
                return
            }

            // Always load from JSONL file to get full history
            // (hook events only capture recent items, not the full conversation)
            await ChatHistoryManager.shared.loadFromFile(sessionId: sessionId, cwd: session.cwd)
            history = ChatHistoryManager.shared.history(for: sessionId)

            withAnimation(.easeOut(duration: 0.2)) {
                isLoading = false
            }

            // Window-mode: ScrollView's natural starting position is
            // content-top (= oldest). Notch is flipped, so content-top
            // is naturally visual-bottom and no nudge is needed. In
            // window-mode we explicitly scroll to bottom after history
            // populates so the user sees the most recent message on
            // mount, matching the notch's perceived behavior.
            if embedStyle == .window {
                shouldScrollToBottom = true
            }
        }
        .onReceive(ChatHistoryManager.shared.$histories) { histories in
            // Update when count changes, last item differs, or content changes (e.g., tool status)
            if let newHistory = histories[sessionId] {
                let countChanged = newHistory.count != history.count
                let lastItemChanged = newHistory.last?.id != history.last?.id
                // Always update - the @Published ensures we only get notified on real changes
                // This allows tool status updates (waitingForApproval -> running) to reflect
                if countChanged || lastItemChanged || newHistory != history {
                    // After sending a local message, suppress JSONL sync for 5s
                    // so the immediate message doesn't disappear
                    let timeSinceSend = Date().timeIntervalSince(lastLocalSendTime)
                    if timeSinceSend < 5.0 && newHistory.count <= history.count {
                        // JSONL hasn't caught up yet, keep local history
                        return
                    }
                    history = newHistory

                    // Auto-scroll to bottom only if autoscroll is NOT paused
                    if !isAutoscrollPaused && countChanged {
                        shouldScrollToBottom = true
                    }

                    // If we have data, skip loading state (handles view recreation)
                    if isLoading && !newHistory.isEmpty {
                        isLoading = false
                    }
                }
            } else if hasLoadedOnce {
                // Session was loaded but is now gone (removed via /clear) - navigate back
                viewModel.exitChat()
            }
        }
        .onReceive(sessionMonitor.$instances) { sessions in
            if let updated = sessions.first(where: { $0.sessionId == sessionId }),
               updated != session {
                // Check if permission was just accepted (transition from waitingForApproval to processing)
                let wasWaiting = isWaitingForApproval
                session = updated
                let isNowProcessing = updated.phase == .processing
                let isNowWaiting = updated.phase.isWaitingForApproval

                if wasWaiting && isNowProcessing {
                    // Scroll to bottom after permission accepted (with slight delay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        shouldScrollToBottom = true
                    }
                }

                // Scroll to bottom when an approval *starts*, so the inline
                // diff (rendered in the chat row for Edit) lands flush above
                // the approval bar. Without this, a user scrolled up reading
                // older history would only see the bar's options without the
                // diff context. The render usually races the layout pass —
                // delay a frame so the row's intrinsic height is known.
                if !wasWaiting && isNowWaiting {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        shouldScrollToBottom = true
                    }
                }
            }
        }
        .onChange(of: canSendMessages) { _, canSend in
            // Auto-focus input when tmux messaging becomes available
            if canSend {
                inputFocus.focus()
                isInputFocused = true
            }
        }
        .onAppear {
            // Auto-focus input when chat opens. The focus call hops to the
            // main queue so it lands after SwiftUI mounts the NSTextView,
            // which makes keyboard entry to chat (Enter from session list)
            // type-ready immediately without a click.
            if canSendMessages {
                inputFocus.focus()
                isInputFocused = true
            }
            // Bind cwd so project-scoped skills are picked up, and clear
            // the catalog so a freshly opened panel re-reads disk on
            // first / (covers the case where the user installed a
            // plugin between sessions).
            let cwdURL = session.cwd.isEmpty ? nil : URL(fileURLWithPath: session.cwd)
            slashController.bindSession(cwd: cwdURL)
            slashController.invalidateCatalog()
            // Local ESC monitor so ESC always exits chat, even when first
            // responder is one of the rendered NSTextViews in chat history
            // (those swallow ESC via cancelOperation: and never bubble it up
            // to NotchPanel.keyDown).
            if localEscMonitor == nil {
                let presentationRef = presentation
                localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53 else { return event }
                    DispatchQueue.main.async {
                        // ESC unwraps drill-down layers innermost-first
                        // before falling through to exitChat:
                        //   1. Pending Edit file reader (back to approval)
                        //   2. Plan reader (back to approval bar)
                        //   3. Tool detail (back to chat history)
                        //   4. Otherwise: exit chat → notch session view
                        if presentationRef.presentedPendingEdit != nil {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                presentationRef.presentedPendingEdit = nil
                            }
                        } else if presentationRef.presentedPlan != nil {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                presentationRef.presentedPlan = nil
                            }
                        } else if presentationRef.presentedToolId != nil {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                presentationRef.presentedToolId = nil
                            }
                        } else if case .chat = viewModel.contentType, viewModel.status == .opened {
                            viewModel.exitChat()
                        }
                    }
                    return nil
                }
            }
            // PgUp / PgDn (= fn+Up/Down on Apple keyboards) page through chat
            // history while the input keeps focus and typed text. Slack and
            // Discord follow the same convention. The chat is bottom-pinned
            // and rendered with .scaleEffect(y: -1), so PgUp visually shows
            // older messages — which means moving the underlying
            // NSScrollView's contentOffset *down* in document space.
            // ChatScrollBridge.scroll handles the direction + clamping.
            if localPageScrollMonitor == nil {
                let chatSessionId = sessionId
                localPageScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 116 || event.keyCode == 121 else { return event }
                    let bridge = ChatScrollBridge.shared
                    let magnitude = bridge.pageScrollDelta(sessionId: chatSessionId)
                    let delta = event.keyCode == 116 ? magnitude : -magnitude
                    bridge.scroll(sessionId: chatSessionId, byY: delta, animated: true)
                    return nil
                }
            }
            // Cmd-+ / Cmd-= scale up, Cmd-- scales down, Cmd-0 resets.
            // We register both `=` (no Shift) and `+` (Shift-=) so users
            // don't have to hold Shift to bump the size on a US layout.
            // Returning nil consumes the event so it doesn't insert into
            // the focused text field.
            if localFontSizeMonitor == nil {
                localFontSizeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.contains(.command) else { return event }
                    guard let chars = event.charactersIgnoringModifiers else { return event }
                    switch chars {
                    case "=", "+":
                        AppSettings.chatFontScale = AppSettings.chatFontScale + AppSettings.chatFontScaleStep
                        return nil
                    case "-":
                        AppSettings.chatFontScale = AppSettings.chatFontScale - AppSettings.chatFontScaleStep
                        return nil
                    case "0":
                        AppSettings.chatFontScale = 1.0
                        return nil
                    default:
                        return event
                    }
                }
            }
            // Poll Ghostty's TUI for the current mode label every second.
            // Claude Code only writes `permission-mode` to JSONL on prompt
            // submission, so without this poll the chip would lag behind
            // any Shift+Tab the user makes directly in the terminal.
            startModeProbe()
        }
        .onDisappear {
            // Persist unsent text + attachments so close/reopen preserves the
            // draft. An empty draft deletes any prior entry, so sending (which
            // clears both) implicitly clears the store too.
            DraftStore.shared.save(
                sessionId: sessionId,
                text: inputText,
                attachments: attachments
            )
            if let monitor = localEscMonitor {
                NSEvent.removeMonitor(monitor)
                localEscMonitor = nil
            }
            if let monitor = localFontSizeMonitor {
                NSEvent.removeMonitor(monitor)
                localFontSizeMonitor = nil
            }
            if let monitor = localPageScrollMonitor {
                NSEvent.removeMonitor(monitor)
                localPageScrollMonitor = nil
            }
            stopModeProbe()
        }
    }

    private func startModeProbe() {
        guard modeProbeTimer == nil else { return }
        let capturedSessionId = sessionId
        let chatLogger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ChatView")
        chatLogger.info("modeProbe START sid=\(capturedSessionId.prefix(8), privacy: .public)")
        // Probe runs on a background queue: AX reads block on Ghostty's
        // scrollback (can be 100KB+ per terminal), and synchronous AX
        // calls on the main thread freeze the UI.
        modeProbeTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task {
                guard let live = await SessionStore.shared.getSession(id: capturedSessionId) else {
                    chatLogger.info("probe-tick: no live session for \(capturedSessionId.prefix(8), privacy: .public)")
                    return
                }
                // Skip tmux sessions — JSONL is authoritative there because
                // the cycle path is direct.
                if live.isInTmux {
                    chatLogger.info("probe-tick: skip tmux session \(capturedSessionId.prefix(8), privacy: .public)")
                    return
                }
                // Skip sessions without a controlling TTY (Cursor's Claude Code
                // extension, headless launchd runs, etc.). The AX probe scrapes
                // a terminal app's scrollback for the mode chevron; without a
                // TTY there's no terminal pane to scrape. JSONL `permission-mode`
                // lines drive the chip for these sessions instead.
                if live.tty == nil {
                    chatLogger.info("probe-tick: skip non-tty session \(capturedSessionId.prefix(8), privacy: .public)")
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    // Capture before the AX read so the timestamp reflects
                    // when the snapshot the probe is reading came into
                    // existence. SessionStore rejects the result if the
                    // user cycled after this point.
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
        let chatLogger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ChatView")
        chatLogger.info("modeProbe STOP sid=\(sessionId.prefix(8), privacy: .public)")
        modeProbeTimer?.invalidate()
        modeProbeTimer = nil
    }

    // MARK: - Header

    @State private var isHeaderHovered = false

    private var chatHeader: some View {
        Button {
            viewModel.exitChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHeaderHovered ? ChatTheme.primary : ChatTheme.secondary)
                    .frame(width: 24, height: 24)

                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? ChatTheme.headerHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ChatTheme.headerBg)
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [fadeColor.opacity(0.7), fadeColor.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: 24) // Push below header
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    /// Whether the session is currently processing
    private var isProcessing: Bool {
        session.phase == .processing || session.phase == .compacting
    }

    /// Live lookup of the tool currently drilled into. Re-resolved every
    /// render so status changes (running → success) flow into the detail.
    private var currentPresentedTool: ToolCallItem? {
        guard let id = presentation.presentedToolId else { return nil }
        for item in history where item.id == id {
            if case .toolCall(let tool) = item.type {
                return tool
            }
        }
        return nil
    }

    private func dismissToolDetail() {
        guard presentation.presentedToolId != nil else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedToolId = nil
        }
    }

    private func openToolDetail(_ historyItemId: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedToolId = historyItemId
        }
    }

    private func presentPlan(_ plan: String) {
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedPlan = plan
        }
    }

    private func dismissPlan() {
        guard presentation.presentedPlan != nil else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedPlan = nil
        }
    }

    private func openPendingEdit(_ ctx: PendingEditContext) {
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedPendingEdit = ctx
        }
    }

    private func dismissPendingEdit() {
        guard presentation.presentedPendingEdit != nil else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            presentation.presentedPendingEdit = nil
        }
    }

    /// Window-mode helper: scroll to the last message id, then flip
    /// `initialScrollSettled` so the fade-in reveals the chat. Two
    /// passes cover the LazyVStack realization race. Re-entry guard:
    /// only the first invocation per ChatView instance does work; on
    /// session switch, the parent (`MainSplitView`) uses `.id(id)`
    /// to recreate ChatView, which resets this flag with the State.
    private func scheduleInitialScroll(proxy: ScrollViewProxy) {
        guard !initialScrollSettled else { return }
        guard let lastId = orderedTimelineRows(history).last?.id else {
            initialScrollSettled = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            proxy.scrollTo(lastId, anchor: .bottom)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            proxy.scrollTo(lastId, anchor: .bottom)
            initialScrollSettled = true
        }
    }

    /// Order timeline rows for the active embed style. Notch chat is
    /// flipped (`scaleEffect(y:-1)`) so rows are emitted newest-first
    /// and re-flipped to read top-down. Window-mode chat is unflipped,
    /// so emit oldest-first and let the scroll position-anchor handle
    /// "newest at the bottom".
    private func orderedTimelineRows(_ history: [ChatHistoryItem]) -> [TimelineRow] {
        let rows = groupedTimelineRows(from: history)
        return embedStyle == .notch ? rows.reversed() : rows
    }

    /// Get the last user message ID for stable text selection per turn
    private var lastUserMessageId: String {
        for item in history.reversed() {
            if case .user = item.type {
                return item.id
            }
            if case .image = item.type {
                return item.id
            }
        }
        return ""
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: ChatTheme.tertiary))
                .scaleEffect(0.8)
            Text("Loading messages...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundColor(ChatTheme.muted)
            Text("No messages yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(ChatTheme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    /// Background color for fade gradients. Matches the chat panel canvas
    /// (`ChatTheme.headerBg`) so the fade dissolves into the surface
    /// instead of banding into a different tone.
    private var fadeColor: Color { ChatTheme.headerBg }

    /// Window-mode only: gates the chat content's visibility for the
    /// first ~100ms after mount. Long histories (1k+ messages) realize
    /// rows lazily and naturally start at content-top; we scroll to
    /// the bottom asynchronously, so the user briefly sees the top of
    /// the chat before the scroll lands. Hiding content during that
    /// window kills the flicker. Notch is unaffected because its
    /// flipped layout puts content-top at visual-bottom (newest)
    /// natively, no jump needed.
    @State private var initialScrollSettled: Bool = false

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // Tightened from 12 → 7. The previous 12pt landed twice
                // around the always-present (but invisible when idle)
                // ProcessingIndicator slot, contributing 24pt of dead air
                // above the latest message. The slot is now elided
                // entirely when !isProcessing, so the only remaining cost
                // is between-message spacing — 7pt is comfortable for
                // chat density and matches Ghostty's TUI more closely.
                LazyVStack(spacing: 7) {
                    // Hidden NSViewRepresentable that walks up to the
                    // enclosing NSScrollView, registers it for save-time
                    // offset access, and applies the saved scroll offset
                    // once after a delay so LazyVStack has time to realize
                    // rows. Lives inside LazyVStack so it sits in the
                    // documentView's view hierarchy (not outside via .background).
                    if #available(macOS 15.0, *) {
                        ChatScrollBridgeRegistrar(sessionId: sessionId)
                            .frame(width: 0, height: 0)
                    }

                    // "bottom" anchor: in notch (flipped) it sits at
                    // LazyVStack's logical TOP (= visual bottom after
                    // flip). In window (un-flipped) it must sit at the
                    // logical BOTTOM so `scrollTo("bottom", anchor:.bottom)`
                    // lands on visual-bottom. Emit it conditionally
                    // here, then again at the end for the window case.
                    if embedStyle == .notch {
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }

                    // Notch: ProcessingIndicator first in source order so
                    // after the y-flip it sits at the visual BOTTOM, just
                    // above the composer. Window (un-flipped): it must be
                    // emitted AFTER the rows so it ends up at the visual
                    // bottom in source order. See the matching block below.
                    if embedStyle == .notch, isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 7)
                            .scaleEffect(x: 1, y: -1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -4)),
                                removal: .opacity
                            ))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                    }

                    ForEach(orderedTimelineRows(history)) { row in
                        TimelineRowView(row: row, sessionId: sessionId)
                            .padding(.horizontal, 7)
                            .scaleEffect(x: 1, y: embedStyle == .notch ? -1 : 1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            ))
                    }

                    // Window: ProcessingIndicator at logical bottom so
                    // it sits between the newest message and the composer,
                    // matching the notch behavior in visual space.
                    if embedStyle == .window, isProcessing {
                        ProcessingIndicatorView(turnId: lastUserMessageId)
                            .padding(.horizontal, 7)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 4)),
                                removal: .opacity
                            ))
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isProcessing)
                    }

                    // Window: bottom anchor at logical bottom of vstack.
                    if embedStyle == .window {
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                // The chat is flipped via `scaleEffect(y: -1)`, so the
                // padding axes are inverted in source vs. visual space:
                //   .padding(.top, …)    → visual BOTTOM of the scroll content
                //                          (gap between last message and inputBar)
                //   .padding(.bottom, …) → visual TOP of the scroll content
                //                          (breathing above the first message)
                // Visual-bottom: 6pt was still too much breathing per
                // user feedback; halved to 3pt. The fade-gradient overlay
                // sits above the input bar (offset y: -24), so it doesn't
                // depend on this padding for visual cover.
                .padding(.top, embedStyle == .notch ? 3 : 12)
                .padding(.bottom, embedStyle == .notch ? 12 : 3)
                // textSelection is environment-propagating: applying
                // it ONCE on the LazyVStack makes every Text descendant
                // selectable while creating a single SelectionOverlay
                // NSView for the whole list. Per-row / per-Text
                // `.textSelection(.enabled)` is forbidden — each call
                // site installs its own SelectionOverlay NSView and the
                // cumulative `setFont:` → `invalidateIntrinsicContentSize`
                // → `_postWindowNeedsUpdateConstraints` walk pins the
                // main thread inside a single
                // GraphHost.flushTransactions cycle. Keep this the
                // ONLY textSelection in the chat tree.
                .textSelection(.enabled)
                // Intentionally no implicit animation on `history.count` OR
                // `isProcessing` on the LazyVStack itself. During a streaming
                // response the parser fires 5+ fileUpdated events over ~30s;
                // an implicit spring keyed on EITHER produces overlapping
                // 300ms layout interpolations across the entire message
                // list, perceived as the chat history slowly drifting
                // upward while "Working …" is
                // visible. Per-item transitions on MessageItemView already
                // handle insertion/removal visuals cleanly. Don't re-add this
                // for "smoothness" without testing a multi-question AskUser
                // form on a long-history session.
            }
            .modifier(IdentityScrollAnchor(anchorItemId: $anchorItemId))
            .scaleEffect(x: 1, y: embedStyle == .notch ? -1 : 1)
            .modifier(ScrollGeometryModifier(
                onScrolledAway: { pauseAutoscroll() },
                onScrolledBack: { if isAutoscrollPaused { resumeAutoscroll() } },
                embedStyle: embedStyle
            ))
            // Window-mode flicker shield. Hides the LazyVStack until
            // the post-mount scroll-to-bottom has had time to land,
            // matching the canonical chat-app pattern (Slack/Discord
            // both render conversation content only after measuring &
            // positioning). Fades in once `initialScrollSettled` flips
            // true. Notch keeps its existing always-visible behavior.
            .opacity(embedStyle == .window && !initialScrollSettled ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: initialScrollSettled)
            .onChange(of: shouldScrollToBottom) { _, shouldScroll in
                if shouldScroll {
                    // Skip the scroll animation when we're already pinned at
                    // the visual bottom. In the flipped layout, contentOffset.y
                    // near 0 means "at bottom"; the ScrollView naturally keeps
                    // us pinned as new content arrives, so re-animating to the
                    // same anchor over and over is just visible motion for
                    // nothing. With ~10k chat items and a burst of 3+ file
                    // updates after a tool completes, the cascading 0.3s
                    // animations read as "the chat is slowly scrolling down."
                    // Same 50pt threshold the ScrollGeometryModifier uses for
                    // its scrolled-away/at-bottom decision.
                    let offsetY = ChatScrollBridge.shared.contentOffsetY(sessionId: sessionId)
                    // Notch-flipped: y near 0 means visual-bottom.
                    // Window: we don't have the maxOffset here (the
                    // bridge only returns y), so unconditionally scroll
                    // — that's the safe default and avoids the "land
                    // at top of chat" symptom from the un-flip change.
                    let alreadyPinned = embedStyle == .notch && (offsetY ?? .infinity) < 50
                    if alreadyPinned {
                        // Already at bottom — let the natural pin handle it.
                    } else if embedStyle == .window {
                        // Window: scroll to the actual last message id —
                        // the LazyVStack's "bottom" sentinel may not be
                        // realized yet on a 1k-message history, but the
                        // last message certainly is (we just rendered
                        // it). Two passes (immediate + delayed) cover
                        // the lazy-realization race.
                        let lastId = orderedTimelineRows(history).last?.id
                        if let lastId {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.none) {
                                    proxy.scrollTo(lastId, anchor: .bottom)
                                }
                            }
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    shouldScrollToBottom = false
                    resumeAutoscroll()
                }
            }
            .onAppear {
                guard embedStyle == .window else { return }
                if !history.isEmpty {
                    scheduleInitialScroll(proxy: proxy)
                }
            }
            .onChange(of: history.count) { oldValue, newValue in
                // After history loads asynchronously (cold start), the
                // .onAppear above ran with empty `history`. Trigger
                // the initial scroll on the first non-empty assignment
                // so the user lands at newest. Guarded to window-mode.
                guard embedStyle == .window else { return }
                if oldValue == 0, newValue > 0 {
                    scheduleInitialScroll(proxy: proxy)
                }
            }
        }
    }

    // MARK: - Input Bar

    /// Whether the composer should accept input for this session.
    /// Delegated to `SessionState.supportsSilentSend`, which is
    /// origin-aware: `.terminal` needs a TTY, `.visorSpawned` is
    /// always true (we own the pty), `.cursorObserved` is always
    /// false (Cursor's extension owns stdin — no silent path).
    private var canSendMessages: Bool {
        session.supportsSilentSend
    }

    /// Placeholder text for the input box. All session origins use
    /// the same prompt now that AX silent-send covers `.cursorObserved`.
    private var composerPlaceholder: String {
        canSendMessages ? "Message Claude (↵ to send)…" : "No terminal connected"
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                        try? FileManager.default.removeItem(at: attachment.url)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 56)
    }

    private func handleImagePaste(_ image: NSImage) {
        guard let url = ImagePasteSender.savePNG(image) else { return }
        let thumbnail = Self.makeThumbnail(from: image, maxSize: 80)
        attachments.append(ImageAttachment(id: UUID(), url: url, thumbnail: thumbnail))
    }

    private static func makeThumbnail(from image: NSImage, maxSize: CGFloat) -> NSImage {
        let size = image.size
        let scale = min(maxSize / size.width, maxSize / size.height, 1.0)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver,
                   fraction: 1.0)
        thumb.unlockFocus()
        return thumb
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slashController.isOpen {
                SlashCommandPopover(controller: slashController) { replacement in
                    inputText = replacement
                    inputFocus.replaceText(replacement, caretAtEnd: true)
                }
                .padding(.horizontal, 16)
                .transition(.opacity)
            }

            if !attachments.isEmpty {
                attachmentStrip
            }

            MultiLineInput(
                text: $inputText,
                placeholder: composerPlaceholder,
                isEnabled: canSendMessages,
                onSubmit: { sendMessage() },
                onImagePasted: { image in handleImagePaste(image) },
                onCycleMode: session.tty == nil ? nil : {
                    Task { await PermissionModeCycler.cycle(session: session) }
                },
                onCancelQuery: isProcessing ? { cancelQuery() } : nil,
                onTextChanged: { newText in
                    slashController.update(composerText: newText)
                },
                slashController: slashController,
                focusController: inputFocus,
                scale: CGFloat(chatFontScaleStorage)
            )
            .frame(minHeight: 20 * CGFloat(chatFontScaleStorage),
                   maxHeight: 60 * CGFloat(chatFontScaleStorage))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(canSendMessages ? ChatTheme.inputBg : ChatTheme.inputBg.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(ChatTheme.inputBorder, lineWidth: 1)
                    )
            )
        }
        // Mirror the chat-row 7pt side gutter so the composer column
        // lines up with the messages above. Was 16pt — combined with the
        // chat row's old 16pt gutter that produced a 32pt empty frame on
        // both sides of the panel.
        .padding(.horizontal, 7)
        // Outer vertical padding around the input bubble. Halved from 9
        // to 4 per user feedback — the 9pt + 10pt inner bubble + 6pt
        // chat-bottom-padding stack still added up to a visible empty
        // band above the bubble. 4pt leaves just enough room for the
        // bubble's drop-shadow / focus ring to land without clipping.
        .padding(.vertical, 4)
        .background(ChatTheme.headerBg)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [fadeColor.opacity(0), fadeColor.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
            .offset(y: -24) // Push above input bar
            .allowsHitTesting(false)
        }
        .zIndex(1) // Render above message list
    }

    // MARK: - Approval Bar

    private func approvalBar(tool: String) -> some View {
        ChatApprovalBar(
            tool: tool,
            toolInput: session.pendingToolInput,
            rawInput: session.activePermission?.toolInput,
            upstreamSuggestionGateOpen: session.activePermission?.permissionSuggestions != nil,
            sessionCwd: session.cwd,
            onApprove: { reason in approvePermission(reason: reason) },
            onDeny: { reason in
                sessionMonitor.denyPermission(sessionId: sessionId, reason: reason)
            },
            onApproveAndPersist: { suggestions in
                sessionMonitor.approvePermission(
                    sessionId: sessionId,
                    updatedPermissions: suggestions
                )
            },
            onUltraplan: { openUltraplanWeb() },
            onExpandPlan: { plan in presentPlan(plan) }
        )
    }

    /// Open claude.ai's web Code surface for plan refinement. The hook
    /// is denied with a short note so claude-code's transcript records
    /// the divert. The URL pattern claude-code uses for cloud-mirrored
    /// Ultraplan isn't exposed in its bundled binary; we open the public
    /// entry point and let the user pick up from there.
    private func openUltraplanWeb() {
        if let url = URL(string: "https://claude.ai/code") {
            NSWorkspace.shared.open(url)
        }
        sessionMonitor.denyPermission(
            sessionId: sessionId,
            reason: "User opted to refine this plan via Ultraplan on the web."
        )
    }

    // MARK: - Autoscroll Management

    /// Pause autoscroll (user scrolled away from bottom). New messages
    /// stay below the viewport instead of yanking the user back to the
    /// bottom while they're reading older content.
    private func pauseAutoscroll() {
        isAutoscrollPaused = true
    }

    /// Resume autoscroll. New messages auto-scroll to the bottom again.
    private func resumeAutoscroll() {
        isAutoscrollPaused = false
    }

    // MARK: - Actions

    private func focusTerminal() {
        Task {
            if let pid = session.pid {
                _ = await YabaiController.shared.focusWindow(forClaudePid: pid)
            } else {
                _ = await YabaiController.shared.focusWindow(forWorkingDirectory: session.cwd)
            }
        }
    }

    private func approvePermission(reason: String? = nil) {
        sessionMonitor.approvePermission(sessionId: sessionId)
        // If the user typed feedback alongside the Yes (Tab-to-amend), send
        // it as a follow-up user message — matches Claude Code's TUI flow:
        // tool runs, then the feedback shows up in the conversation as
        // additional context Claude reads on the next turn.
        guard let reason = reason, !reason.isEmpty else { return }
        let userItem = ChatHistoryItem(
            id: "user-\(UUID().uuidString)",
            type: .user(reason),
            timestamp: Date()
        )
        history.append(userItem)
        lastLocalSendTime = Date()
        resumeAutoscroll()
        shouldScrollToBottom = true
        Task {
            await sendToSession(reason, attachments: [])
        }
    }

    private func denyPermission() {
        sessionMonitor.denyPermission(sessionId: sessionId, reason: nil)
    }

    /// Cancel the in-flight Claude query for this session. Wired to
    /// Ctrl+C in the chat input. Sends ESC to the session's terminal
    /// pane, which is the keystroke claude-code's TUI interprets as
    /// "interrupt the current generation."
    ///
    /// claude-code's cancel path returns `aborted_streaming` and
    /// deliberately skips the Stop hook (see `query.ts`), so the only
    /// signal back to agent-visor is the synthetic `[Request
    /// interrupted by user]` user-message that lands in the JSONL.
    /// `JSONLInterruptWatcher` picks that up and drives
    /// `processInterrupt`, but the file write can land 200-1000ms
    /// after the keystroke — long enough that the orange "Processing…"
    /// chip felt stuck.
    ///
    /// So once AppleScript confirms the keystroke was delivered, we
    /// drive `interruptDetected` ourselves on the main thread. The
    /// JSONL watcher will fire later for the same session and call the
    /// same handler again; `processInterrupt` is idempotent so the
    /// double-call costs nothing.
    ///
    /// Also restores the just-submitted text to the input field,
    /// mirroring claude-code's REPL auto-restore (REPL.tsx:3010). The
    /// "input is empty" guard prevents clobbering text the user typed
    /// in the gap between submit and cancel.
    private func cancelQuery() {
        guard isProcessing else { return }
        let target = session
        let textToRestore = lastSubmittedText
        let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "ChatView")
        logger.info("cancel sid=\(target.sessionId.prefix(8), privacy: .public)")
        let isITerm = TerminalAdapterRegistry.adapter(for: target) is ITermAdapter
        // AppleScript round-trips can take 100-500ms; run off the main
        // queue so the chat UI stays responsive while the keystroke
        // dispatches.
        DispatchQueue.global(qos: .userInitiated).async {
            let ok: Bool
            if isITerm {
                ok = ITermAdapter().sendEscape(toSession: target)
            } else {
                ok = GhosttyScripting.sendKeystroke(named: "escape", toSession: target)
            }
            logger.info("cancel result=\(ok, privacy: .public)")
            guard ok else { return }

            // Claude Code's REPL auto-restores the canceled prompt
            // text into its TUI input buffer (REPL.tsx:3010). If we
            // leave it there, the user's next message gets appended
            // to the restored text and submitted as "query Aquery B".
            // Wait for the restore to render (~150ms in practice on
            // a populated buffer), then clear it.
            //
            // iTerm2: one `write text "\u{15}"` (Ctrl+U / NAK) — Ink
            // sees a single kill-to-start-of-line event, instant.
            //
            // Ghostty: N backspace keystrokes batched into one
            // AppleScript tell-block. We tested Ctrl+U via three
            // channels (send key with modifier, input text, perform
            // action text:) — all consumed/filtered by Ghostty before
            // reaching the PTY (xxd-traced 2026-05-12). Backspace
            // named-keys are the only channel that delivers, even
            // though Ink re-renders per char and the user sees a
            // visible type-erase. Open upstream issue if priority.
            let restoreCount = textToRestore.count
            if restoreCount > 0 {
                usleep(200_000)
                let cleared: Bool
                if isITerm {
                    cleared = ITermAdapter().sendCtrlU(toSession: target)
                } else {
                    cleared = GhosttyScripting.sendBackspaces(count: restoreCount, toSession: target)
                }
                logger.info("cancel clear n=\(restoreCount, privacy: .public) ok=\(cleared, privacy: .public)")
            }

            DispatchQueue.main.async {
                if inputText.isEmpty, !textToRestore.isEmpty {
                    inputText = textToRestore
                }
                Task {
                    await SessionStore.shared.process(.interruptDetected(sessionId: target.sessionId))
                }
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentAttachments = attachments
        guard !text.isEmpty || !currentAttachments.isEmpty else { return }

        // Remember this submission so Ctrl+C can restore it to the
        // input. Image-only sends don't restore — there's no plain-text
        // representation to put back. Empty submissions don't overwrite
        // a meaningful previous value.
        if !text.isEmpty {
            lastSubmittedText = text
        }

        inputText = ""
        attachments = []
        // Programmatic clears don't fire NSTextView's textDidChange, so
        // tell the popover state machine to close itself.
        slashController.close()

        // Show the message immediately and suppress JSONL sync briefly
        lastLocalSendTime = Date()
        let displayText: String
        if text.isEmpty {
            // Image-only: render a lightweight placeholder so the user sees something in history
            displayText = currentAttachments.map { _ in "[Image]" }.joined(separator: " ")
        } else if currentAttachments.isEmpty {
            displayText = text
        } else {
            let prefix = currentAttachments.map { _ in "[Image]" }.joined(separator: " ")
            displayText = "\(prefix) \(text)"
        }
        let userItem = ChatHistoryItem(
            id: "user-\(UUID().uuidString)",
            type: .user(displayText),
            timestamp: Date()
        )
        history.append(userItem)

        // Resume autoscroll when user sends a message
        resumeAutoscroll()
        shouldScrollToBottom = true

        Task {
            await sendToSession(text, attachments: currentAttachments)
            scheduleAttachmentCleanup(currentAttachments)
        }
    }

    private func sendToSession(_ text: String, attachments: [ImageAttachment]) async {
        await SessionSender.send(
            text: text,
            attachments: attachments,
            to: session,
            keepFocusOnHost: true,
            onEscDuringSend: {
                if case .chat = viewModel.contentType, viewModel.status == .opened {
                    viewModel.exitChat()
                }
            }
        )
    }

    private func scheduleAttachmentCleanup(_ attachments: [ImageAttachment]) {
        guard !attachments.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            for attachment in attachments {
                try? FileManager.default.removeItem(at: attachment.url)
            }
        }
    }

    private func findTmuxTarget(tty: String) async -> TmuxTarget? {
        guard let tmuxPath = await TmuxPathFinder.shared.getTmuxPath() else {
            return nil
        }

        do {
            let output = try await ProcessExecutor.shared.run(
                tmuxPath,
                arguments: ["list-panes", "-a", "-F", "#{session_name}:#{window_index}.#{pane_index} #{pane_tty}"]
            )

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.components(separatedBy: " ")
                guard parts.count >= 2 else { continue }

                let target = parts[0]
                let paneTty = parts[1].replacingOccurrences(of: "/dev/", with: "")

                if paneTty == tty {
                    return TmuxTarget(from: target)
                }
            }
        } catch {
            return nil
        }

        return nil
    }
}

// MARK: - Timeline Grouping

/// Internal (was private) so WindowChatView can mount the same row
/// shape the notch produces. Identifiable keys on item id so SwiftUI
/// row diffing matches the notch's behavior.
///
/// CRITICAL — `id` is STORED, not computed. SwiftUI's ForEach diff
/// reads `id` via a key-path getter every frame; with a computed
/// `var id: String { item.id }` the keypath read does
/// `swift_getAtKeyPath` over the whole `TimelineRow`, which triggers
/// `outlined init with copy of ChatHistoryItem` → recursive copies
/// of `ChatHistoryItemType` and its `[ToolResultData]?` payloads.
/// On a session with thousands of items that pins the main thread
/// at 99%. Storing `id` once at init keeps the keypath read flat.
/// See [[feedback_foreach_keypath_deep_copy]].
struct TimelineRow: Identifiable, Equatable {
    let id: String
    let item: ChatHistoryItem
    let children: [ChatHistoryItem]

    init(item: ChatHistoryItem, children: [ChatHistoryItem]) {
        self.id = item.id
        self.item = item
        self.children = children
    }
}

/// Visibility predicate with explicit rules. Pure function — no actor
/// isolation, no global reads. The caller (groupedTimelineRows) reads
/// `ChatVisibilitySelector.shared.rules` ONCE and passes the value
/// through. Earlier draft read `.shared.rules` per call inside this
/// function, which on big sessions (10k+ items) compounded with
/// streaming-rate rebuilds (5-10 Hz) into a measurable CPU hotspot.
///
/// The empty-text guard for prose kinds happens BEFORE the rules check
/// so an empty assistant string gets dropped even when the user has
/// "Show assistant messages" on — the row would render a blank space.
nonisolated func shouldRenderHistoryItem(
    _ item: ChatHistoryItem,
    rules: ChatVisibilityRules
) -> Bool {
    switch item.type {
    case .assistant(let text), .thinking(let text):
        // Empty rows render nothing but still take a LazyVStack slot
        // plus surrounding spacing — drop them unconditionally.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
    case .user(let text):
        // Two distinct empties for user messages:
        //   1. raw text trimmed → empty
        //   2. text contains ONLY hidden injection tags (e.g.
        //      <system-reminder>…</system-reminder>) which the
        //      `UserMessageView` strips, then returns `EmptyView()`.
        //      Without parsing here, those messages survive the
        //      filter, claim a LazyVStack slot, and produce a fat
        //      phantom gap (often before tool-call rows that follow
        //      a system reminder — the source of the user-reported
        //      "huge gap before bash command").
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        let parsed = InjectionTagParser.parse(text)
        if parsed.plainText.isEmpty && parsed.attachments.isEmpty {
            return false
        }
    case .image, .toolCall, .interrupted, .turnDuration, .recap,
         .compactBoundary, .localCommandOutput:
        break
    }
    let kind = ChatItemKindProjector.kind(for: item.type)
    return ChatVisibilityFilter.shouldShow(kind, rules: rules)
}

/// Maps the main app's `ChatHistoryItemType` (which carries payload)
/// onto the Core-side `ChatItemKind` (case-only, agent-agnostic) so
/// `ChatVisibilityFilter` can decide visibility without knowing about
/// SwiftUI / AppKit / agent-specific tool names.
enum ChatItemKindProjector {
    nonisolated static func kind(for type: ChatHistoryItemType) -> ChatItemKind {
        switch type {
        case .user, .image: return .userMessage
        case .assistant: return .assistantMessage
        case .thinking: return .thinking
        case .interrupted: return .interrupted
        case .turnDuration: return .turnDuration
        case .recap: return .recap
        case .compactBoundary: return .compactBoundary
        case .localCommandOutput: return .localCommandOutput
        case .toolCall(let tool):
            // The agent that produced this row isn't tracked on the
            // ChatHistoryItem — the legacy chat path is claude-code-only,
            // and Codex uses a parallel renderer. Mapping via
            // `.claudeCode` is safe; raw names that don't match its
            // table fall through to `.generic`, which the filter routes
            // through `showOtherTools`.
            let canonical = ToolNameMapper.canonical(for: tool.name, agent: .claudeCode)
            return .toolCall(canonical)
        }
    }
}

func isTurnDetailItem(_ item: ChatHistoryItem) -> Bool {
    switch item.type {
    case .thinking, .toolCall, .localCommandOutput, .recap, .compactBoundary, .interrupted:
        return true
    case .assistant, .user, .image, .turnDuration:
        return false
    }
}

@MainActor
func groupedTimelineRows(from history: [ChatHistoryItem]) -> [TimelineRow] {
    // Snapshot the visibility rules ONCE per rebuild so the predicate
    // applied to each item is a plain value-type read, not a global
    // singleton dereference. Streaming rebuilds at 5-10 Hz × 10k items
    // would otherwise dispatch to the @MainActor singleton 50k+ times
    // per second — measurable CPU climb on big sessions.
    let rules = ChatVisibilitySelector.shared.rules
    let items = history.filter { shouldRenderHistoryItem($0, rules: rules) }
    var rows: [TimelineRow] = []
    var index = 0

    while index < items.count {
        let item = items[index]

        if case .turnDuration = item.type {
            var children: [ChatHistoryItem] = []
            var childIndex = index + 1

            while childIndex < items.count {
                let candidate = items[childIndex]
                guard isTurnDetailItem(candidate) else {
                    break
                }
                children.append(candidate)
                childIndex += 1
            }

            rows.append(TimelineRow(item: item, children: children))
            index = childIndex
        } else {
            rows.append(TimelineRow(item: item, children: []))
            index += 1
        }
    }

    return rows
}

/// Codex-style turn grouping for Claude Code (gated on
/// `collapseClaudeTurns`). Unlike `groupedTimelineRows` — which treats
/// `.turnDuration` as a LEADING delimiter and is wrong for Claude Code,
/// whose `turn_duration` row TRAILS its turn — this projects each item
/// onto a `ClaudeTurnGrouper.ItemDescriptor`, runs the pure Core
/// segmenter, and rebuilds `[TimelineRow]`:
///   * a grouped turn → header parent (the turnDuration item) with the
///     work items as children; the kept final-answer items follow as
///     standalone rows;
///   * everything else → standalone.
/// Narration ids the grouper omitted are simply never looked up, so they
/// vanish from the timeline. Same `shouldRenderHistoryItem` visibility
/// pre-filter as `groupedTimelineRows`.
@MainActor
func claudeGroupedTimelineRows(from history: [ChatHistoryItem]) -> [TimelineRow] {
    guard !history.isEmpty else { return [] }
    let rules = ChatVisibilitySelector.shared.rules

    // Group over the UNFILTERED history. The narration-vs-final-answer
    // split is positional — it needs the turn's WORK items present to
    // mark the boundary. Filtering first (e.g. a user who hides a tool
    // kind) would erase those boundaries and collapse interleaved
    // `text, tool, text, tool, finalText` into a run of consecutive
    // texts, every one of which then survives as "after the last work
    // item." Visibility is applied as a post-pass below instead.
    var itemsById: [String: ChatHistoryItem] = [:]
    itemsById.reserveCapacity(history.count)
    let descriptors: [ClaudeTurnGrouper.ItemDescriptor] = history.map { item in
        itemsById[item.id] = item
        return ClaudeTurnGrouper.ItemDescriptor(
            id: item.id,
            category: claudeTurnCategory(for: item.type)
        )
    }

    let grouped = ClaudeTurnGrouper.group(descriptors)

    var rows: [TimelineRow] = []
    rows.reserveCapacity(grouped.count)
    for row in grouped {
        if row.childIds.isEmpty {
            // Standalone row (prompt, final-answer text, session marker,
            // or live-turn latest text). Apply per-kind visibility here.
            guard let parent = itemsById[row.parentId] else { continue }
            if shouldRenderHistoryItem(parent, rules: rules) {
                rows.append(TimelineRow(item: parent, children: []))
            }
        } else {
            // Collapsible turn. A completed turn's parent is the real
            // turn_duration item; the LIVE turn's parent is synthetic
            // (no backing item) — synthesize a `.turnDuration` with the
            // live sentinel so it routes through CollapsibleTurnHeader and
            // renders "Working…".
            let header: ChatHistoryItem
            if let real = itemsById[row.parentId] {
                header = real
            } else {
                let ts = row.childIds.first.flatMap { itemsById[$0]?.timestamp } ?? Date()
                header = ChatHistoryItem(
                    id: row.parentId,
                    type: .turnDuration(seconds: row.isLive ? ClaudeLiveTurnSentinel.seconds : 0),
                    timestamp: ts
                )
            }
            let children = row.childIds
                .compactMap { itemsById[$0] }
                .filter { shouldRenderHistoryItem($0, rules: rules) }
            // If visibility filtered every child away (e.g. the turn's only
            // work was an empty thinking block), drop the header too — a
            // "Worked" chip with nothing to expand is meaningless.
            guard !children.isEmpty else { continue }
            rows.append(TimelineRow(item: header, children: children))
        }
    }
    return rows
}

/// Codex-style turn grouping for Codex (gated on `collapseCodexTurns`).
/// Codex inserts its `turn_duration` at the START of a turn (and only on
/// `task_complete`), so it can't reuse the trailing-marker Claude grouper.
/// `CodexTurnGrouper` segments on user-prompt boundaries instead, folds the
/// work (commentary / tool calls / terminal) under a leading header, and
/// keeps only the trailing final answer prominent. Interim narration is
/// folded as collapsible children (NOT dropped — Codex commentary carries
/// progress signal). `sessionIsProcessing` drives whether the trailing
/// marker-less turn renders as a live "Working…" header.
@MainActor
func codexGroupedTimelineRows(from history: [ChatHistoryItem], sessionIsProcessing: Bool) -> [TimelineRow] {
    guard !history.isEmpty else { return [] }
    let rules = ChatVisibilitySelector.shared.rules

    // Group over UNFILTERED history (positional boundaries — same rationale
    // as claudeGroupedTimelineRows); apply visibility as a post-pass below.
    var itemsById: [String: ChatHistoryItem] = [:]
    itemsById.reserveCapacity(history.count)
    let descriptors: [CodexTurnGrouper.ItemDescriptor] = history.map { item in
        itemsById[item.id] = item
        return CodexTurnGrouper.ItemDescriptor(
            id: item.id,
            category: codexTurnCategory(for: item.type)
        )
    }

    let grouped = CodexTurnGrouper.group(descriptors, sessionIsProcessing: sessionIsProcessing)

    var rows: [TimelineRow] = []
    rows.reserveCapacity(grouped.count)
    for row in grouped {
        if row.childIds.isEmpty {
            guard let parent = itemsById[row.parentId] else { continue }
            if shouldRenderHistoryItem(parent, rules: rules) {
                rows.append(TimelineRow(item: parent, children: []))
            }
        } else {
            // Completed turn with a duration → real turn_duration item;
            // live/aborted turn → synthesize a `.turnDuration` header (the
            // live sentinel routes it through CollapsibleTurnHeader as
            // "Working…"; an aborted header shows a static "Worked").
            let header: ChatHistoryItem
            if let real = itemsById[row.parentId] {
                header = real
            } else {
                let ts = row.childIds.first.flatMap { itemsById[$0]?.timestamp } ?? Date()
                header = ChatHistoryItem(
                    id: row.parentId,
                    type: .turnDuration(seconds: row.isLive ? ClaudeLiveTurnSentinel.seconds : 0),
                    timestamp: ts
                )
            }
            let children = row.childIds
                .compactMap { itemsById[$0] }
                .filter { shouldRenderHistoryItem($0, rules: rules) }
            guard !children.isEmpty else { continue }
            rows.append(TimelineRow(item: header, children: children))
        }
    }
    return rows
}

/// Project a `ChatHistoryItemType` onto the Codex grouper's coarse
/// category. Mirrors `claudeTurnCategory` — Codex commentary lands as
/// `.thinking` (→ `.work`, folded), so it collapses for free.
private func codexTurnCategory(for type: ChatHistoryItemType) -> CodexTurnGrouper.ItemCategory {
    switch type {
    case .user, .image:
        return .prompt
    case .assistant:
        return .assistantText
    case .toolCall(let tool):
        if tool.name == "AskUserQuestion" || tool.status == .waitingForApproval {
            return .interactive
        }
        return .work(hasError: tool.status == .error || tool.status == .interrupted)
    case .thinking, .localCommandOutput:
        return .work(hasError: false)
    case .interrupted:
        return .work(hasError: true)
    case .turnDuration:
        return .turnMarker
    case .recap, .compactBoundary:
        return .sessionLevel
    }
}

/// Sentinel `seconds` value marking a synthesized LIVE-turn header (the
/// in-progress turn has no `turn_duration` yet). Real durations are always
/// >= 1 (parser does `max(1, durationMs/1000)`), so -1 is unambiguous.
/// `CollapsibleTurnHeader` renders "Working…" for it instead of a duration.
enum ClaudeLiveTurnSentinel {
    static let seconds = -1
}

/// Project a `ChatHistoryItemType` onto the Core grouper's coarse
/// category. A tool call that errored or was interrupted flags the turn
/// so the collapsed "Worked for X" header can surface a warning glyph.
private func claudeTurnCategory(for type: ChatHistoryItemType) -> ClaudeTurnGrouper.ItemCategory {
    switch type {
    case .user, .image:
        return .prompt
    case .assistant:
        return .assistantText
    case .toolCall(let tool):
        // Action-required tools never fold: an AskUserQuestion prompt, or
        // any tool still awaiting approval, is the thing blocking the user
        // — hiding it behind a collapsed "Worked" header is exactly wrong.
        if tool.name == "AskUserQuestion" || tool.status == .waitingForApproval {
            return .interactive
        }
        return .work(hasError: tool.status == .error || tool.status == .interrupted)
    case .thinking, .localCommandOutput:
        return .work(hasError: false)
    case .interrupted:
        return .work(hasError: true)
    case .turnDuration:
        return .turnMarker
    case .recap, .compactBoundary:
        return .sessionLevel
    }
}

private struct TimelineRowView: View {
    let row: TimelineRow
    let sessionId: String

    var body: some View {
        if case .turnDuration(let seconds) = row.item.type {
            TurnDurationView(seconds: seconds, children: row.children, sessionId: sessionId)
        } else {
            MessageItemView(item: row.item, sessionId: sessionId)
        }
    }
}

/// Formats a session's cwd for the status bar's location chip.
/// Replaces `$HOME` with `~` so paths under the user's home read
/// `~/Personal/agent-visor` instead of the full absolute form.
/// Truncation/middle-shrink is handled by the SwiftUI `Text` modifier
/// in `ChatStatusBar` itself.
private enum ChatStatusLocationFormatter {
    static func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

// MARK: - Message Item View

struct MessageItemView: View {
    let item: ChatHistoryItem
    let sessionId: String

    var body: some View {
        switch item.type {
        case .user(let text):
            UserMessageView(text: text)
        case .image(let image):
            ImageMessageView(image: image)
        case .assistant(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AssistantMessageView(text: text)
            }
        case .toolCall(let tool):
            if tool.name == CodexActivitySummaryView.sentinelToolName {
                CodexActivitySummaryView(summary: tool.input["summary"] ?? "")
            } else {
                ToolCallView(tool: tool, sessionId: sessionId, historyItemId: item.id)
            }
        case .thinking(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ThinkingView(text: text)
            }
        case .interrupted:
            InterruptedMessageView()
        case .turnDuration(let seconds):
            TurnDurationView(seconds: seconds, children: [], sessionId: sessionId)
        case .recap(let text):
            RecapMessageView(text: text)
        case .compactBoundary(let summary, let preTokens, let trigger):
            CompactBoundaryView(summary: summary, preTokens: preTokens, trigger: trigger)
        case .localCommandOutput(let text):
            LocalCommandOutputView(text: text)
        }
    }
}

// MARK: - Codex Tool-Activity Summary

/// One muted line standing in for a run of consecutive Codex tool calls,
/// mirroring the Codex desktop app ("Explored 8 files · Ran 4 commands")
/// instead of flooding the transcript with a row per command. Built by
/// `WindowChatView`'s Codex coalescing pass as a sentinel `.toolCall`.
struct CodexActivitySummaryView: View {
    static let sentinelToolName = "CodexActivitySummary"
    let summary: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundColor(ChatTheme.tertiary)
            Text(summary)
                .chatScaledFont(size: 11)
                .foregroundColor(ChatTheme.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - User Message

struct UserMessageView: View {
    let text: String

    /// Parsed once per render; cheap (string scanning, no regex on the
    /// hot tags). Surfaces IDE attachments as chips and hides
    /// plumbing tags entirely.
    private var parsed: ParsedUserMessage {
        InjectionTagParser.parse(text)
    }

    var body: some View {
        let p = parsed
        // Pure-plumbing message (e.g. only <system-reminder>) — skip
        // the bubble entirely.
        if p.plainText.isEmpty && p.attachments.isEmpty {
            EmptyView()
        } else {
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 6) {
                    if !p.attachments.isEmpty {
                        attachmentChips(p.attachments)
                    }
                    if !p.plainText.isEmpty {
                        MarkdownText(p.plainText, color: Catppuccin.text, fontSize: 13)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ChatTheme.bubbleUser)
                )
            }
        }
    }

    @ViewBuilder
    private func attachmentChips(_ attachments: [ParsedUserMessage.Attachment]) -> some View {
        // Flow chips horizontally — most messages have ≤ 2 attachments
        // so a simple HStack with wrap is overkill; let SwiftUI handle
        // overflow by truncating.
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                AttachmentChipView(attachment: attachment)
            }
        }
    }
}

struct ImageMessageView: View {
    let image: ChatImageAttachment

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            content
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ChatTheme.bubbleUser)
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let nsImage = resolvedImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 360, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(ChatTheme.inputBorder, lineWidth: 1)
                )
        } else {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ChatTheme.secondary)
                Text(image.displayName)
                    .chatScaledFont(size: 12, weight: .medium)
                    .foregroundColor(Catppuccin.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var resolvedImage: NSImage? {
        switch image.source {
        case .localPath:
            return NSImage(contentsOfFile: NSString(string: image.value).expandingTildeInPath)
        case .dataURI:
            let base64 = image.value.components(separatedBy: ",").last ?? image.value
            guard let data = Data(base64Encoded: base64) else { return nil }
            return NSImage(data: data)
        }
    }
}

/// Compact chip representing one injected attachment (e.g. an opened
/// file or a selection). Matches Cursor's chat-input chip style: small
/// icon + filename, muted background, lives at the top of the message.
struct AttachmentChipView: View {
    let attachment: ParsedUserMessage.Attachment

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Catppuccin.subtext.opacity(0.85))
            Text(label)
                .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                .foregroundColor(Catppuccin.text.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.18))
        )
    }

    private var iconName: String {
        switch attachment {
        case .openedFile: return "doc.text"
        case .selection: return "text.cursor"
        }
    }

    private var label: String {
        switch attachment {
        case .openedFile(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .selection(let path, let startLine, let endLine):
            let name = URL(fileURLWithPath: path).lastPathComponent
            if let s = startLine, let e = endLine {
                return s == e ? "\(name):\(s)" : "\(name):\(s)-\(e)"
            }
            return name
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Catppuccin.lavender.opacity(0.85))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            MarkdownText(text, color: Catppuccin.text, fontSize: 13)

            Spacer(minLength: 60)
        }
    }
}

// MARK: - Processing Indicator

struct ProcessingIndicatorView: View {
    private let baseTexts = ["Processing", "Working"]
    private let color = Catppuccin.peach
    private let baseText: String

    @State private var dotCount: Int = 1
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    /// Use a turnId to select text consistently per user turn
    init(turnId: String = "") {
        // Use hash of turnId to pick base text consistently for this turn
        let index = abs(turnId.hashValue) % baseTexts.count
        baseText = baseTexts[index]
    }

    private var dots: String {
        String(repeating: ".", count: dotCount)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ProcessingSpinner()
                .frame(width: 6)

            Text(baseText + dots)
                .chatScaledFont(size: 13)
                .foregroundColor(color)

            Spacer()
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}

// MARK: - Tool Call View

struct ToolCallView: View {
    let tool: ToolCallItem
    let sessionId: String
    /// Id of the wrapping ChatHistoryItem. Used as the key for drill-down
    /// presentation, since ToolCallItem itself has no id.
    let historyItemId: String

    @State private var pulseOpacity: Double = 0.6
    @Environment(\.openToolDetail) private var openToolDetail

    init(tool: ToolCallItem, sessionId: String, historyItemId: String) {
        self.tool = tool
        self.sessionId = sessionId
        self.historyItemId = historyItemId
    }

    private var statusColor: Color {
        switch tool.status {
        case .running:
            return ChatTheme.statusRunning
        case .waitingForApproval:
            return ChatTheme.statusPending
        case .success:
            return ChatTheme.statusSuccess
        case .error, .interrupted:
            return ChatTheme.statusError
        }
    }

    private var textColor: Color {
        switch tool.status {
        case .running:
            return ChatTheme.secondary
        case .waitingForApproval:
            return ChatTheme.statusPending
        case .success:
            return ChatTheme.secondary
        case .error, .interrupted:
            return ChatTheme.statusError
        }
    }

    private var hasResult: Bool {
        tool.result != nil || tool.structuredResult != nil
    }

    /// All completed tools with results can expand to show rich content
    private var canExpand: Bool {
        hasResult && tool.status != .running && tool.status != .waitingForApproval
    }

    /// Result summary text for the ⎿ line (nil when running)
    private var resultSummaryText: String? {
        guard tool.status != .running && tool.status != .waitingForApproval else { return nil }
        return toolResultSummary(for: tool)
    }

    /// Same as `resultSummaryText` but with `+N` segments colored
    /// `statusSuccess` (green) and `-N` segments colored `statusError` (red),
    /// mirroring the inline diff colors. Lets the diff stat on the ⎿ line be
    /// scanned at a glance.
    ///
    /// Only applied when the *entire* trimmed summary matches a diff-stat
    /// shape (`+N`, `-N`, `+N -N`, optionally followed by ` line` / ` lines`).
    /// Otherwise dates like `2026-01-26` would have their `-01` and `-26`
    /// fragments incorrectly painted red.
    private var resultSummaryAttributed: AttributedString? {
        guard let s = resultSummaryText else { return nil }
        var attr = AttributedString(s)
        let baseColor = tool.status == .error ? ChatTheme.statusError : ChatTheme.secondary
        attr.foregroundColor = baseColor
        guard tool.status != .error else { return attr }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let diffStatPattern = #"^[+-]\d+( [+-]\d+)?( lines?)?$"#
        guard trimmed.range(of: diffStatPattern, options: .regularExpression) != nil else {
            return attr
        }
        let regex = try? NSRegularExpression(pattern: #"[+-]\d+"#)
        let ns = s as NSString
        let matches = regex?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? []
        for match in matches {
            let segment = ns.substring(with: match.range)
            if let range = attr.range(of: segment) {
                attr[range].foregroundColor = segment.hasPrefix("+")
                    ? ChatTheme.statusSuccess
                    : ChatTheme.statusError
            }
        }
        return attr
    }

    /// Display name matching Claude Code (Edit→Update/Create, Grep/Glob→Search, Task→Agent)
    private var displayName: String {
        MCPToolFormatter.contextualToolName(tool.name, input: tool.input)
    }

    /// Input summary shown in parens after tool name
    private var inputSummary: String {
        // AgentOutputTool: use agent description from ChatHistoryManager
        if tool.name == "AgentOutputTool" {
            if let agentId = tool.input["agentId"],
               let descs = ChatHistoryManager.shared.agentDescriptions[sessionId],
               let desc = descs[agentId] {
                let blocking = tool.input["block"] == "true"
                return blocking ? "Waiting: \(desc)" : desc
            }
        }
        return toolInputSummary(for: tool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1: ⏺ ToolName (input-summary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // The leading status glyph is informative only while a
                // tool is live (running / awaiting approval = pulsing
                // color) or has failed (error). For the overwhelmingly
                // common completed case it's just a green dot on every
                // row — a noisy uniform column that drowns the bold tool
                // name. Render it transparent there (kept in the layout
                // so the tool name stays aligned with assistant
                // narration above), so completed tool rows read as quiet
                // subordinate steps under the turn that triggered them.
                let glyphVisible = tool.status == .running
                    || tool.status == .waitingForApproval
                    || tool.status == .error
                Text("\u{23FA}")
                    .chatScaledFont(size: 10)
                    .foregroundColor(statusColor.opacity(tool.status == .running || tool.status == .waitingForApproval ? pulseOpacity : 0.7))
                    .opacity(glyphVisible ? 1 : 0)
                    .id(tool.status)
                    .onAppear {
                        if tool.status == .running || tool.status == .waitingForApproval {
                            startPulsing()
                        }
                    }

                Text(displayName)
                    .chatScaledFont(size: 12, weight: .semibold)
                    .foregroundColor(ChatTheme.primary)
                    .fixedSize()

                if tool.name == "Bash" || tool.name == "Shell",
                   let cmd = tool.input["command"], !cmd.isEmpty {
                    // Rich-render the truncated first line. The helper
                    // builds an `AttributedString` from scratch (no
                    // Highlightr, no NSAttributedString conversion) so
                    // the layout shape is identical to the plain Text
                    // path that was here before. Colors via regex pass.
                    //
                    // 10pt mono. Tool-call argument is metadata, not
                    // prose: the user's eye anchors on the bold tool
                    // name ("Bash") and treats the command as
                    // supporting context. We tried 12pt (too dominant),
                    // 7pt (legible only on a 1.0 display when leaning
                    // in), 9pt (still small to glance-read). 10pt is
                    // the legibility floor on Retina at typical viewing
                    // distance. `.chatScaledFont` honors Cmd +/- so
                    // users who scale up the chat globally also scale
                    // these.
                    Text(bashHeaderAttributed(cmd))
                        .chatScaledFont(size: 10, design: .monospaced)
                        .fixedSize(horizontal: false, vertical: true)
                } else if (tool.name == "Edit" || tool.name == "MultiEdit" || tool.name == "Write"),
                          let filePath = tool.input["file_path"], !filePath.isEmpty {
                    // File-mutating tools render their filename as a
                    // clickable link (Codex parity) — clicking opens
                    // the file in the user's default editor.
                    FileLinkButton(filePath: filePath, displayText: inputSummary)
                } else if !inputSummary.isEmpty {
                    // Non-Bash tools (Edit, Grep, …) — same 10pt
                    // density rule as the Bash command above so all
                    // tool headers share one visual weight.
                    Text(inputSummary)
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                // Expand chevron migrates from the (now-suppressed) Line-2
                // result-summary row up to Line 1 for successful tools, so
                // users can still drill in to see full output. The
                // error-state Line 2 below still owns its own chevron.
                if canExpand && tool.status != .error {
                    ToolExpandButton {
                        openToolDetail(historyItemId)
                    }
                }
            }

            // Line 2: ⎿ Result summary, ONLY for errors. Successful tool
            // outputs (bash stdout, read line counts, grep match counts,
            // …) are noise in the common case and the user can always
            // expand to see the full content via the chevron above.
            // Errors are kept inline because a failed bash/build/test
            // surfaces actionable info (compile error, missing file, …)
            // and shouldn't require a click to see.
            if tool.status == .error, let summary = resultSummaryAttributed {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("  \u{23BF}  ")
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary)

                    Text(summary)
                        .chatScaledFont(size: 11)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer()

                    if canExpand {
                        ToolExpandButton {
                            openToolDetail(historyItemId)
                        }
                    }
                }
            }

            // Subagent tools list (for Task/Agent tools)
            if tool.name == "Task" && !tool.subagentTools.isEmpty {
                SubagentToolsList(tools: tool.subagentTools)
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }

            // Edit tools show diff from input both while running AND while
            // waiting for approval. Putting the diff inline in the chat row
            // (vs. inside the approval bar's bounded ScrollView) means the
            // chat's own scroll is the only scroll surface — no nested-scroll
            // fight, and the diff can be any size. Matches Ghostty TUI which
            // prints the full diff in the conversation above the approval
            // prompt. See feedback_chat_parity_with_ghostty.md.
            if tool.name == "Edit"
                && (tool.status == .running || tool.status == .waitingForApproval) {
                EditInputDiffView(input: tool.input)
                    .padding(.leading, 16)
                    .padding(.top, 4)
            }

            // Inline diff preview for completed Edit/MultiEdit. Shows up to
            // 12 diff rows under the result summary so the user can see what
            // changed without drilling in. Drill-down still renders the full
            // untruncated diff via ToolResultContent (no maxRows passed).
            if (tool.name == "Edit" || tool.name == "MultiEdit") &&
               tool.status != .running && tool.status != .waitingForApproval {
                InlineEditPreview(tool: tool, onOverflowTap: {
                    if canExpand { openToolDetail(historyItemId) }
                })
                    .padding(.leading, 16)
                    .padding(.top, 4)
            }

            // No inline content preview for completed Write. The first
            // N lines of a new file are almost always the license/comment
            // header — low signal, and it cost ~10 rows of vertical space
            // to show boilerplate (unlike Edit, whose inline preview is a
            // meaningful diff). The "Wrote N lines to X" header carries the
            // useful at-a-glance info; the full content is one chevron-click
            // away via WriteResultContent. Mirrors how Read renders.

            // BISECT: Read/Bash/Grep/Glob inline previews disabled to test
            // if one of them is the source of the empty-space regression.
            // If the gap disappears with these off, the bug is here.

            // AskUserQuestion inline rendering. Two shapes, gated by
            // tool status:
            //  - pending (.running / .waitingForApproval): full
            //    interactive form (keyboard nav + submit).
            //  - completed (.success with structured result): compact
            //    "→ answer" rows via AskUserQuestionResultContent.
            //  - error / interrupted: nothing inline. The tool header
            //    already shows the status; full detail is one chev-
            //    click away in the drill-down view.
            // Without this gating, answered questions kept rendering the
            // full PendingContent form below the "Answered" header,
            // each question chewing through a screen of vertical space
            // and showing options as un-selected (the form's @State is
            // independent and never sees the answer that landed via
            // JSONL).
            if tool.name == "AskUserQuestion",
               let questions = AskUserQuestionPendingDecoder.decode(tool.input["questions"]) {
                let isPendingStatus = tool.status == .running || tool.status == .waitingForApproval
                if isPendingStatus {
                    let hasCodexTransport = AskUserQuestionSubmissionCoordinator.hasCodexTransport(sessionId: sessionId)
                    let hasClaudeTransport = AskUserQuestionSubmissionCoordinator.hasClaudeCodeTransport(sessionId: sessionId)
                    let canSubmitTransport = hasCodexTransport || hasClaudeTransport
                    AskUserQuestionPendingContent(
                        questions: questions,
                        isPending: true,
                        sessionId: sessionId,
                        canSubmitTransport: canSubmitTransport,
                        transportUnavailableMessage: "Session lost — answer in the terminal or restart the agent.",
                        onSubmitAnswers: { questions, answers in
                            if hasCodexTransport {
                                AskUserQuestionSubmissionCoordinator.submitCodex(
                                    sessionId: sessionId,
                                    questions: questions,
                                    answers: answers
                                )
                            } else {
                                AskUserQuestionSubmissionCoordinator.submitClaudeCode(
                                    sessionId: sessionId,
                                    questions: questions,
                                    answers: answers,
                                    activeToolUseId: historyItemId
                                )
                            }
                        },
                        onCancel: {
                            if hasCodexTransport {
                                AskUserQuestionSubmissionCoordinator.cancelCodex(sessionId: sessionId)
                            } else {
                                AskUserQuestionSubmissionCoordinator.cancelClaudeCode(
                                    sessionId: sessionId,
                                    activeToolUseId: historyItemId
                                )
                            }
                        }
                    )
                    .padding(.leading, 16)
                    .padding(.top, 6)
                } else if tool.status == .success,
                          case .askUserQuestion(let answered) = tool.structuredResult {
                    AskUserQuestionResultContent(
                        result: answered,
                        hideQuestionText: questions.count <= 1
                    )
                    .padding(.leading, 16)
                    .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startPulsing() {
        withAnimation(
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
        ) {
            pulseOpacity = 0.15
        }
    }

    /// Compact-row helper. Renders only the first line of a bash command
    /// (the chat history row is one-line tall). Multi-line full-command
    /// rendering used by the approval bar lives in
    /// `BashHighlighter.attributedString(_:firstLineOnly:)` at file scope.
    private func bashHeaderAttributed(_ command: String) -> AttributedString {
        BashHighlighter.attributedString(command, firstLineOnly: true)
    }

    // MARK: - Input Summary (matches Claude Code's format)

    private func toolInputSummary(for tool: ToolCallItem) -> String {
        switch tool.name {
        case "Bash":
            if let cmd = tool.input["command"] {
                // Collapse multi-line heredocs to first line so a single
                // bash call doesn't dominate the chat. Length-wise we let
                // the full first line through and rely on SwiftUI wrap.
                return cmd.components(separatedBy: .newlines).first ?? cmd
            }
        case "Read":
            if let path = tool.input["file_path"] {
                return (path as NSString).lastPathComponent
            }
        case "Edit":
            if let path = tool.input["file_path"] {
                return (path as NSString).lastPathComponent
            }
        case "Write":
            if let path = tool.input["file_path"] {
                return (path as NSString).lastPathComponent
            }
        case "Grep":
            if let pattern = tool.input["pattern"] {
                return "pattern: \"\(pattern)\""
            }
        case "Glob":
            if let pattern = tool.input["pattern"] {
                return "pattern: \"\(pattern)\""
            }
        case "Task":
            if let desc = tool.input["description"] {
                return desc
            }
        case "Skill":
            guard let skillName = tool.input["skill"], !skillName.isEmpty else { return "" }
            if let args = tool.input["args"], !args.isEmpty {
                let oneLine = args.components(separatedBy: .newlines).first ?? args
                return "\(skillName): \(oneLine)"
            }
            return skillName
        case "SlashCommand":
            if let cmd = tool.input["command"] {
                return cmd
            }
        case "WebFetch":
            if let url = tool.input["url"] {
                return url
            }
        case "WebSearch":
            if let query = tool.input["query"] {
                return "\"\(query)\""
            }
        case "AskUserQuestion":
            // For single-question forms, surface the short `header` tag
            // (e.g. "Driver verdict") rather than the full `question`
            // text. Claude-code's TUI mirrors this with `□ <header>` at
            // the top, then the long question text once inside the
            // form. Matching that structure here means the chat
            // tool-header row and the form body don't duplicate the
            // long question text. Multi-question forms still surface a
            // count since no single header would be representative.
            if let questionsJSON = tool.input["questions"],
               let data = questionsJSON.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                if arr.count > 1 {
                    return "\(arr.count) questions"
                }
                if let first = arr.first {
                    if let header = first["header"] as? String, !header.isEmpty {
                        return header
                    }
                    if let q = first["question"] as? String {
                        return q
                    }
                }
            }
        default:
            if MCPToolFormatter.isMCPTool(tool.name) {
                return MCPToolFormatter.formatArgs(tool.input, maxValueLength: 80, maxArgs: 2)
            }
        }
        return ""
    }

    // MARK: - Result Summary (matches Claude Code's format)

    private func toolResultSummary(for tool: ToolCallItem) -> String? {
        if tool.status == .error {
            if let result = tool.result {
                return result.components(separatedBy: .newlines).first ?? result
            }
            return "Error"
        }

        if tool.status == .interrupted {
            return "Interrupted"
        }

        guard let structured = tool.structuredResult else {
            if let result = tool.result {
                let first = result.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                return first.isEmpty ? "Completed" : first
            }
            return hasResult ? "Completed" : nil
        }

        switch structured {
        case .read(let r):
            let w = r.numLines == 1 ? "line" : "lines"
            return "Read \(r.numLines) \(w)"

        case .edit(let r):
            if let patch = r.structuredPatch {
                let added = patch.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("+") }.count }
                let removed = patch.reduce(0) { $0 + $1.lines.filter { $0.hasPrefix("-") }.count }
                if added > 0 && removed > 0 { return "+\(added) -\(removed) lines" }
                if added > 0 { return "+\(added) lines" }
                if removed > 0 { return "-\(removed) lines" }
            }
            let oldLines = r.oldString.components(separatedBy: "\n").count
            let newLines = r.newString.components(separatedBy: "\n").count
            let diff = newLines - oldLines
            if diff > 0 { return "+\(diff) lines" }
            if diff < 0 { return "\(diff) lines" }
            return "\(newLines) lines changed"

        case .write(let r):
            let lines = r.content.components(separatedBy: "\n").count
            return "Wrote \(lines) lines to \(r.filename)"

        case .bash(let r):
            if let bgId = r.backgroundTaskId { return "Background task \(bgId)" }
            let output = r.stdout.isEmpty ? r.stderr : r.stdout
            if output.isEmpty { return r.returnCodeInterpretation ?? "Completed" }
            return output.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""

        case .grep(let r):
            let fw = r.numFiles == 1 ? "file" : "files"
            if let n = r.numLines, r.mode == .content {
                return "Found \(n) matches across \(r.numFiles) \(fw)"
            }
            return "Found \(r.numFiles) \(fw)"

        case .glob(let r):
            if r.numFiles == 0 { return "No files found" }
            let fw = r.numFiles == 1 ? "file" : "files"
            return "Found \(r.numFiles) \(fw)"

        case .task(let r):
            if let ms = r.totalDurationMs {
                let s = Double(ms) / 1000.0
                return "\(r.status.capitalized) in \(String(format: "%.1f", s))s"
            }
            return r.status.capitalized

        case .webFetch(let r):
            return "\(r.code) \(r.codeText)"

        case .webSearch(let r):
            let t = r.durationSeconds >= 1 ?
                "\(String(format: "%.1f", r.durationSeconds))s" :
                "\(Int(r.durationSeconds * 1000))ms"
            return "Did 1 search in \(t)"

        case .askUserQuestion:
            return "Answered"
        case .todoWrite:
            return "Updated"
        case .bashOutput(let r):
            return "Status: \(r.status)"
        case .killShell(let r):
            return r.message
        case .exitPlanMode:
            return "Plan ready"
        case .mcp:
            return "Completed"
        case .generic:
            return "Completed"
        }
    }
}

// MARK: - Subagent Views

/// List of subagent tools (shown during Task execution)
struct SubagentToolsList: View {
    let tools: [SubagentToolCall]

    /// Number of hidden tools (all except last 2)
    private var hiddenCount: Int {
        max(0, tools.count - 2)
    }

    /// Recent tools to show (last 2, regardless of status)
    private var recentTools: [SubagentToolCall] {
        Array(tools.suffix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Show count of older hidden tools at top
            if hiddenCount > 0 {
                Text("+\(hiddenCount) more tool uses")
                    .chatScaledFont(size: 10)
                    .foregroundColor(ChatTheme.tertiary)
            }

            // Show last 2 tools (most recent activity)
            ForEach(recentTools) { tool in
                SubagentToolRow(tool: tool)
            }
        }
    }
}

/// Single subagent tool row (compact ⏺ format)
struct SubagentToolRow: View {
    let tool: SubagentToolCall

    @State private var dotOpacity: Double = 0.5

    private var statusColor: Color {
        switch tool.status {
        case .running: return ChatTheme.statusRunning
        case .waitingForApproval: return ChatTheme.statusPending
        case .success: return ChatTheme.statusSuccess
        case .error, .interrupted: return ChatTheme.statusError
        }
    }

    private var subagentInputSummary: String {
        switch tool.name {
        case "Bash":
            if let cmd = tool.input["command"] {
                return cmd.components(separatedBy: .newlines).first ?? cmd
            }
        case "Read", "Edit", "Write":
            if let path = tool.input["file_path"] {
                return (path as NSString).lastPathComponent
            }
        case "Grep", "Glob":
            if let pattern = tool.input["pattern"] {
                return pattern
            }
        default:
            break
        }
        return tool.displayText
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\u{23FA}")
                .chatScaledFont(size: 8)
                .foregroundColor(statusColor.opacity(tool.status == .running ? dotOpacity : 0.5))
                .id(tool.status)
                .onAppear {
                    if tool.status == .running {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            dotOpacity = 0.2
                        }
                    }
                }

            Text(MCPToolFormatter.contextualToolName(tool.name, input: tool.input))
                .chatScaledFont(size: 10, weight: .medium)
                .foregroundColor(ChatTheme.secondary)

            Text(subagentInputSummary)
                .chatScaledFont(size: 10)
                .foregroundColor(ChatTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Summary of subagent tools (shown when Task is expanded after completion)
struct SubagentToolsSummary: View {
    let tools: [SubagentToolCall]

    private var toolCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for tool in tools {
            counts[tool.name, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagent used \(tools.count) tools:")
                .chatScaledFont(size: 10, weight: .medium)
                .foregroundColor(ChatTheme.secondary)

            HStack(spacing: 8) {
                ForEach(toolCounts.prefix(5), id: \.0) { name, count in
                    HStack(spacing: 2) {
                        Text(name)
                            .chatScaledFont(size: 10, design: .monospaced)
                            .foregroundColor(ChatTheme.tertiary)
                        Text("×\(count)")
                            .chatScaledFont(size: 9, design: .monospaced)
                            .foregroundColor(ChatTheme.muted)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ChatTheme.cardBg.opacity(0.4))
        )
    }
}

// MARK: - Plan Content (from ExitPlanMode input)

struct PlanContentFromInput: View {
    let input: [String: String]
    @State private var isExpanded = false

    private var planText: String? {
        // Try reading from input directly
        if let plan = input["plan"], !plan.isEmpty { return plan }
        // Try reading from file
        if let path = input["planFilePath"] {
            let expanded = path.hasPrefix("~") ? path.replacingOccurrences(of: "~", with: NSHomeDirectory()) : path
            return try? String(contentsOfFile: expanded, encoding: .utf8)
        }
        return nil
    }

    var body: some View {
        if let plan = planText {
            VStack(alignment: .leading, spacing: 6) {
                if let path = input["planFilePath"] {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .chatScaledFont(size: 10)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .chatScaledFont(size: 11, design: .monospaced)
                    }
                    .foregroundColor(ChatTheme.link)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if isExpanded {
                        MarkdownText(plan, color: ChatTheme.primary, fontSize: 11)
                    } else {
                        MarkdownText(String(plan.prefix(500)), color: ChatTheme.primary, fontSize: 11)
                        if plan.count > 500 {
                            Button("Show full plan...") {
                                withAnimation { isExpanded = true }
                            }
                            .chatScaledFont(size: 10)
                            .foregroundColor(ChatTheme.link)
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ChatTheme.planBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(ChatTheme.planBorder, lineWidth: 1)
                        )
                )
            }
        }
    }
}

// MARK: - Thinking View

struct ThinkingView: View {
    let text: String

    @State private var isExpanded = false

    private var canExpand: Bool {
        text.count > 80
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(ChatTheme.muted)
                .frame(width: 6, height: 6)
                .padding(.top, 4)

            Text(isExpanded ? text : String(text.prefix(80)) + (canExpand ? "..." : ""))
                .chatScaledFont(size: 11)
                .foregroundColor(ChatTheme.tertiary)
                .italic()
                .lineLimit(isExpanded ? nil : 1)
                .multilineTextAlignment(.leading)

            Spacer()

            if canExpand {
                Image(systemName: "chevron.right")
                    .chatScaledFont(size: 9, weight: .medium)
                    .foregroundColor(ChatTheme.muted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

// MARK: - Interrupted Message

struct InterruptedMessageView: View {
    var body: some View {
        HStack {
            Text("Interrupted")
                .chatScaledFont(size: 13)
                .foregroundColor(ChatTheme.statusError)
            Spacer()
        }
    }
}

// MARK: - Turn Duration

struct TurnDurationView: View {
    let seconds: Int
    let children: [ChatHistoryItem]
    let sessionId: String
    @State private var isExpanded = false

    private var formatted: String {
        if seconds >= 60 {
            let m = seconds / 60
            let s = seconds % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        return "\(seconds)s"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if !children.isEmpty {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("✻")
                        .chatScaledFont(size: 11)
                    Text("Worked for \(formatted)")
                        .chatScaledFont(size: 11)
                    if !children.isEmpty {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .disabled(children.isEmpty)

            if isExpanded && !children.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(children) { child in
                        MessageItemView(item: child, sessionId: sessionId)
                    }
                }
            }
        }
        .foregroundColor(ChatTheme.tertiary)
        .padding(.vertical, 2)
    }
}

// MARK: - Recap Message

/// Output of a TUI built-in like `/reload-plugins` or `/rename`. Mirrors
/// claude-code's `⎿ <text>` styling so users see "what claude-code told
/// me" in the same shape they'd see in the terminal.
struct LocalCommandOutputView: View {
    let text: String
    @Environment(\.chatFontScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("⎿")
                .font(.system(size: 11 * scale))
                .foregroundColor(ChatTheme.heading)
            Text(text)
                .font(.system(size: 11 * scale))
                .foregroundColor(ChatTheme.heading.opacity(0.85))
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct RecapMessageView: View {
    let text: String
    // Read scale directly because the recap body uses Text + Text
    // concatenation, which requires the components stay as `Text` and rules
    // out the `.chatScaledFont` modifier (returns `some View`).
    @Environment(\.chatFontScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("※")
                .font(.system(size: 11 * scale))
                .foregroundColor(ChatTheme.heading)
            Text("recap: ")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(ChatTheme.heading)
            + Text(text)
                .font(.system(size: 11 * scale))
                .italic()
                .foregroundColor(ChatTheme.heading.opacity(0.85))
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Compact Boundary

/// Divider rendered for `/compact` events. Click to expand the summary that
/// Claude Code feeds back into the next turn.
struct CompactBoundaryView: View {
    let summary: String?
    let preTokens: Int?
    let trigger: String?

    @State private var isExpanded = false
    @State private var isHovered = false

    private var label: String {
        var parts: [String] = ["Conversation compacted"]
        if let preTokens = preTokens, preTokens > 0 {
            parts.append(formatTokens(preTokens))
        }
        if trigger == "auto" {
            parts.append("auto")
        }
        return parts.joined(separator: " • ")
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return "\(n / 1_000)k tokens"
        }
        return "\(n) tokens"
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                if summary != nil {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(ChatTheme.muted)
                        .frame(height: 1)

                    HStack(spacing: 4) {
                        Text(label)
                            .chatScaledFont(size: 11, weight: .medium)
                            .foregroundColor(ChatTheme.tertiary)
                        if summary != nil {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .chatScaledFont(size: 9, weight: .semibold)
                                .foregroundColor(ChatTheme.tertiary)
                        }
                    }
                    .fixedSize()

                    Rectangle()
                        .fill(ChatTheme.muted)
                        .frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(summary == nil)
            .onHover { isHovered = $0 }

            if isExpanded, let summary = summary {
                MarkdownText(summary, color: ChatTheme.secondary, fontSize: 12)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(ChatTheme.cardBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ChatTheme.cardBorder, lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chat Interactive Prompt Bar

// MARK: - Chat Approval Bar

/// Mutable state held in a class so the NSEvent local monitor's closure can
/// read/write fresh values. View struct captures (which `.onKeyPress` and the
/// SwiftUI body see) get rebuilt on each render, but a long-lived NSEvent
/// closure created once in `.onAppear` would otherwise see only the snapshot
/// at install time.
@MainActor
private final class ApprovalBarState: ObservableObject {
    @Published var focusedIndex: Int = 0
    @Published var expandedIndex: Int? = nil
    @Published var feedbackText: String = ""
}

/// Approval bar for the chat view with animated buttons
struct ChatApprovalBar: View {
    let tool: String
    let toolInput: String?
    let rawInput: [String: AnyCodable]?
    /// Presence-only gate for the third "Yes, and don't ask again…"
    /// option. True when claude-code's TUI would also show the option
    /// for this prompt (the hook sent a `permission_suggestions` field,
    /// regardless of contents). False → option is suppressed even if
    /// the local builder could produce a label, mirroring the TUI's
    /// safety classifier rejecting the command.
    var upstreamSuggestionGateOpen: Bool = false
    /// Session's launch cwd. Used by the Edit / MultiEdit renderer to
    /// turn an absolute file_path into a project-relative path for the
    /// diff header, mirroring claude-code's TUI ("scripts/foo.py" not
    /// "/Users/.../scripts/foo.py").
    var sessionCwd: String = ""
    /// Approve. The optional reason is sent as a follow-up user message
    /// after the hook decision, mirroring Claude Code TUI's "Yes + Tab to
    /// amend" — the tool runs, then the feedback is appended to the
    /// conversation as user context.
    let onApprove: (String?) -> Void
    let onDeny: (String?) -> Void
    /// Approve + send the upstream-supplied `permission_suggestions`
    /// array back as `updatedPermissions`. claude-code persists those
    /// rules into `settings.local.json` AND applies them to the
    /// session's in-memory permission context, so the same tool
    /// invocation won't re-prompt. Default is no-op so call sites
    /// without suggestions compile unchanged.
    var onApproveAndPersist: ([AnyCodable]) -> Void = { _ in }
    /// ExitPlanMode-only: route the user to claude.ai's web Ultraplan
    /// flow. Mirrors claude-code's "No, refine with Ultraplan on Claude
    /// Code on the web" TUI option.
    var onUltraplan: () -> Void = {}
    /// Called with the plan markdown when the user taps the expand
    /// button on the plan box. Parent opens a full-panel reader.
    var onExpandPlan: (String) -> Void = { _ in }

    @StateObject private var state = ApprovalBarState()
    @State private var showContent = false
    @State private var showOptions = false
    @State private var keyMonitor: Any?
    @FocusState private var barFocused: Bool
    @FocusState private var feedbackFocused: Bool

    /// Action a single approval option performs when confirmed. The bar
    /// dispatches to one of the parent callbacks based on this.
    private enum ApprovalAction {
        case allow                                  // Yes
        case allowAndPersist([AnyCodable])          // Yes, and don't ask again…
        case ultraplan                              // Refine with Ultraplan on the web (ExitPlanMode)
        case deny                                   // No / Tell Claude what to change
    }

    /// Permission menu options. Mirrors Claude Code's TUI list. The
    /// third "Yes, and don't ask again…" option is appended when
    /// `PermissionSuggestionBuilder` can derive a sensible scope from
    /// the tool input — same gate as the TUI, which omits the option
    /// when no useful prefix exists. We do the derivation locally
    /// (rather than trusting `permission_suggestions` from the hook
    /// payload) because (a) claude-code routinely omits the field for
    /// Bash invocations even when its TUI shows the option, and (b)
    /// when the field IS present its rules target Read paths instead
    /// of Bash command prefixes.
    private struct ApprovalOption {
        let label: String
        let action: ApprovalAction
        let supportsFeedback: Bool
    }

    // ExitPlanMode-specific menu. Three options that are accurate on
    // every backend — Bedrock, Vertex, standard Anthropic API, and
    // enterprise.
    //
    // Earlier versions had a fourth "Yes, and use auto mode" option as
    // item 1. That option triggered a Shift+Tab keystroke after allow
    // landed, intending to cycle plan→auto. But auto mode is enterprise-
    // gated (TRANSCRIPT_CLASSIFIER feature flag) and absent from every
    // non-enterprise backend, so on Bedrock/Vertex/standard-API the
    // keystroke cycled plan→default instead — landing the user in
    // "manually approve edits" while the menu had labelled it "auto
    // mode." Hook protocol carries no signal we can read to gate the
    // option per-backend, so the safe fix is to drop it.
    //
    // Enterprise users who actually have auto mode can still reach it
    // by pressing Shift+Tab themselves after allowing the plan.
    private static let planApprovalOptions: [ApprovalOption] = [
        ApprovalOption(label: "Yes, manually approve edits", action: .allow, supportsFeedback: false),
        ApprovalOption(label: "No, refine with Ultraplan on Claude Code on the web", action: .ultraplan, supportsFeedback: false),
        ApprovalOption(label: "Tell Claude what to change", action: .deny, supportsFeedback: true),
    ]

    /// Computed list of options for the currently pending tool.
    private var approvalOptions: [ApprovalOption] {
        if tool == "ExitPlanMode" { return Self.planApprovalOptions }

        var options: [ApprovalOption] = [
            ApprovalOption(label: "Yes", action: .allow, supportsFeedback: true)
        ]
        // Two gates must both be open before option 2 appears:
        //   1. upstreamSuggestionGateOpen — claude-code's TUI also
        //      shows the option for this prompt (its safety classifier
        //      didn't reject the input). Diagnosed via field-presence
        //      on `permission_suggestions`; absent means "hide it".
        //   2. local builder yields a suggestion — claude-code's
        //      contents are routinely Read rules even for Bash, so
        //      we use the local PermissionSuggestionBuilder for the
        //      actual label + rule.
        if upstreamSuggestionGateOpen,
           let suggestion = derivedSuggestion(),
           let encoded = encodedUpdates(suggestion.updates) {
            options.append(ApprovalOption(
                label: suggestion.label,
                action: .allowAndPersist(encoded),
                supportsFeedback: false
            ))
        }
        options.append(
            ApprovalOption(label: "No, tell Claude what to do differently", action: .deny, supportsFeedback: true)
        )
        return options
    }

    /// Build the local "always allow" suggestion for the current tool.
    /// Returns nil when the input doesn't yield a safe scope (e.g.
    /// command-substitution-laden Bash, missing file_path) — same
    /// outcome as the TUI omitting the option.
    private func derivedSuggestion() -> PermissionSuggestion? {
        let plainInput = rawInput?.mapValues { $0.value } ?? [:]
        return PermissionSuggestionBuilder.suggestion(
            tool: tool,
            input: plainInput,
            cwd: sessionCwd
        )
    }

    /// Encode `[PermissionUpdate]` into the `[AnyCodable]` shape the
    /// hook response wire format wants. Each update round-trips through
    /// JSON so its keys match upstream's PermissionUpdate schema
    /// (toolName/ruleContent etc) — `AnyCodable` then re-encodes the
    /// dict on the way back out. Returns nil only on a JSON failure
    /// (impossible in practice given the Codable shape, but guarded
    /// to keep the call site total).
    private func encodedUpdates(_ updates: [PermissionUpdate]) -> [AnyCodable]? {
        var out: [AnyCodable] = []
        for update in updates {
            guard let data = try? JSONEncoder().encode(update),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            out.append(AnyCodable(dict))
        }
        return out
    }

    /// Per-tool detailed renderer. Shows the full content the user would see
    /// in Ghostty's TUI for this tool — no truncation. Wrapper outside is a
    /// ScrollView so long commands / file diffs / Plan content stay visible
    /// without expanding the bar past the chat panel.
    ///
    /// Two things upgraded vs the original plain-text version:
    ///   1. `.chatScaledFont(...)` everywhere so Cmd +/- scales the bar
    ///      content together with the chat history.
    ///   2. Bash commands run through `BashHighlighter.attributedString`
    ///      for syntax-coloring — same hues as the chat row's compact
    ///      bash header.
    /// Edit keeps the simple inline `-`/`+` diff shape (the user picked
    /// option A — a Myers-diff hunk view was the other option and was
    /// passed on for now).
    @ViewBuilder
    private func toolDetailView() -> some View {
        switch tool {
        case "Bash", "BashOutput":
            if let cmd = rawInput?["command"]?.value as? String {
                Text(BashHighlighter.attributedString(cmd))
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "Edit", "MultiEdit":
            // TUI-parity diff. Read the file as it exists right now
            // (claude-code hasn't applied the edit yet) to derive line
            // numbers and surrounding context, then reuse the existing
            // chat-history `DiffView` so the approval body looks the
            // same as the post-execution diff in chat. Falls back to a
            // simple prefixed-line view when the file can't be read or
            // old_string isn't found (e.g. the assistant generated a
            // bad edit), so the user can still see the proposed change.
            if let filePath = rawInput?["file_path"]?.value as? String,
               let oldString = rawInput?["old_string"]?.value as? String,
               let newString = rawInput?["new_string"]?.value as? String,
               let hunk = Self.buildEditPatchHunk(
                filePath: filePath, oldString: oldString, newString: newString
               ) {
                DiffView(
                    patches: [hunk],
                    filename: Self.relativeFilename(filePath: filePath, cwd: sessionCwd),
                    filePath: filePath
                )
            } else if let path = rawInput?["file_path"]?.value as? String {
                // Fallback when the file can't be read or old_string
                // isn't located in the current file content.
                Text(path)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
                if let old = rawInput?["old_string"]?.value as? String {
                    Text("- " + old)
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let new = rawInput?["new_string"]?.value as? String {
                    Text("+ " + new)
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.statusSuccess)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case "Write":
            if let path = rawInput?["file_path"]?.value as? String {
                Text(path)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }
            if let content = rawInput?["content"]?.value as? String {
                Text(content)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "Read":
            if let path = rawInput?["file_path"]?.value as? String {
                Text(path)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
            }
            if let offset = rawInput?["offset"]?.value {
                Text("offset: \(String(describing: offset))")
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.tertiary)
            }
            if let limit = rawInput?["limit"]?.value {
                Text("limit: \(String(describing: limit))")
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.tertiary)
            }
        case "Grep":
            if let pattern = rawInput?["pattern"]?.value as? String {
                Text("pattern: \(pattern)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
            }
            if let path = rawInput?["path"]?.value as? String {
                Text("path: \(path)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }
            if let glob = rawInput?["glob"]?.value as? String {
                Text("glob: \(glob)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }
        case "Glob":
            if let pattern = rawInput?["pattern"]?.value as? String {
                Text("pattern: \(pattern)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
            }
            if let path = rawInput?["path"]?.value as? String {
                Text("path: \(path)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }
        case "WebFetch":
            if let url = rawInput?["url"]?.value as? String {
                Text(url)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
            }
            if let prompt = rawInput?["prompt"]?.value as? String {
                Text(prompt)
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        default:
            // Generic fallback: render every field of the raw input. Uses
            // formattedInput which (post-fix) returns full strings.
            if let formatted = toolInput {
                Text(formatted)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Description field if available
    private var toolDescription: String? {
        rawInput?["description"]?.value as? String
    }

    /// Synthesize a unified-diff `PatchHunk` for an Edit / MultiEdit
    /// approval. The on-disk file still has the OLD content (the edit
    /// hasn't applied yet), so we read it, locate `oldString`, and
    /// build a patch that includes 3 context lines on each side. Falls
    /// out as nil when the file can't be read or `oldString` isn't
    /// present (the assistant produced a stale edit) — the caller
    /// then renders a simpler old/new fallback view so the user can
    /// still see the proposed change before deciding.
    static func buildEditPatchHunk(
        filePath: String,
        oldString: String,
        newString: String,
        contextRadius: Int = 3
    ) -> PatchHunk? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return nil
        }
        guard let matchRange = content.range(of: oldString) else { return nil }

        // 0-indexed line of where oldString starts in the file.
        let beforeMatch = content[..<matchRange.lowerBound]
        // `components(separatedBy:)` returns 1 element when there are
        // no newlines, so the count is "lines before + 1" → subtract 1
        // to get the 0-indexed line number of oldString's first line.
        let startLine0 = beforeMatch.components(separatedBy: "\n").count - 1

        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let allLines = content.components(separatedBy: "\n")

        // 0-indexed line range that oldString occupies.
        let oldEndLine0 = startLine0 + oldLines.count - 1

        let ctxBeforeStart = max(0, startLine0 - contextRadius)
        let ctxAfterEnd = min(allLines.count, oldEndLine0 + 1 + contextRadius)

        var diffLines: [String] = []
        for i in ctxBeforeStart..<startLine0 {
            diffLines.append(" " + allLines[i])
        }
        for line in oldLines {
            diffLines.append("-" + line)
        }
        for line in newLines {
            diffLines.append("+" + line)
        }
        if oldEndLine0 + 1 < ctxAfterEnd {
            for i in (oldEndLine0 + 1)..<ctxAfterEnd {
                diffLines.append(" " + allLines[i])
            }
        }

        let ctxBeforeCount = startLine0 - ctxBeforeStart
        let ctxAfterCount = max(0, ctxAfterEnd - (oldEndLine0 + 1))
        return PatchHunk(
            oldStart: ctxBeforeStart + 1,  // PatchHunk uses 1-indexed lines
            oldLines: ctxBeforeCount + oldLines.count + ctxAfterCount,
            newStart: ctxBeforeStart + 1,  // No offset until the change applies
            newLines: ctxBeforeCount + newLines.count + ctxAfterCount,
            lines: diffLines
        )
    }

    /// Filename relative to the session's launch cwd. Matches the path
    /// claude-code's TUI shows in the Edit header ("scripts/foo.py"
    /// rather than "/Users/.../scripts/foo.py"). Falls back to the
    /// basename if the path doesn't share the cwd prefix, and to the
    /// raw filePath when even that fails.
    private static func relativeFilename(filePath: String, cwd: String) -> String {
        guard !cwd.isEmpty else {
            return (filePath as NSString).lastPathComponent
        }
        if filePath.hasPrefix(cwd) {
            let tail = String(filePath.dropFirst(cwd.count))
            return tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        }
        return (filePath as NSString).lastPathComponent
    }

    /// Debug: show tool name for troubleshooting
    private var debugToolInfo: String {
        "tool=\(tool), hasRawInput=\(rawInput != nil), keys=\(rawInput?.keys.joined(separator: ",") ?? "none")"
    }

    /// For ExitPlanMode: read the plan file content
    private var planContent: String? {
        // Match any tool name that contains "plan" (case insensitive)
        guard tool.lowercased().contains("plan") || tool == "ExitPlanMode" else { return nil }

        // Try multiple sources for the plan file path
        var filePath: String?

        // From rawInput (permission context)
        if let input = rawInput {
            if let p = input["planFilePath"]?.value as? String { filePath = p }
            else if let p = input["file_path"]?.value as? String { filePath = p }
        }

        // From toolInput string (parse "planFilePath: /path/to/file")
        if filePath == nil, let inputStr = toolInput {
            for line in inputStr.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("planFilePath: ") {
                    filePath = String(trimmed.dropFirst("planFilePath: ".count))
                } else if trimmed.hasPrefix("file_path: ") {
                    filePath = String(trimmed.dropFirst("file_path: ".count))
                }
            }
        }

        // Fallback: find the most recent plan file
        if filePath == nil {
            let plansDir = NSHomeDirectory() + "/.claude/plans"
            if let files = try? FileManager.default.contentsOfDirectory(atPath: plansDir) {
                let planFiles = files.filter { $0.hasSuffix(".md") }
                    .sorted { a, b in
                        let aDate = (try? FileManager.default.attributesOfItem(atPath: plansDir + "/" + a))?[.modificationDate] as? Date ?? .distantPast
                        let bDate = (try? FileManager.default.attributesOfItem(atPath: plansDir + "/" + b))?[.modificationDate] as? Date ?? .distantPast
                        return aDate > bDate
                    }
                if let recent = planFiles.first {
                    filePath = plansDir + "/" + recent
                }
            }
        }

        guard let path = filePath else { return nil }
        let expanded = path.hasPrefix("~") ? path.replacingOccurrences(of: "~", with: NSHomeDirectory()) : path
        return try? String(contentsOfFile: expanded, encoding: .utf8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool name (header)
            Text(MCPToolFormatter.formatToolName(tool))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(ChatTheme.statusPending)
                .opacity(showContent ? 1 : 0)
                .offset(x: showContent ? 0 : -10)

            // Tool input detail — always scrollable so long commands, full
            // diffs, multi-line content etc. are visible in their entirety
            // (matches what Ghostty's TUI shows). Uses textSelection so users
            // can copy. Falls back to formattedInput when no specific renderer
            // matches — formattedInput now renders full strings, no silent
            // truncation.
            //
            // Skipped for ExitPlanMode: its raw input is just the markdown
            // plan (already rendered below) plus an `allowedPrompts` list
            // that isn't actionable in this approval UI.
            //
            // Skipped for Edit: the chat row above renders the diff inline
            // (see ChatToolRowView render path). Keeping it here too created
            // a nested-scroll trap — the bar's 200pt ScrollView clipped the
            // diff while the chat scroll above was the natural surface for
            // arbitrarily long content.
            if tool != "ExitPlanMode" && tool != "Edit" {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        toolDetailView()
                        if let desc = toolDescription {
                            Text(desc)
                                .font(.system(size: 11))
                                .foregroundColor(ChatTheme.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                // Shrink the detail viewport when the feedback field is shown so
                // the inline TextField has room to render — NotchView clips
                // overflow, so without yielding space here the field would be
                // pushed below the visible panel bottom.
                .frame(maxHeight: state.expandedIndex != nil ? 90 : 200)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ChatTheme.cardBg.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(ChatTheme.inputBorder.opacity(0.5), lineWidth: 1)
                        )
                )
                .opacity(showContent ? 1 : 0)
                .offset(x: showContent ? 0 : -10)
            }

            // Plan content (for ExitPlanMode approval). Renders inline
            // with a 250pt cap + internal scroll so the approval bar
            // stays compact and the Yes/No options remain visible. The
            // top-right expand button opens a full-panel drill-down
            // reader (PlanDetailView) for examining the plan without
            // fighting the approval bar for vertical space. Matches
            // the parity rule (feedback_chat_parity_with_ghostty.md)
            // by giving the user the full content, just in a roomier
            // viewport when they want it.
            if let plan = planContent {
                ZStack(alignment: .topTrailing) {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            MarkdownText(plan, color: ChatTheme.primary, fontSize: 13)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 250)

                    Button {
                        onExpandPlan(plan)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(ChatTheme.secondary)
                            .padding(6)
                            .background(
                                Circle().fill(ChatTheme.planBg)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Open plan in full reader")
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ChatTheme.planBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(ChatTheme.planBorder, lineWidth: 1)
                        )
                )
                .opacity(showContent ? 1 : 0)
            }

            // Option list (mirrors Claude Code's TUI permission menu)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(approvalOptions.enumerated()), id: \.offset) { idx, option in
                    optionRow(index: idx, option: option)
                }
            }
            .opacity(showOptions ? 1 : 0)
            .offset(x: showOptions ? 0 : -8)

            // Keyboard hint
            HStack(spacing: 12) {
                Text("↵ confirm")
                Text("↑↓ navigate")
                Text("⇥ amend")
                Text("⌃C deny")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(ChatTheme.tertiary)
            .opacity(showOptions ? 0.7 : 0)
        }
        .frame(minHeight: 44)  // Consistent height with other bars
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ChatTheme.headerBg)
        .focusable(true)
        .focusEffectDisabled()
        .focused($barFocused)
        .onKeyPress(.upArrow) {
            guard state.expandedIndex == nil else { return .ignored }
            state.focusedIndex = max(0, state.focusedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard state.expandedIndex == nil else { return .ignored }
            state.focusedIndex = min(approvalOptions.count - 1, state.focusedIndex + 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard state.expandedIndex == nil else { return .ignored }
            confirmFocused()
            return .handled
        }
        .onKeyPress(.delete) {
            // Bar-level backspace: quick-deny without a reason. Skipped when
            // a feedback field is expanded — the field handles its own keys.
            guard state.expandedIndex == nil else { return .ignored }
            onDeny(nil)
            return .handled
        }
        .onChange(of: state.expandedIndex) { _, newValue in
            // Feedback expand/collapse drives @FocusState. We bridge here
            // (rather than inside the NSEvent monitor) so the monitor only
            // mutates plain state and SwiftUI handles focus on the next
            // render pass — avoids "set focus before the field exists" races.
            if newValue != nil {
                feedbackFocused = true
            } else {
                feedbackFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    barFocused = true
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                showContent = true
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7).delay(0.12)) {
                showOptions = true
            }
            // Focus the bar so ↑↓ / ↵ / ⌫ work without a click.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                barFocused = true
            }
            installTabMonitor()
        }
        .onDisappear {
            removeTabMonitor()
        }
    }

    // MARK: - Tab interception

    /// Tab on a focusable SwiftUI container is eaten by AppKit's focus-
    /// traversal engine before `.onKeyPress(.tab)` ever fires. We install a
    /// local NSEvent monitor that runs *before* the responder chain, so we
    /// can swallow Tab and toggle the feedback expansion. State is kept in a
    /// class (`ApprovalBarState`) because this closure is created once in
    /// `.onAppear` and would otherwise see only the initial value snapshot.
    private func installTabMonitor() {
        guard keyMonitor == nil else { return }
        let stateRef = state
        let options = approvalOptions
        let denyHandler = onDeny
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Originally gated on NotchPanel; with the panel retired,
            // the approval bar lives in the main window. Local monitors
            // are already scoped to the app, and the bar only mounts
            // when a permission approval is live, so accepting any
            // window is correct.
            guard event.window != nil else { return event }

            // Ctrl+C — deny the approval with no reason. Mirrors the
            // AskUserQuestion form's Ctrl+C-cancels behavior so the
            // muscle memory is the same across both approval surfaces.
            // Goes through `onDeny`, which routes to
            // `ClaudeSessionMonitor.denyPermission` → socket "deny"
            // (or TUI Esc fallback for replayed sidecars) +
            // `.permissionDenied` dispatch.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods == .control, event.charactersIgnoringModifiers == "c" {
                denyHandler(nil)
                return nil
            }

            // Tab keyCode is 0x30. Ignore Shift+Tab (used by the input bar
            // for permission-mode cycling — we only swap the chat input for
            // the approval bar, but other panes may rely on it).
            guard event.keyCode == 0x30,
                  !event.modifierFlags.contains(.shift) else {
                return event
            }

            if stateRef.expandedIndex != nil {
                // Collapse — works even when the feedback TextField is the
                // first responder, because the local monitor runs first.
                stateRef.expandedIndex = nil
                stateRef.feedbackText = ""
                return nil
            }

            let option = options[stateRef.focusedIndex]
            guard option.supportsFeedback else { return nil }
            stateRef.expandedIndex = stateRef.focusedIndex
            return nil
        }
    }

    private func removeTabMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    // MARK: - Option row + helpers

    @ViewBuilder
    private func optionRow(index: Int, option: ApprovalOption) -> some View {
        let isFocused = state.focusedIndex == index
        let isExpanded = state.expandedIndex == index
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Focus indicator: filled chevron for the active row.
                Text(isFocused ? "❯" : " ")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(isFocused ? ChatTheme.statusSuccess : ChatTheme.tertiary)
                    .frame(width: 12, alignment: .leading)

                Text(option.label)
                    .font(.system(size: 12, weight: isFocused ? .semibold : .regular))
                    .foregroundColor(isFocused ? ChatTheme.primary : ChatTheme.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                state.focusedIndex = index
                state.expandedIndex = nil
                state.feedbackText = ""
                confirmFocused()
            }

            if isExpanded {
                // Manual placeholder rendered as a Text overlay rather than
                // via TextField's `prompt:` parameter. On macOS, `prompt:`
                // bridges to NSTextField.placeholderAttributedString, but
                // .textFieldStyle(.plain) frequently overrides with
                // NSColor.placeholderTextColor regardless of the foreground
                // color attached to the inner Text — that's why three rounds
                // of color tweaks via `prompt:` had no visible effect. An
                // overlay bypasses NSTextField's placeholder machinery
                // entirely so the color we pick is the color that ships.
                ZStack(alignment: .leading) {
                    if state.feedbackText.isEmpty {
                        Text(placeholder(for: option))
                            .font(.system(size: 12))
                            .foregroundColor(ChatTheme.primary.opacity(0.65))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $state.feedbackText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(ChatTheme.inputBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(ChatTheme.inputBorder, lineWidth: 1)
                        )
                )
                .focused($feedbackFocused)
                .onSubmit {
                    confirmFocused()
                }
                .onKeyPress(.delete) {
                    // Empty field + backspace: collapse so the user can quick-
                    // deny via the bar-level shortcut. Otherwise let the key
                    // delete a character normally.
                    guard state.feedbackText.isEmpty else { return .ignored }
                    collapseFeedback()
                    return .handled
                }
                .padding(.leading, 20)
            }
        }
    }

    private func confirmFocused() {
        let option = approvalOptions[state.focusedIndex]
        let trimmed = state.feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = trimmed.isEmpty ? nil : trimmed
        switch option.action {
        case .allow:                          onApprove(reason)
        case .allowAndPersist(let updates):   onApproveAndPersist(updates)
        case .ultraplan:                      onUltraplan()
        case .deny:                           onDeny(reason)
        }
    }

    /// Placeholder text shown inside the feedback input when an option's
    /// Tab-expansion is open. ExitPlanMode's "Tell Claude what to change"
    /// uses claude-code's exact phrasing.
    private func placeholder(for option: ApprovalOption) -> String {
        switch option.action {
        case .deny where tool == "ExitPlanMode":
            return "Tell Claude what to change…"
        case .allow:
            return "Tell Claude what to do next…"
        default:
            return "Tell Claude what to do differently…"
        }
    }

    private func collapseFeedback() {
        state.expandedIndex = nil
        state.feedbackText = ""
    }
}

// MARK: - Attachment Chip

/// Thumbnail card shown in the attachment strip above the input bar.
struct AttachmentChip: View {
    let attachment: ImageAttachment
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: attachment.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ChatTheme.inputBorder, lineWidth: 1)
                )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(ChatTheme.primary)
                    .background(Circle().fill(Catppuccin.mantle.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .opacity(isHovering ? 1 : 0.7)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

// MARK: - Input Focus Controller

/// Bridge for asking an NSViewRepresentable-wrapped text view to take
/// first-responder status. SwiftUI's `@FocusState` and `.focused()`
/// modifier don't drive the underlying NSTextView in NSViewRepresentable;
/// setting `isInputFocused = true` was a no-op, which is why entering
/// chat via the keyboard left the input unfocused while clicking the
/// input worked (the click directly granted first responder via AppKit).
final class InputFocusController: ObservableObject {
    fileprivate weak var textView: NSTextView?

    /// Make the held text view the first responder of its window.
    /// Hops to the main queue so it runs after the in-flight SwiftUI
    /// layout pass that mounted the view; calling synchronously during
    /// onAppear can race with view installation.
    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView,
                  let window = textView.window else { return }
            _ = window.makeFirstResponder(textView)
        }
    }

    /// Replace the text view's contents wholesale and optionally drop
    /// the caret at the end. Used by the slash-command popover when the
    /// user accepts a suggestion: SwiftUI's `@Binding<String>` update
    /// alone leaves the caret at its prior offset, which feels wrong
    /// after a `/foo ` insertion.
    func replaceText(_ replacement: String, caretAtEnd: Bool) {
        guard let textView = textView else { return }
        textView.string = replacement
        if caretAtEnd {
            let end = (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    /// Visual line count from the NSTextView's layout manager. Counts
    /// soft-wrapped lines (long string with no newline that wraps to
    /// the next visual row) AND hard-wrapped ones — i.e. the number
    /// of rows the user actually sees. Counting `\n`s in the SwiftUI
    /// `@Binding<String>` misses soft wraps and the composer height
    /// stays at one line while the second visual line gets clipped.
    /// Returns 1 for empty content.
    func visualLineCount() -> Int {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return 1 }
        if layoutManager.numberOfGlyphs == 0 { return 1 }
        // Canonical implementation: ask the layout manager for the
        // total rendered height of the laid-out text and divide by
        // the typesetter's line-height. Two earlier strategies were
        // both wrong for a Shift+Enter sequence:
        //   1. Counting `\n` characters in the bound string missed
        //      soft wraps.
        //   2. Enumerating `lineFragmentRect` per glyph double-
        //      counted: each `\n` glyph occasionally produced its
        //      own fragment, so 6 words + 6 newlines → 12 fragments,
        //      capped at 8 → 2 lines of phantom gap below the caret.
        // `usedRect(for:)` is what NSLayoutManager itself uses to
        // size the text container — the same height NSTextView would
        // report as its content. We force layout first so streaming
        // updates can't return a stale rect.
        layoutManager.ensureLayout(for: container)
        // CRITICAL: do NOT add `extraLineFragmentRect.height`.
        // Empirical truth (verified by ComposerHeightCalculatorTests
        // and the prior comment block on `visualTextHeight` below):
        // `usedRect.height` ALREADY includes the trailing-newline
        // caret line. `extraLineFragmentRect` exposes the SAME
        // geometry for cursor positioning, not additional height.
        // Adding it doubles the trailing-newline line and produces
        // the user-reported "phantom extra vertical space after
        // Shift+Enter that disappears once any character is typed".
        let height = layoutManager.usedRect(for: container).height
        // Compute line count from height. The font's default
        // typesetter line height is what the layout manager uses, so
        // ask the font directly. Fall back to 22pt if the font
        // somehow can't be resolved.
        let lineHeight: CGFloat
        if let font = textView.font {
            lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
        } else {
            lineHeight = 22
        }
        guard lineHeight > 0 else { return 1 }
        return max(1, Int((height / lineHeight).rounded()))
    }

    /// Live line height from the NSTextView's typesetter, in points.
    /// Reflects whatever font the text view is currently using —
    /// already includes the user's `chatFontScale` because the
    /// composer scales its font by that value when it builds the
    /// view. Callers should NOT multiply this by scale again.
    /// Returns 22pt as a safe fallback when the text view hasn't
    /// been laid out yet (matches the previous fictional baseline,
    /// so the empty-composer height stays stable across the upgrade).
    func visualLineHeight() -> CGFloat {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let font = textView.font
        else { return 22 }
        let h = ceil(layoutManager.defaultLineHeight(for: font))
        return h > 0 ? h : 22
    }

    /// Total rendered text height, in points. Reads `usedRect.height`
    /// directly off the layout manager — no addition of
    /// `extraLineFragmentRect.height`, despite what the docs and a
    /// long history of Stack Overflow answers might suggest.
    ///
    /// Empirical truth (verified by `ComposerHeightCalculatorTests`):
    /// `usedRect.height` ALREADY includes the trailing-newline caret
    /// line. The separate `extraLineFragmentRect` is the same
    /// geometry exposed for cursor positioning, NOT additional
    /// height. Adding it produced a one-line phantom gap that
    /// appeared after every Shift+Enter and vanished when the user
    /// typed any character (no trailing newline = empty extra rect
    /// = no double-count).
    ///
    /// We floor at one line height so an empty input still has
    /// visible height (the layout manager reports
    /// `usedRect.height ≈ lineHeight - 2` for empty content).
    func visualTextHeight() -> CGFloat {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let font = textView.font
        else { return 0 }
        layoutManager.ensureLayout(for: container)
        let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
        let used = ceil(layoutManager.usedRect(for: container).height)
        return max(lineHeight, used)
    }
}

// MARK: - Multi-Line Input

/// NSTextView-backed multi-line input with Enter to submit, Shift+Enter for new line.
struct MultiLineInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var onSubmit: () -> Void
    var onImagePasted: ((NSImage) -> Void)? = nil
    var onCycleMode: (() -> Void)? = nil
    var onCancelQuery: (() -> Void)? = nil
    /// Fires after every user-driven text change. Use this for live
    /// derivations like the slash-command popover that need each
    /// keystroke, not just submit.
    var onTextChanged: ((String) -> Void)? = nil
    /// Optional popover controller; when set and `isOpen` is true, the
    /// text view intercepts ↑/↓/Tab/Esc and routes them to the popover.
    /// When nil or closed, the text view behaves as before.
    var slashController: SlashCommandPopoverController? = nil
    var focusController: InputFocusController? = nil
    /// Multiplied into the base font size so Cmd +/- in the chat panel
    /// scales the input together with the chat history. Source of truth is
    /// `AppSettings.chatFontScale`, propagated via Environment.
    var scale: CGFloat = 1.0

    /// Base font size for the input. Same 13pt the chat body uses, kept
    /// in one place so resizing math is straightforward.
    static let baseFontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Top/bottom inset between the NSTextView's text container and
    /// its frame. The composer's outer SwiftUI frame must include
    /// 2 × this value or the bottom line gets clipped.
    static let textContainerInsetY: CGFloat = 2

    func makeNSView(context: Context) -> NSScrollView {
        // Wrapping NSScrollView. We KEEP the scroll view because
        // NSTextView's auto-grow behavior (`isVerticallyResizable =
        // true`) requires an enclosing clip view to grow into. Without
        // it, Shift+Enter has nowhere to put the new line.
        //
        // The drift bug was NOT caused by the scroll view's existence
        // — it was caused by the OUTER SwiftUI frame being smaller
        // than NSTextView's intrinsic content size. NSTextView's
        // intrinsic height = usedRect + 2 × textContainerInset.height.
        // When SwiftUI sized the outer frame to just `usedRect`, the
        // inner NSTextView was 4pt taller than the visible scroll-view
        // bounds, and AppKit's `scrollRangeToVisible:` shifted the
        // clip view to keep the caret visible — the visible drift.
        //
        // Fix: ComposerOuterFrameHeight (Core) computes the outer
        // SwiftUI frame as text height + 2 × inset, so the visible
        // scroll-view bounds exactly match the NSTextView's intrinsic
        // size. Nothing to scroll → no drift.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = SubmittableTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onImagePasted = onImagePasted
        textView.onCycleMode = onCycleMode
        textView.onCancelQuery = onCancelQuery
        textView.slashController = slashController
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: Self.baseFontSize * scale)
        textView.textColor = NSColor(Catppuccin.text)
        textView.insertionPointColor = NSColor(Catppuccin.lavender)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Catppuccin.surface2.opacity(0.7))
        ]
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.textContainerInset = NSSize(
            width: 0, height: Self.textContainerInsetY
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping

        scrollView.documentView = textView
        context.coordinator.textView = textView
        focusController?.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmittableTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.onSubmit = onSubmit
        textView.onImagePasted = onImagePasted
        textView.onCycleMode = onCycleMode
        textView.onCancelQuery = onCancelQuery
        textView.slashController = slashController
        focusController?.textView = textView

        // Re-apply theme-driven attributes. These are originally set in
        // makeNSView, but the user can flip Light/Dark at runtime —
        // without reapplying here, the cached NSColor values keep
        // showing Mocha tokens after the user has switched to Latte
        // (the screenshot the user reported).
        textView.textColor = NSColor(Catppuccin.text)
        textView.insertionPointColor = NSColor(Catppuccin.lavender)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Catppuccin.surface2.opacity(0.7))
        ]

        // Re-apply the scaled font when Cmd +/- bumps the chat font
        // scale. NSTextView keeps the previous font otherwise, so the
        // body would stay at the size from the first render even as
        // `chatFontScale` changes underneath.
        let targetSize = Self.baseFontSize * scale
        if (textView.font?.pointSize ?? 0) != targetSize {
            textView.font = NSFont.systemFont(ofSize: targetSize)
        }

        if text.isEmpty && !textView.isFirstResponder {
            textView.string = ""
        }
        context.coordinator.parent = self
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineInput
        weak var textView: NSTextView?

        init(_ parent: MultiLineInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChanged?(textView.string)
        }
    }
}

/// NSScrollView subclass that exposes a real `intrinsicContentSize`
/// based on the contained NSTextView's laid-out text. Plain NSScrollView
/// returns `noIntrinsicMetric`, which is fine when an Auto Layout parent
/// pins the scroll view's height — but SwiftUI's
/// `.frame(minHeight:maxHeight:)` modifier queries the intrinsic height
/// to decide where in the [min, max] range to land. With no intrinsic
/// height SwiftUI snaps to `maxHeight`, so the empty composer was
/// rendered at the full 60pt cap and produced a giant gap above the
/// status bar.
///
/// We fold the text container's used rect into a height and clamp it
/// from below at the line height so a freshly cleared composer doesn't
/// collapse to zero (it would still hit `minHeight` from the SwiftUI
/// frame, but reporting a sensible floor avoids a brief layout flash
/// on first paint).
class ResizingScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        guard let textView = documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return super.intrinsicContentSize
        }
        // Force layout so usedRect reflects current text. Cheap — the
        // NSTextView is already laid out; ensureLayout is a no-op when
        // the layout is current.
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let line = textView.font?.boundingRectForFont.height ?? 16
        let inset = textView.textContainerInset.height * 2
        let height = max(line, used.height) + inset
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

/// NSTextView subclass that submits on Enter and inserts newline on Shift+Enter.
class SubmittableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onImagePasted: ((NSImage) -> Void)?
    var onCycleMode: (() -> Void)?
    /// Ctrl+C handler. Set to non-nil only while the bound session is
    /// actively processing — when nil, Ctrl+C falls through to default
    /// NSTextView behavior so we don't swallow the keystroke for users
    /// with a different muscle memory.
    var onCancelQuery: (() -> Void)?
    /// When non-nil and `isOpen`, ↑/↓/Tab/Esc are routed to the popover
    /// instead of NSTextView's default behavior. ESC closes the popover
    /// rather than exiting the chat view; the chat-exit ESC handler
    /// fires only when the popover is closed.
    weak var slashController: SlashCommandPopoverController?

    /// Intercept Cmd+V when the clipboard holds an image so the image becomes
    /// an attachment (sent as a bracketed-paste file path) instead of text.
    /// Non-image clipboards fall through to the default paste behavior.
    ///
    /// We intercept at `paste(_:)` rather than `readSelection(from:type:)` because
    /// a plain-text NSTextView (`isRichText = false`) declares only text types in
    /// `readablePasteboardTypes`, so an image-only clipboard never triggers the
    /// type-matching path at all.
    override func paste(_ sender: Any?) {
        if let handler = onImagePasted, let image = imageFromPasteboard(.general) {
            handler(image)
            return
        }
        super.paste(sender)
    }

    /// The notch panel is a .nonactivatingPanel with no app menu bar, so
    /// Cmd+V has no Edit > Paste menu item to dispatch through and the
    /// normal NSTextView clipboard shortcuts never fire. Intercept the
    /// standard editing shortcuts here and route them to the corresponding
    /// actions directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let isShift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers {
        case "v": paste(nil); return true
        case "c": copy(nil); return true
        case "x": cut(nil); return true
        case "a": selectAll(nil); return true
        case "z":
            if isShift {
                if let um = undoManager, um.canRedo { um.redo(); return true }
            } else {
                if let um = undoManager, um.canUndo { um.undo(); return true }
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func imageFromPasteboard(_ pasteboard: NSPasteboard) -> NSImage? {
        // Fast path: direct image types.
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        for t in imageTypes {
            if pasteboard.availableType(from: [t]) != nil,
               let data = pasteboard.data(forType: t),
               let image = NSImage(data: data) {
                return image
            }
        }
        // File URL path: if the clipboard has a single image file reference,
        // load it as an image. Covers Finder "Copy" of an image file.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count == 1, let url = urls.first,
           ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic"]
            .contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        // When the slash-command popover is open, ↑/↓/Tab/Esc belong to
        // it. Plain Enter still falls through to submit. Shift+Tab is
        // the existing permission-mode shortcut and stays wired below.
        if let popover = slashController, popover.isOpen {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch event.keyCode {
            case 126:  // up arrow
                popover.selectPrevious(); return
            case 125:  // down arrow
                popover.selectNext(); return
            case 48 where !mods.contains(.shift):  // Tab (not Shift+Tab)
                if let replacement = popover.acceptSelection() {
                    self.string = replacement
                    let end = (replacement as NSString).length
                    self.setSelectedRange(NSRange(location: end, length: 0))
                    delegate?.textDidChange?(Notification(
                        name: NSText.didChangeNotification,
                        object: self
                    ))
                }
                return
            case 53:  // ESC closes the popover; chat-exit ESC is suppressed
                popover.close(); return
            default:
                break
            }
        }

        // Ctrl+C: cancel the in-flight Claude query. Only intercepts
        // when `onCancelQuery` is wired (gated by ChatView on the
        // session's processing state) and only for pure Ctrl+C — no
        // shift / cmd / option — so accidental chords pass through.
        // Cmd+C (copy) is handled separately in
        // `performKeyEquivalent`, so this path doesn't conflict with
        // clipboard behavior.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .control,
           event.charactersIgnoringModifiers == "c",
           let handler = onCancelQuery {
            handler()
            return
        }
        // ESC: leave the chat view immediately. The ChatView's onDisappear
        // persists the current text + attachments to DraftStore, so the
        // user's draft survives and is restored on re-entry.
        if event.keyCode == 53 {
            // ESC: legacy notch panel exited via .notchEscapePressed.
            // The notch panel is gone; window-mode owns its own ESC
            // handling. Swallow here so the textview doesn't beep.
            return
        }
        // Enter/Return without Shift = submit
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        // Shift+Enter = insert newline
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            insertNewline(nil)
            return
        }
        // Shift+Tab: cycle Claude Code permission mode. Must intercept
        // before super.keyDown, otherwise AppKit treats it as
        // "previous responder" and the input loses focus. Skip
        // auto-repeats so one tap = one cycle (otherwise holding the key
        // would cycle modes 10+ times per second).
        if event.keyCode == 48 && event.modifierFlags.contains(.shift) {
            if !event.isARepeat {
                onCycleMode?()
            }
            return
        }
        // Plain ↑ / ↓ — explicit caret movement.
        //
        // We MUST consume these here. Without this branch, `super.keyDown`
        // dispatches to `interpretKeyEvents`, which CAN bubble through
        // the responder / window chain when the caret is already at the
        // top/bottom edge, ending up at the chat's NSScrollView whose
        // default `keyDown` scrolls. Symptom: typing in a multi-line
        // composer, pressing ↑ scrolls the chat history up instead of
        // moving the composer's caret.
        //
        // Calling `moveUp:` / `moveDown:` directly consumes the event
        // either way: caret moves if it can, no-op otherwise — but the
        // event never propagates further.
        if event.keyCode == 126 {
            self.moveUp(self)
            return
        }
        if event.keyCode == 125 {
            self.moveDown(self)
            return
        }
        super.keyDown(with: event)
    }

    // Draw placeholder text when empty and not focused
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    var isFirstResponder: Bool {
        window?.firstResponder == self
    }
}

// MARK: - Identity-based scroll anchor

/// SwiftUI 15's `.scrollPosition(id:anchor:)` wrapped in an availability
/// gate. On macOS 14 the modifier is a no-op and scroll position is not
/// preserved across notch close/reopen (the chat snaps to the natural
/// default — newest content at visual bottom). Acceptable degradation
/// given the small remaining macOS 14 user base.
struct IdentityScrollAnchor: ViewModifier {
    @Binding var anchorItemId: String?

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // `.bottom` in the unflipped ScrollView coordinate system maps
            // to the visual TOP of the panel after the outer
            // `.scaleEffect(y: -1)` flip — i.e. the row the user is
            // reading. Pinning that row's id keeps it visually fixed
            // across history mutations and notch close/reopen.
            content.scrollPosition(id: $anchorItemId, anchor: .bottom)
        } else {
            content
        }
    }
}

/// Window-mode (un-flipped) helper: tells the ScrollView its default
/// anchor is the bottom so freshly mounted content lands on the
/// newest message, matching the notch's perceived behavior. Notch
/// itself doesn't need this — its content-top IS visual-bottom after
/// the y-flip, so the ScrollView's default content-top anchor already
/// gives the right thing.
struct WindowDefaultScrollAnchor: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active, #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

// MARK: - Backward-compatible scroll geometry modifier

struct ScrollGeometryModifier: ViewModifier {
    let onScrolledAway: () -> Void
    let onScrolledBack: () -> Void
    var embedStyle: ChatViewEmbedStyle = .notch

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                switch embedStyle {
                case .notch:
                    // Flipped layout: scroll-coords y=0 is the visual
                    // bottom (newest), so "at bottom" means
                    // contentOffset is near 0.
                    return geometry.contentOffset.y < 50
                case .window:
                    // Un-flipped: visual bottom = the far end of the
                    // content. "At bottom" means contentOffset is near
                    // contentSize - visibleHeight.
                    let maxOffset = geometry.contentSize.height - geometry.containerSize.height
                    return maxOffset - geometry.contentOffset.y < 50
                }
            } action: { wasAtBottom, isNowAtBottom in
                if wasAtBottom && !isNowAtBottom {
                    onScrolledAway()
                } else if !wasAtBottom && isNowAtBottom {
                    onScrolledBack()
                }
            }
        } else {
            content // On macOS 14, skip scroll geometry detection
        }
    }
}

/// Walks up to the enclosing NSScrollView and registers it with
/// `ChatScrollBridge`. The bridge is consumed by the PgUp/PgDn keyboard
/// monitor (paging) and by the "already at bottom?" check in the
/// auto-scroll path. No save/restore happens here — within-session scroll
/// preservation is provided by NSScrollView's own contentOffset memory
/// because ChatView is always-mounted in the panel hierarchy.
@available(macOS 15.0, *)
private struct ChatScrollBridgeRegistrar: NSViewRepresentable {
    let sessionId: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let probe = sessionId
        // Slight delay so the enclosing NSScrollView is in the hierarchy
        // before we walk up to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let scrollView = view.enclosingScrollView else { return }
            ChatScrollBridge.shared.register(sessionId: probe, scrollView: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // No-op: the bridge entry is keyed by sessionId; the next chat
        // mount overwrites it, and the previous NSScrollView is released
        // by AppKit when no longer referenced.
    }
}

// MARK: - Tool detail drill-down

/// Shared presentation state for ChatView's tool-detail overlay. Lives in
/// its own class so closures (NSEvent monitors, env actions) can capture it
/// by reference and read the current value without the staleness that comes
/// from capturing @State by value.
@MainActor
final class ChatPresentationState: ObservableObject {
    @Published var presentedToolId: String? = nil
    /// Plan markdown shown in a full-panel drill-down. Non-nil while the
    /// user is reading a plan via the expand button in the approval bar.
    @Published var presentedPlan: String? = nil
    /// Pending Edit file shown in a full-panel drill-down. Non-nil while the
    /// user is reading the to-be-edited file via the expand button on the
    /// inline diff card. Carries the absolute path + filename + the hunk's
    /// old_string so the detail view can anchor to and tint the changed
    /// region.
    @Published var presentedPendingEdit: PendingEditContext? = nil
}

/// Identifies a pending Edit drill-down. The detail view reads the current
/// on-disk file, locates the hunk via `oldString`, and splices the
/// proposed `newString` in place so the user sees a unified diff embedded
/// inside the whole file — option (D) of the design conversation. The
/// region of change is anchored on open so the user lands at the hunk
/// instead of line 1.
struct PendingEditContext: Equatable {
    let filePath: String
    let filename: String
    let oldString: String
    let newString: String
}

private struct OpenToolDetailKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

private struct OpenPendingEditKey: EnvironmentKey {
    static let defaultValue: (PendingEditContext) -> Void = { _ in }
}


extension EnvironmentValues {
    /// Closure passed down to ToolCallView so its chevron tap can ask
    /// ChatView to drill into the tool's full result. Argument is the
    /// wrapping ChatHistoryItem.id (ToolCallItem itself has no id).
    var openToolDetail: (String) -> Void {
        get { self[OpenToolDetailKey.self] }
        set { self[OpenToolDetailKey.self] = newValue }
    }

    /// Closure passed down to the inline Edit diff card so its expand
    /// button can ask ChatView to drill into the to-be-edited file. Keeps
    /// SimpleDiffView ignorant of ChatPresentationState.
    var openPendingEdit: (PendingEditContext) -> Void {
        get { self[OpenPendingEditKey.self] }
        set { self[OpenPendingEditKey.self] = newValue }
    }

}

/// Drill-down view for a tool result. Shown as an overlay over the chat
/// list when the user taps a tool call's chevron. Has its own header (back
/// button + tool name + status) and a scrollable body that reuses the
/// existing inline result content.
struct ToolResultDetailView: View {
    let tool: ToolCallItem
    let onDismiss: () -> Void

    private var statusColor: Color {
        switch tool.status {
        case .running: return ChatTheme.statusRunning
        case .waitingForApproval: return ChatTheme.statusPending
        case .success: return ChatTheme.statusSuccess
        case .error, .interrupted: return ChatTheme.statusError
        }
    }

    private var displayName: String {
        MCPToolFormatter.contextualToolName(tool.name, input: tool.input)
    }

    private var inputSummary: String {
        let formatted = MCPToolFormatter.formatArgs(tool.input, maxValueLength: 80, maxArgs: 3)
        return formatted.isEmpty ? "" : "(\(formatted))"
    }

    /// Extract the file content for a Write tool, preferring the structured
    /// result. Falls back to the input `content` arg so we still render
    /// something useful before the structured result lands or for older
    /// sessions without it. Returns nil when neither source has content.
    private func extractWriteContent(tool: ToolCallItem) -> String? {
        if let structured = tool.structuredResult, case .write(let r) = structured {
            return r.content.isEmpty ? nil : r.content
        }
        if let content = tool.input["content"], !content.isEmpty {
            return content
        }
        return nil
    }

    /// Resolve the filename to display in the rich file header. Same fallback
    /// chain as `extractWriteContent`.
    private func extractWriteFilename(tool: ToolCallItem) -> String {
        if let structured = tool.structuredResult, case .write(let r) = structured {
            return r.filename
        }
        if let path = tool.input["file_path"] {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header: back button + tool name + status
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ChatTheme.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to chat (esc)")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{23FA}")
                            .chatScaledFont(size: 10)
                            .foregroundColor(statusColor.opacity(0.7))
                        Text(displayName)
                            .chatScaledFont(size: 13, weight: .semibold)
                            .foregroundColor(ChatTheme.primary)
                    }
                    if !inputSummary.isEmpty {
                        Text(inputSummary)
                            .chatScaledFont(size: 11)
                            .foregroundColor(ChatTheme.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChatTheme.headerBg)

            Divider()

            // Body: the same content the inline expand used to render
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if tool.name == "Write",
                       let writeContent = extractWriteContent(tool: tool) {
                        RichFileView(
                            filename: extractWriteFilename(tool: tool),
                            content: writeContent
                        )
                    } else {
                        ToolResultContent(tool: tool)
                    }

                    if tool.name == "ExitPlanMode" {
                        PlanContentFromInput(input: tool.input)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .background(ChatTheme.headerBg)
    }
}

// MARK: - Plan Detail View

/// Full-panel reader for a pending plan, opened from the approval bar's
/// expand button. Replaces the chat content + approval bar with just the
/// plan, plus a "back" button that returns to the previous state. The
/// Yes/No decision is still made in the approval bar — this view is
/// read-only by design, so the user can examine the plan without
/// committing to a verdict yet. ESC dismisses too via the global ESC
/// handler that NotchPanel installs.
struct PlanDetailView: View {
    let plan: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(ChatTheme.tertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to approval (esc)")

                Text("Plan")
                    .chatScaledFont(size: 13, weight: .semibold)
                    .foregroundColor(ChatTheme.primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChatTheme.headerBg)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                MarkdownText(plan, color: ChatTheme.primary, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(ChatTheme.planBg)
        }
        .background(ChatTheme.headerBg)
    }
}

// MARK: - Pending Edit Detail View

/// Full-panel reader for the file claude is about to edit. Opened from the
/// expand glyph on an inline Edit diff card while the approval is pending.
/// Shows the file as it exists *right now* on disk (option (a) — "what
/// claude is editing from") with the hunk's old_string range tinted, and
/// auto-scrolls there on open so the user lands at the change site instead
/// of line 1.
///
/// File reads happen lazily on appear via Task.detached so the cost is zero
/// until the user actually expands. 2 MB size cap; oversize files render a
/// "too large to preview, open in editor" fallback instead of loading the
/// whole thing into a single ScrollView (a 50k-line file kills layout time).
struct PendingEditDetailView: View {
    let context: PendingEditContext
    let onDismiss: () -> Void

    @State private var fileText: String? = nil
    @State private var loadError: String? = nil

    private static let sizeCapBytes = 2 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
        }
        .background(ChatTheme.headerBg)
        .task(id: context.filePath) {
            await loadFile()
        }
    }

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ChatTheme.tertiary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to approval (esc)")

            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
            Text(context.filename)
                .chatScaledFont(size: 13, weight: .semibold)
                .foregroundColor(ChatTheme.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ChatTheme.headerBg)
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError {
            errorView(err)
        } else if let text = fileText {
            fileBody(text)
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.cardBg.opacity(0.4))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(ChatTheme.tertiary)
            Text(message)
                .chatScaledFont(size: 12)
                .foregroundColor(ChatTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: openInDefaultApp) {
                Text("Open in default app")
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.link)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.cardBg.opacity(0.4))
    }

    /// Per-row data for the embedded whole-file unified diff. `lineNumber`
    /// uses old-file numbers for context + removed rows, new-file numbers
    /// for added rows — matches how DiffView (and claude-code TUI's diff
    /// card) labels the gutter.
    private struct DetailRow: Identifiable {
        let id: Int
        let lineNumber: Int?  // nil for added rows when we don't have a stable new-file index
        let text: String
        let type: DiffLineType
    }

    private func fileBody(_ text: String) -> some View {
        // Whole-file unified diff (option D). Context rows for every line
        // outside the hunk; the hunk's old_string renders as `-` rows in
        // place, immediately followed by new_string's `+` rows. Syntax
        // highlighting runs once over the *post-edit* file so the +/- lines
        // pick up the right token colors, then is sliced per row. The first
        // changed row is anchored on appear.
        let oldLines = text.components(separatedBy: "\n")
        let hunkRange = locateHunk(in: oldLines)
        let newHunkLines = context.newString.components(separatedBy: "\n")
        let language = syntaxLanguage(for: context.filePath)

        // Synthesize the projected post-edit file so syntax highlighting
        // covers the inserted lines too. When the hunk can't be located we
        // fall back to the on-disk content unchanged.
        let projected: String = {
            guard let range = hunkRange else { return text }
            var result = Array(oldLines.prefix(range.lowerBound))
            result.append(contentsOf: newHunkLines)
            result.append(contentsOf: oldLines.suffix(from: range.upperBound))
            return result.joined(separator: "\n")
        }()
        let highlightedNewFile = highlightedLines(
            content: projected,
            language: language,
            defaultColor: ChatTheme.primary
        )
        let highlightedOldFile = highlightedLines(
            content: text,
            language: language,
            defaultColor: ChatTheme.primary
        )

        let rows = buildRows(
            oldLines: oldLines,
            hunkRange: hunkRange,
            newHunkLines: newHunkLines,
            highlightedOld: highlightedOldFile,
            highlightedNew: highlightedNewFile
        )
        let anchorId = rows.firstIndex { $0.type != .context }
        let maxLineNumber = rows.compactMap { $0.lineNumber }.max() ?? oldLines.count
        let gutterWidth = max(2, String(maxLineNumber).count)

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        diffRow(
                            row: row,
                            gutterWidth: gutterWidth,
                            highlightedFor: row,
                            highlightedOld: highlightedOldFile,
                            highlightedNew: highlightedNewFile
                        )
                        .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(ChatTheme.cardBg.opacity(0.4))
            .onAppear {
                guard let anchor = anchorId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
        }
    }

    /// Walk the old file plus the hunk replacement and emit one DetailRow
    /// per visible line. Context rows fall through; the hunk region emits
    /// removed rows (old line numbers) followed by added rows (new line
    /// numbers). Indices are assigned so SwiftUI's id-based diffing /
    /// scrollTo work cleanly.
    private func buildRows(
        oldLines: [String],
        hunkRange: Range<Int>?,
        newHunkLines: [String],
        highlightedOld: [AttributedString],
        highlightedNew: [AttributedString]
    ) -> [DetailRow] {
        var rows: [DetailRow] = []
        var nextId = 0
        // Track running new-file line numbers so + rows label correctly.
        // Context above the hunk shares numbers with old; below the hunk,
        // the shift in line count gets applied for added rows only.
        var newLineCounter = 1

        // Lines before the hunk: context, old==new numbering.
        let upperBefore = hunkRange?.lowerBound ?? oldLines.count
        for idx in 0..<upperBefore {
            rows.append(DetailRow(
                id: nextId,
                lineNumber: idx + 1,
                text: oldLines[idx],
                type: .context
            ))
            nextId += 1
            newLineCounter += 1
        }

        // The hunk: removed lines first, then added lines.
        if let range = hunkRange {
            for idx in range {
                rows.append(DetailRow(
                    id: nextId,
                    lineNumber: idx + 1,
                    text: oldLines[idx],
                    type: .removed
                ))
                nextId += 1
            }
            for newLine in newHunkLines {
                rows.append(DetailRow(
                    id: nextId,
                    lineNumber: newLineCounter,
                    text: newLine,
                    type: .added
                ))
                nextId += 1
                newLineCounter += 1
            }

            // Context after the hunk: keep showing old-file line numbers so
            // the user can locate the surroundings in the on-disk file. The
            // alternative (post-edit numbers) is technically more accurate
            // but confuses the cross-reference with what they'd see in
            // their editor right now.
            for idx in range.upperBound..<oldLines.count {
                rows.append(DetailRow(
                    id: nextId,
                    lineNumber: idx + 1,
                    text: oldLines[idx],
                    type: .context
                ))
                nextId += 1
            }
        }

        return rows
    }

    @ViewBuilder
    private func diffRow(
        row: DetailRow,
        gutterWidth: Int,
        highlightedFor: DetailRow,
        highlightedOld: [AttributedString],
        highlightedNew: [AttributedString]
    ) -> some View {
        let (prefix, prefixColor, bgColor): (String, Color, Color) = {
            switch row.type {
            case .added:
                return ("+", ChatTheme.statusSuccess, ChatTheme.statusSuccess.opacity(0.12))
            case .removed:
                return ("-", ChatTheme.statusError, ChatTheme.statusError.opacity(0.12))
            case .context:
                return (" ", ChatTheme.tertiary, Color.clear)
            }
        }()
        let content = highlightSlice(for: row, highlightedOld: highlightedOld, highlightedNew: highlightedNew)
        HStack(alignment: .top, spacing: 0) {
            Text(row.lineNumber.map { String(format: "%\(gutterWidth)d", $0) } ?? String(repeating: " ", count: gutterWidth))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(ChatTheme.tertiary)
                .padding(.trailing, 6)
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(prefixColor)
                .padding(.trailing, 4)
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(bgColor)
    }

    /// Pick the right highlighted slice for this row. Context + removed rows
    /// come from the on-disk file's highlight pass (so coloring matches what
    /// the file looks like now). Added rows come from the projected
    /// post-edit file so inserted code picks up correct token colors.
    private func highlightSlice(
        for row: DetailRow,
        highlightedOld: [AttributedString],
        highlightedNew: [AttributedString]
    ) -> AttributedString {
        switch row.type {
        case .added:
            // newLineCounter was 1-indexed; the array is 0-indexed.
            if let n = row.lineNumber, n - 1 >= 0, n - 1 < highlightedNew.count {
                return highlightedNew[n - 1]
            }
            return AttributedString(row.text.isEmpty ? " " : row.text)
        case .removed, .context:
            if let n = row.lineNumber, n - 1 >= 0, n - 1 < highlightedOld.count {
                return highlightedOld[n - 1]
            }
            return AttributedString(row.text.isEmpty ? " " : row.text)
        }
    }

    /// Find the contiguous block of lines in `fileLines` that matches the
    /// hunk's `oldString`. Returns nil if old_string is empty (new-file Edit)
    /// or doesn't appear verbatim in the file (already-applied / drifted).
    private func locateHunk(in fileLines: [String]) -> Range<Int>? {
        let target = context.oldString
        guard !target.isEmpty else { return nil }
        let targetLines = target.components(separatedBy: "\n")
        guard !targetLines.isEmpty, fileLines.count >= targetLines.count else { return nil }
        let span = targetLines.count
        let last = fileLines.count - span
        if last < 0 { return nil }
        for start in 0...last {
            if Array(fileLines[start..<(start + span)]) == targetLines {
                return start..<(start + span)
            }
        }
        return nil
    }

    private func loadFile() async {
        let path = context.filePath
        do {
            let url = URL(fileURLWithPath: path)
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.sizeCapBytes {
                await MainActor.run {
                    loadError = "File is \(size / 1024) KB — too large to preview here. Open it in your editor."
                }
                return
            }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            guard let text = String(data: data, encoding: .utf8) else {
                await MainActor.run {
                    loadError = "File isn't valid UTF-8."
                }
                return
            }
            await MainActor.run {
                fileText = text
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
            }
        }
    }

    private func openInDefaultApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: context.filePath))
    }
}

// MARK: - Inline Edit Preview

/// Renders a truncated diff inline under a completed Edit/MultiEdit row so
/// the user can see what changed without drilling into the detail view.
/// Prefers the structured patch when available (line numbers + context),
/// falls back to a synthesized old/new diff. Drill-down (`ToolResultContent`)
/// renders the same data without `maxRows`, so the full diff is always one
/// click away.
/// Inline diff card under a completed Edit/MultiEdit row in chat.
///
/// As of the diffs-by-drill-down refactor, this view returns
/// `EmptyView` and the chat doesn't render any inline diff content
/// at all. The tool-call row's chevron already opens the full
/// drill-down detail view (`ToolResultDetailView`) where the
/// untruncated diff is shown — that's the one path now.
///
/// The struct itself is kept (rather than removing every call
/// site) so the existing message-row layout doesn't have to be
/// rewired; SwiftUI elides the empty view from the layout pass.
struct InlineEditPreview: View {
    let tool: ToolCallItem
    /// Retained for API compatibility with call sites; unused now
    /// that nothing inline can overflow.
    let onOverflowTap: () -> Void

    var body: some View {
        EmptyView()
    }
}

// MARK: - File Link Button

/// Renders a filename as a clickable, link-styled label that opens the
/// file in the user's default editor on click. Used inside the Edit /
/// MultiEdit / Write tool header rows so the user can jump to the file
/// from the chat without drilling in. Codex parity. Falls back to plain
/// text when the path is empty.
struct FileLinkButton: View {
    let filePath: String
    /// Pre-formatted text the surrounding row already computed
    /// (typically the filename's last path component). Kept as a
    /// parameter so this stays a pure presentation primitive.
    let displayText: String

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            Text(displayText)
                .chatScaledFont(size: 10)
                .foregroundColor(ChatTheme.link)
                .underline(isHovering, color: ChatTheme.link)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(filePath)
    }

    private func open() {
        FileOpener.open(path: filePath)
    }
}

// MARK: - Tool Expand Button

/// Right-side affordance on a completed tool row that opens the drill-down
/// detail view. The visible glyph stays small (8pt chevron) so it doesn't
/// dominate the row, but the hit area is enlarged to ~28pt square so it's
/// actually clickable. Brightens on hover for discoverability.
struct ToolExpandButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .chatScaledFont(size: 8, weight: .medium)
                .foregroundColor(isHovering ? ChatTheme.secondary : ChatTheme.muted)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Show details")
    }
}

// MARK: - Inline Read Preview

/// Renders a numbered preview of a Read tool's file content inline under
/// the result summary. Restores the v2.0.0 inline affordance (which used
/// a per-row expand toggle to surface the same content). Skips file types
/// where line-numbered text rendering would be garbage (images, PDFs).
struct InlineReadPreview: View {
    let tool: ToolCallItem
    let onOverflowTap: () -> Void

    private static let inlineCap = 10

    /// File extensions where the Read result is binary or special-formatted
    /// and rendering as numbered text lines would be misleading.
    private static let nonTextExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg",
        "tiff", "bmp", "ico", "mp3", "mp4", "mov", "wav", "zip", "tar", "gz"
    ]

    private func isNonText(_ filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return Self.nonTextExtensions.contains(ext)
    }

    var body: some View {
        if let structured = tool.structuredResult, case .read(let r) = structured {
            if !isNonText(r.filename), !r.content.isEmpty {
                FileCodeView(
                    filename: r.filename,
                    content: r.content,
                    startLine: r.startLine,
                    totalLines: r.totalLines,
                    maxLines: Self.inlineCap,
                    onOverflowTap: onOverflowTap
                )
            }
        }
    }
}

// MARK: - Inline Bash Preview

/// Renders a capped preview of Bash stdout (or stderr when stdout is empty)
/// inline under the result summary so the user sees the output without
/// drilling in. Reuses the existing `CodePreview` component which already
/// truncates and shows a "+N more lines" indicator.
struct InlineBashPreview: View {
    let tool: ToolCallItem

    private static let inlineCap = 15

    var body: some View {
        if let structured = tool.structuredResult, case .bash(let r) = structured {
            // Background tasks have no terminal output; the result summary
            // already says "Background task <id>". Don't repeat ourselves.
            if r.backgroundTaskId == nil {
                let output = r.stdout.isEmpty ? r.stderr : r.stdout
                if !output.isEmpty {
                    CodePreview(content: output, maxLines: Self.inlineCap)
                }
            }
        }
    }
}

// MARK: - Inline Search Preview (Grep / Glob)

/// Renders the list of matched files for completed Grep / Glob calls.
/// Reuses `FileListView` which already caps and shows "... and N more".
struct InlineSearchPreview: View {
    let tool: ToolCallItem

    private static let inlineCap = 8

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case .grep(let r):
                if !r.filenames.isEmpty {
                    FileListView(files: r.filenames, limit: Self.inlineCap)
                }
            case .glob(let r):
                if !r.filenames.isEmpty {
                    FileListView(files: r.filenames, limit: Self.inlineCap)
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Rich File View (drill-down only)

/// Renders a file's content in its native presentation: Markdown is fully
/// rendered (headings, links, lists, code blocks all styled), and other
/// content is shown as plain monospace text. Used by `ToolResultDetailView`
/// when drilling into a Write tool, replacing the legacy raw `CodePreview`
/// rendering. The parent ScrollView handles overflow, so this view is
/// always rendered untruncated.
struct RichFileView: View {
    let filename: String
    let content: String

    private var isMarkdown: Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }

    var body: some View {
        if isMarkdown {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(ChatTheme.tertiary)
                    Text(filename)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(ChatTheme.primary)
                }
                MarkdownText(content, color: Catppuccin.text, fontSize: 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            // Reuse FileCodeView so the expanded drill-down matches the
            // inline collapsed preview's syntax highlighting + line numbers.
            // The earlier plain `Text(content)` branch left this view less
            // richly rendered than its own 10-line inline preview. maxLines
            // = totalLines so nothing truncates; FileCodeView's own header
            // replaces the outer filename label used in the markdown branch.
            let totalLines = content.components(separatedBy: "\n").count
            FileCodeView(
                filename: filename,
                content: content,
                startLine: 1,
                totalLines: totalLines,
                maxLines: totalLines,
                language: syntaxLanguage(for: filename)
            )
        }
    }
}

// MARK: - Inline Write Preview

/// Renders a numbered preview of a Write tool's file content inline under
/// the result summary, capped at 10 lines. Mirrors the Claude Code CLI
/// "Wrote N lines" + first 10 lines + "+M more lines" treatment. Drill-down
/// shows the full content via `WriteResultContent`.
