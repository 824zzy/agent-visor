//
//  ToolResultViews.swift
//  AgentVisor
//
//  Individual views for rendering each tool's result with proper formatting
//

import AppKit
import AgentVisorCore
import Combine
import SwiftUI
import os.log

// MARK: - Tool Result Content Dispatcher

struct ToolResultContent: View {
    let tool: ToolCallItem

    var body: some View {
        if let structured = tool.structuredResult {
            switch structured {
            case .read(let r):
                ReadResultContent(result: r)
            case .edit(let r):
                EditResultContent(result: r, toolInput: tool.input)
            case .write(let r):
                WriteResultContent(result: r)
            case .bash(let r):
                BashResultContent(result: r)
            case .grep(let r):
                GrepResultContent(result: r)
            case .glob(let r):
                GlobResultContent(result: r)
            case .todoWrite(let r):
                TodoWriteResultContent(result: r)
            case .task(let r):
                TaskResultContent(result: r)
            case .webFetch(let r):
                WebFetchResultContent(result: r)
            case .webSearch(let r):
                WebSearchResultContent(result: r)
            case .askUserQuestion(let r):
                AskUserQuestionResultContent(result: r)
            case .bashOutput(let r):
                BashOutputResultContent(result: r)
            case .killShell(let r):
                KillShellResultContent(result: r)
            case .exitPlanMode(let r):
                ExitPlanModeResultContent(result: r)
            case .mcp(let r):
                MCPResultContent(result: r)
            case .generic(let r):
                GenericResultContent(result: r)
            }
        } else if tool.name == "Edit" {
            // Special fallback for Edit - show diff from input params
            EditInputDiffView(input: tool.input)
        } else if let result = tool.result {
            // Fallback to raw text display
            GenericTextContent(text: result)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Edit Input Diff View (fallback when no structured result)

struct EditInputDiffView: View {
    let input: [String: String]

    @Environment(\.openPendingEdit) private var openPendingEdit

    private var filePath: String? {
        input["file_path"]
    }

    private var filename: String {
        if let path = filePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return "file"
    }

    private var oldString: String {
        input["old_string"] ?? ""
    }

    private var newString: String {
        input["new_string"] ?? ""
    }

    /// Build the onExpand closure for SimpleDiffView. Only fires when we have
    /// an absolute path AND the file exists on disk — without the actual file
    /// there's nothing to expand into. The fileManager check is a fast stat,
    /// not a content read.
    private var expandHandler: (() -> Void)? {
        guard let path = filePath else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let ctx = PendingEditContext(
            filePath: path,
            filename: filename,
            oldString: oldString,
            newString: newString
        )
        return { openPendingEdit(ctx) }
    }

    /// File-aware unified-diff hunk for the proposed edit. Reads the file
    /// from disk, locates `oldString`, and includes 3 context lines on each
    /// side — matches what claude-code's TUI shows in the approval prompt.
    /// Returns nil when the file can't be read or `oldString` isn't found
    /// (e.g. assistant produced a stale edit); caller falls back to the
    /// input-only LCS view so the user still sees the proposed change.
    private var fileAwarePatch: PatchHunk? {
        guard let path = filePath, !oldString.isEmpty else { return nil }
        return ChatApprovalBar.buildEditPatchHunk(
            filePath: path,
            oldString: oldString,
            newString: newString
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hunk = fileAwarePatch {
                // Real file line numbers + 3 lines of context on each side,
                // matching claude-code TUI's approval-prompt diff format.
                DiffView(
                    patches: [hunk],
                    filename: filename,
                    filePath: filePath,
                    onExpand: expandHandler
                )
            } else if !oldString.isEmpty || !newString.isEmpty {
                // Fallback: file unreadable or old_string drifted from disk.
                // Show input-only LCS so the user still sees the proposed
                // change, even without absolute line numbers.
                SimpleDiffView(
                    oldString: oldString,
                    newString: newString,
                    filename: filename,
                    onExpand: expandHandler
                )
            }
        }
    }
}

// MARK: - Read Result View

struct ReadResultContent: View {
    let result: ReadResult

    var body: some View {
        if !result.content.isEmpty {
            FileCodeView(
                filename: result.filename,
                content: result.content,
                startLine: result.startLine,
                totalLines: result.totalLines,
                maxLines: 10,
                language: syntaxLanguage(for: result.filePath)
            )
        }
    }
}

// MARK: - Edit Result View

struct EditResultContent: View {
    let result: EditResult
    var toolInput: [String: String] = [:]

    /// Get old string - prefer result, fallback to input
    private var oldString: String {
        if !result.oldString.isEmpty {
            return result.oldString
        }
        return toolInput["old_string"] ?? ""
    }

    /// Get new string - prefer result, fallback to input
    private var newString: String {
        if !result.newString.isEmpty {
            return result.newString
        }
        return toolInput["new_string"] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Prefer the structured patch when Claude Code provided one — it
            // carries absolute line numbers and surrounding context, which
            // matches what the terminal TUI shows. Fall back to a synthesized
            // old/new diff only when no patch is available (older sessions,
            // or tools that didn't emit one).
            if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches, filename: result.filename, filePath: result.filePath)
            } else if !oldString.isEmpty || !newString.isEmpty {
                SimpleDiffView(oldString: oldString, newString: newString, filename: result.filename)
            }

            if result.userModified {
                Text("(User modified)")
                    .chatScaledFont(size: 10)
                    .foregroundColor(ChatTheme.statusRunning)
            }
        }
    }
}

// MARK: - Write Result View

struct WriteResultContent: View {
    let result: WriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Action and filename
            HStack(spacing: 4) {
                Text(result.type == .create ? "Created" : "Wrote")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
                Text(result.filename)
                    .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundColor(ChatTheme.primary)
            }

            // Content preview for new files
            if result.type == .create && !result.content.isEmpty {
                CodePreview(
                    content: result.content,
                    maxLines: 8,
                    language: syntaxLanguage(for: result.filePath)
                )
            } else if let patches = result.structuredPatch, !patches.isEmpty {
                DiffView(patches: patches)
            }
        }
    }
}

// MARK: - Bash Result View

struct BashResultContent: View {
    let result: BashResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Background task indicator
            if let bgId = result.backgroundTaskId {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .chatScaledFont(size: 10)
                    Text("Background task: \(bgId)")
                        .chatScaledFont(size: 10, design: .monospaced)
                }
                .foregroundColor(ChatTheme.link)
            }

            // Return code interpretation
            if let interpretation = result.returnCodeInterpretation {
                Text(interpretation)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }

            // Stdout
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 15, language: "bash")
            }

            // Stderr (shown in red)
            if !result.stderr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stderr:")
                        .chatScaledFont(size: 10, weight: .medium)
                        .foregroundColor(ChatTheme.statusError)
                    Text(result.stderr)
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.statusError)
                        .lineLimit(10)
                }
            }

            // Empty state
            if !result.hasOutput && result.backgroundTaskId == nil && result.returnCodeInterpretation == nil {
                Text("(No content)")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
            }
        }
    }
}

// MARK: - Grep Result View

struct GrepResultContent: View {
    let result: GrepResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch result.mode {
            case .filesWithMatches:
                // Show file list
                if result.filenames.isEmpty {
                    Text("No matches found")
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                } else {
                    FileListView(files: result.filenames, limit: 10)
                }

            case .content:
                // Show matching content
                if let content = result.content, !content.isEmpty {
                    CodePreview(content: content, maxLines: 15)
                } else {
                    Text("No matches found")
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                }

            case .count:
                Text("\(result.numFiles) files with matches")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
            }
        }
    }
}

// MARK: - Glob Result View

struct GlobResultContent: View {
    let result: GlobResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.filenames.isEmpty {
                Text("No files found")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
            } else {
                FileListView(files: result.filenames, limit: 10)

                if result.truncated {
                    Text("... and more (truncated)")
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.tertiary)
                }
            }
        }
    }
}

// MARK: - TodoWrite Result View

struct TodoWriteResultContent: View {
    let result: TodoWriteResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(result.newTodos.enumerated()), id: \.offset) { _, todo in
                HStack(spacing: 6) {
                    // Status icon
                    Image(systemName: todoIcon(for: todo.status))
                        .chatScaledFont(size: 10)
                        .foregroundColor(todoColor(for: todo.status))
                        .frame(width: 12)

                    Text(todo.content)
                        .chatScaledFont(size: 11)
                        .foregroundColor(todo.status == "completed" ? ChatTheme.tertiary : ChatTheme.primary)
                        .strikethrough(todo.status == "completed")
                        .lineLimit(2)
                }
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status {
        case "completed": return ChatTheme.statusSuccess
        case "in_progress": return ChatTheme.statusRunning
        default: return ChatTheme.tertiary
        }
    }
}

// MARK: - Task Result View

struct TaskResultContent: View {
    let result: TaskResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Status and stats
            HStack(spacing: 8) {
                Text(result.status.capitalized)
                    .chatScaledFont(size: 11, weight: .medium)
                    .foregroundColor(statusColor)

                if let duration = result.totalDurationMs {
                    Text("\(formatDuration(duration))")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                }

                if let tools = result.totalToolUseCount {
                    Text("\(tools) tools")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                }
            }

            // Content summary
            if !result.content.isEmpty {
                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.secondary)
                    .lineLimit(5)
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case "completed": return ChatTheme.statusSuccess
        case "in_progress": return ChatTheme.statusRunning
        case "failed", "error": return ChatTheme.statusError
        default: return ChatTheme.secondary
        }
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms >= 60000 {
            return "\(ms / 60000)m \((ms % 60000) / 1000)s"
        } else if ms >= 1000 {
            return "\(ms / 1000)s"
        }
        return "\(ms)ms"
    }
}

// MARK: - WebFetch Result View

struct WebFetchResultContent: View {
    let result: WebFetchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // URL and status
            HStack(spacing: 6) {
                Text("\(result.code)")
                    .chatScaledFont(size: 10, weight: .medium, design: .monospaced)
                    .foregroundColor(result.code < 400 ? ChatTheme.statusSuccess : ChatTheme.statusError)

                Text(truncateUrl(result.url))
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)
                    .lineLimit(1)
            }

            // Result summary
            if !result.result.isEmpty {
                Text(result.result.prefix(300) + (result.result.count > 300 ? "..." : ""))
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.secondary)
                    .lineLimit(8)
            }
        }
    }

    private func truncateUrl(_ url: String) -> String {
        if url.count > 50 {
            return String(url.prefix(47)) + "..."
        }
        return url
    }
}

// MARK: - WebSearch Result View

struct WebSearchResultContent: View {
    let result: WebSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.results.isEmpty {
                Text("No results found")
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
            } else {
                ForEach(Array(result.results.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .chatScaledFont(size: 11, weight: .medium)
                            .foregroundColor(ChatTheme.link)
                            .lineLimit(1)

                        if !item.snippet.isEmpty {
                            Text(item.snippet)
                                .chatScaledFont(size: 10)
                                .foregroundColor(ChatTheme.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                if result.results.count > 5 {
                    Text("... and \(result.results.count - 5) more results")
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.tertiary)
                }
            }
        }
    }
}

// MARK: - AskUserQuestion Pending View
//
// Rich rendering for an AskUserQuestion tool_use that's still waiting on
// the user. Mirrors what Claude Code's TUI shows: the header chip, the
// question text, and the options list with descriptions. Decoded from the
// JSON-encoded `questions` field on `tool.input`.

struct AskUserQuestionPendingDecoder {
    struct Question: Equatable {
        let id: String?
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
        let isOther: Bool
    }

    struct Option: Equatable {
        let label: String
        let description: String
    }

    static func decode(_ json: String?) -> [Question]? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return arr.enumerated().compactMap { index, dict in
            guard let q = dict["question"] as? String else { return nil }
            let id = dict["id"] as? String ?? dict["questionId"] as? String
            let header = dict["header"] as? String ?? "Question \(index + 1)"
            let multiSelect = dict["multiSelect"] as? Bool ?? false
            let isOther = dict["isOther"] as? Bool ?? false
            let optionsArr = dict["options"] as? [[String: Any]] ?? []
            let options = optionsArr.compactMap { opt -> Option? in
                guard let label = opt["label"] as? String else { return nil }
                let desc = opt["description"] as? String ?? ""
                return Option(label: label, description: desc)
            }
            return Question(id: id, question: q, header: header, options: options, multiSelect: multiSelect, isOther: isOther)
        }
    }
}

@MainActor
enum AskUserQuestionSubmissionCoordinator {
    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "AskUserQuestionSubmit")

    static func hasClaudeCodeTransport(sessionId: String) -> Bool {
        HookSocketServer.shared.hasPendingPermission(sessionId: sessionId)
    }

    static func hasCodexTransport(sessionId: String) -> Bool {
        CodexAppServerApprovalBridge.shared.hasPendingUserInput(sessionId: sessionId)
    }

    static func submitClaudeCode(
        sessionId: String,
        questions: [AskUserQuestionPendingDecoder.Question],
        answers: [AskUserQuestionAnswerBuilder.Answer],
        activeToolUseId: String?
    ) {
        guard let pending = HookSocketServer.shared.getPendingPermission(sessionId: sessionId),
              let toolInput = pending.toolInput,
              let questionsAny = toolInput["questions"] else {
            logger.error("submit: no captured questions in pending tool_input sid=\(sessionId.prefix(8), privacy: .public)")
            if let toolUseId = activeToolUseId {
                HookSocketServer.shared.respondToPermission(
                    toolUseId: toolUseId,
                    decision: "deny",
                    reason: "\(AppBranding.appName) lost the original question payload"
                )
                Task {
                    await SessionStore.shared.process(
                        .permissionDenied(
                            sessionId: sessionId,
                            toolUseId: toolUseId,
                            reason: "\(AppBranding.appName) lost the original question payload"
                        )
                    )
                }
            }
            return
        }

        let coreQuestions = questions.map {
            AskUserQuestionAnswerBuilder.Question(
                questionText: $0.question,
                optionLabels: $0.options.map(\.label),
                multiSelect: $0.multiSelect
            )
        }
        let answersDict = AskUserQuestionAnswerBuilder.build(
            questions: coreQuestions,
            answers: answers
        )
        let updatedInput: [String: AnyCodable] = [
            "questions": questionsAny,
            "answers": AnyCodable(answersDict),
        ]

        logger.info("submit: questions=\(questions.count, privacy: .public) answers=\(answersDict.count, privacy: .public) sid=\(sessionId.prefix(8), privacy: .public) via=hook-socket")
        HookSocketServer.shared.respondToPermissionBySession(
            sessionId: sessionId,
            decision: "allow",
            updatedInput: updatedInput
        )
    }

    static func cancelClaudeCode(sessionId: String, activeToolUseId: String?) {
        let reason = "Cancelled by user via Ctrl+C"
        let toolUseId = HookSocketServer.shared.getPendingPermission(sessionId: sessionId)?.toolId ?? activeToolUseId
        guard let toolUseId else {
            logger.error("cancel: no tool id sid=\(sessionId.prefix(8), privacy: .public)")
            return
        }
        HookSocketServer.shared.respondToPermission(
            toolUseId: toolUseId,
            decision: "deny",
            reason: reason
        )
        Task {
            await SessionStore.shared.process(
                .permissionDenied(
                    sessionId: sessionId,
                    toolUseId: toolUseId,
                    reason: reason
                )
            )
        }
    }

    static func submitCodex(
        sessionId: String,
        questions: [AskUserQuestionPendingDecoder.Question],
        answers: [AskUserQuestionAnswerBuilder.Answer]
    ) {
        let codexQuestions = questions.map {
            CodexUserInputAnswerBuilder.Question(
                id: $0.id ?? $0.question,
                optionLabels: $0.options.map(\.label),
                multiSelect: $0.multiSelect,
                isOther: $0.isOther
            )
        }
        let codexAnswers = answers.map {
            CodexUserInputAnswerBuilder.Answer(
                singleSelected: $0.singleSelected,
                multiSelected: $0.multiSelected,
                otherText: $0.otherText
            )
        }
        let answersByQuestionId = CodexUserInputAnswerBuilder.build(
            questions: codexQuestions,
            answers: codexAnswers
        )
        logger.info("submit: questions=\(questions.count, privacy: .public) answers=\(answersByQuestionId.count, privacy: .public) sid=\(sessionId.prefix(8), privacy: .public) via=codex-app-server")
        CodexAppServerApprovalBridge.shared.resolveUserInput(
            sessionId: sessionId,
            answersByQuestionId: answersByQuestionId
        )
    }

    static func cancelCodex(sessionId: String) {
        logger.info("cancel codex user input sid=\(sessionId.prefix(8), privacy: .public)")
        CodexAppServerApprovalBridge.shared.cancelUserInput(sessionId: sessionId)
    }
}

// MARK: - Multi-question Form State

/// Per-question local state. Mirrors claude-code's `questionStates`
/// from `use-multiple-choice-state.ts`: tracks the user's pick(s) plus
/// any free-form text typed into the auto-appended "Other" option.
/// `optionFocus` is the arrow-nav cursor inside the current question.
private struct QuestionLocalState: Equatable {
    var singleSelectedIndex: Int? = nil
    var multiSelectedIndices: Set<Int> = []
    var otherText: String = ""
    var optionFocus: Int = 0
}

/// Form-level state, mirroring claude-code's outer `useMultipleChoiceState`.
/// `currentStep` runs `0...questions.count` — the trailing slot is the
/// SubmitView (review + final submit/cancel), matching the TUI's extra
/// "Submit" tab. Owned by the view via `@StateObject` so a long-lived
/// NSEvent keyboard monitor (created once in `.onAppear`) can read fresh
/// state without recapturing the SwiftUI view struct.
@MainActor
private final class QuestionFlowState: ObservableObject {
    @Published var currentStep: Int = 0 { didSet { persist() } }
    @Published var perQuestion: [Int: QuestionLocalState] = [:] { didSet { persist() } }
    @Published var submitted: Bool = false
    @Published var canceled: Bool = false
    /// Question index currently editing its "Other" text field, or nil
    /// when the field is unfocused. Drives `@FocusState` and the
    /// keyboard-monitor's pass-through gate so typed chars don't trigger
    /// option shortcuts while editing. Intentionally NOT persisted —
    /// `@FocusState` doesn't survive view unmount, and re-forcing the
    /// keyboard on remount would be jarring (especially if the user
    /// navigated away to escape it).
    @Published var otherEditingIndex: Int? = nil

    /// Persistence wiring. Both nil means "ephemeral mode" — no
    /// write-through, no cleanup; matches old behavior. Set by
    /// `AskUserQuestionPendingContent.init` when sessionId is known.
    private let sessionId: String?
    private let fingerprint: String?

    init(
        sessionId: String? = nil,
        fingerprint: String? = nil,
        initialSnapshot: QuestionFlowSnapshot? = nil
    ) {
        self.sessionId = sessionId
        self.fingerprint = fingerprint
        if let snap = initialSnapshot {
            self.currentStep = snap.currentStep
            self.perQuestion = snap.perQuestion.reduce(into: [:]) { acc, kv in
                acc[kv.key] = QuestionLocalState(
                    singleSelectedIndex: kv.value.singleSelectedIndex,
                    multiSelectedIndices: kv.value.multiSelectedIndices,
                    otherText: kv.value.otherText,
                    optionFocus: kv.value.optionFocus
                )
            }
        }
    }

    func state(for index: Int) -> QuestionLocalState {
        perQuestion[index] ?? QuestionLocalState()
    }

    func update(_ index: Int, _ mutate: (inout QuestionLocalState) -> Void) {
        var s = perQuestion[index] ?? QuestionLocalState()
        mutate(&s)
        perQuestion[index] = s
    }

    /// Project the live state into a value-type snapshot the draft
    /// store can hold. Excludes terminal flags and transient focus
    /// state — see `QuestionFlowSnapshot` doc for why.
    func snapshot() -> QuestionFlowSnapshot {
        let snap = perQuestion.reduce(into: [Int: QuestionLocalStateSnapshot]()) { acc, kv in
            acc[kv.key] = QuestionLocalStateSnapshot(
                singleSelectedIndex: kv.value.singleSelectedIndex,
                multiSelectedIndices: kv.value.multiSelectedIndices,
                otherText: kv.value.otherText,
                optionFocus: kv.value.optionFocus
            )
        }
        return QuestionFlowSnapshot(currentStep: currentStep, perQuestion: snap)
    }

    /// Write-through invoked from every persisted-field `didSet`. No
    /// debounce: the store is in-memory, the data is small, and a
    /// debounce window would risk losing the last keystroke when the
    /// view unmounts.
    private func persist() {
        guard let sessionId, let fingerprint else { return }
        AskUserQuestionDraftStore.shared.save(
            sessionId: sessionId,
            fingerprint: fingerprint,
            snapshot: snapshot()
        )
    }
}

struct AskUserQuestionPendingContent: View {
    let questions: [AskUserQuestionPendingDecoder.Question]
    /// True while the tool is still .running / .waitingForApproval.
    let isPending: Bool
    /// Required for keyboard interactivity and draft persistence.
    /// nil disables interactivity entirely.
    let sessionId: String?
    let canSubmitTransport: Bool
    let transportUnavailableMessage: String?
    let onSubmitAnswers: ([AskUserQuestionPendingDecoder.Question], [AskUserQuestionAnswerBuilder.Answer]) -> Void
    let onCancel: () -> Void

    @StateObject private var flow: QuestionFlowState
    @State private var keyMonitor: Any?
    @FocusState private var otherFieldFocused: Bool

    /// Custom init so `flow` can be hydrated from
    /// `AskUserQuestionDraftStore` BEFORE the first body render —
    /// avoiding a flash of "form reset" between mount and `.onAppear`.
    /// The fingerprint guards stale drafts: if the prompt has shifted
    /// shape since the last draft was saved, `get` returns nil and
    /// we start fresh.
    init(
        questions: [AskUserQuestionPendingDecoder.Question],
        isPending: Bool,
        sessionId: String?,
        canSubmitTransport: Bool,
        transportUnavailableMessage: String? = nil,
        onSubmitAnswers: @escaping ([AskUserQuestionPendingDecoder.Question], [AskUserQuestionAnswerBuilder.Answer]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.questions = questions
        self.isPending = isPending
        self.sessionId = sessionId
        self.canSubmitTransport = canSubmitTransport
        self.transportUnavailableMessage = transportUnavailableMessage
        self.onSubmitAnswers = onSubmitAnswers
        self.onCancel = onCancel

        let fingerprint = AskUserQuestionDraftFingerprint.compute(
            questions: questions.map { q in
                AskUserQuestionDraftFingerprint.Question(
                    question: q.question,
                    header: q.header,
                    options: q.options.map {
                        AskUserQuestionDraftFingerprint.Option(
                            label: $0.label,
                            description: $0.description
                        )
                    },
                    multiSelect: q.multiSelect
                )
            }
        )
        let snapshot: QuestionFlowSnapshot? = sessionId.flatMap {
            AskUserQuestionDraftStore.shared.get(sessionId: $0, fingerprint: fingerprint)
        }
        _flow = StateObject(wrappedValue: QuestionFlowState(
            sessionId: sessionId,
            fingerprint: fingerprint,
            initialSnapshot: snapshot
        ))
    }

    private static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "AskUserQuestionView")

    private var canInteract: Bool {
        isPending && !flow.submitted && !flow.canceled && sessionId != nil
    }

    /// True when we're past the last question, on the final review screen.
    private var isOnSubmitStep: Bool { flow.currentStep == questions.count }

    /// All declared questions answered (or, for "Other"-selected, has
    /// non-empty text). Gates the final Submit button.
    private var allAnswered: Bool {
        questions.indices.allSatisfy { isQuestionAnswered(at: $0) }
    }

    private func isQuestionAnswered(at index: Int) -> Bool {
        guard index < questions.count else { return false }
        let q = questions[index]
        let s = flow.state(for: index)
        let otherIndex = q.options.count
        if q.multiSelect {
            if s.multiSelectedIndices.isEmpty { return false }
            if s.multiSelectedIndices.contains(otherIndex) {
                return s.multiSelectedIndices.count > 1 ||
                    !s.otherText.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        } else {
            guard let idx = s.singleSelectedIndex else { return false }
            if idx == otherIndex {
                return !s.otherText.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            navigationBar
            if isOnSubmitStep {
                submitView
            } else if flow.currentStep < questions.count {
                questionView(at: flow.currentStep)
            }
            footerHint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { installMonitor() }
        .onDisappear { removeMonitor() }
        .onChange(of: canInteract) { _, newValue in
            if newValue { installMonitor() } else { removeMonitor() }
        }
        .onChange(of: flow.otherEditingIndex) { _, newValue in
            // The TextField only mounts when its question's Other option is
            // selected, and the selection state change reaches the body on
            // the same tick this onChange fires. Assigning focus inline
            // races the mount and silently no-ops; defer one runloop so the
            // field is present when @FocusState writes through.
            if newValue != nil {
                DispatchQueue.main.async {
                    otherFieldFocused = true
                }
            } else {
                otherFieldFocused = false
            }
        }
    }

    // MARK: - Navigation Bar

    @ViewBuilder
    private var navigationBar: some View {
        // Tab strip — one chip per question + a final Submit chip,
        // mirroring claude-code's QuestionNavigationBar. Click jumps; the
        // current step is highlighted; answered questions get a check.
        HStack(spacing: 6) {
            ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                navigationChip(
                    label: q.header,
                    icon: isQuestionAnswered(at: idx) ? "checkmark.circle.fill" : "circle",
                    isCurrent: idx == flow.currentStep,
                    isEnabled: true
                ) {
                    jumpTo(step: idx)
                }
            }
            navigationChip(
                label: "Submit",
                icon: "paperplane.fill",
                isCurrent: isOnSubmitStep,
                isEnabled: allAnswered
            ) {
                jumpTo(step: questions.count)
            }
        }
    }

    @ViewBuilder
    private func navigationChip(label: String, icon: String, isCurrent: Bool, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .chatScaledFont(size: 9)
                Text(label)
                    .chatScaledFont(size: 10, weight: isCurrent ? .semibold : .regular)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? ChatTheme.statusRunning.opacity(0.18) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isCurrent ? ChatTheme.statusRunning : ChatTheme.muted.opacity(0.4), lineWidth: 1)
                    )
            )
            .foregroundColor(isCurrent ? ChatTheme.primary : (isEnabled ? ChatTheme.secondary : ChatTheme.tertiary))
        }
        .buttonStyle(.plain)
        .disabled(!canInteract || !isEnabled)
    }

    // MARK: - Question View

    @ViewBuilder
    private func questionView(at index: Int) -> some View {
        let q = questions[index]
        let s = flow.state(for: index)
        let otherIndex = q.options.count
        VStack(alignment: .leading, spacing: 8) {
            Text(q.question)
                .chatScaledFont(size: 12, weight: .semibold)
                .foregroundColor(ChatTheme.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { optIdx, opt in
                    optionRow(
                        questionIndex: index,
                        optionIndex: optIdx,
                        label: opt.label,
                        description: opt.description,
                        isMulti: q.multiSelect,
                        isSelected: q.multiSelect
                            ? s.multiSelectedIndices.contains(optIdx)
                            : s.singleSelectedIndex == optIdx,
                        isFocused: s.optionFocus == optIdx
                    )
                }
                otherRow(
                    questionIndex: index,
                    otherIndex: otherIndex,
                    isMulti: q.multiSelect,
                    isSelected: q.multiSelect
                        ? s.multiSelectedIndices.contains(otherIndex)
                        : s.singleSelectedIndex == otherIndex,
                    isFocused: s.optionFocus == otherIndex,
                    text: s.otherText
                )
            }

            questionFooterButtons(at: index)
        }
    }

    @ViewBuilder
    private func optionRow(questionIndex: Int, optionIndex: Int, label: String, description: String, isMulti: Bool, isSelected: Bool, isFocused: Bool) -> some View {
        Button(action: { onTapOption(questionIndex: questionIndex, optionIndex: optionIndex) }) {
            HStack(alignment: .top, spacing: 6) {
                Text(isFocused ? "\u{276F}" : " ")
                    .chatScaledFont(size: 11, weight: .bold, design: .monospaced)
                    .foregroundColor(ChatTheme.statusRunning)
                    .frame(width: 10, alignment: .leading)
                Image(systemName: selectionIcon(isMulti: isMulti, isSelected: isSelected))
                    .chatScaledFont(size: 11)
                    .foregroundColor(isSelected ? ChatTheme.statusRunning : ChatTheme.muted)
                    .frame(width: 14, alignment: .center)
                Text("\(optionIndex + 1).")
                    .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundColor(isFocused ? ChatTheme.primary : ChatTheme.tertiary)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .chatScaledFont(size: 11, weight: isFocused ? .semibold : .medium)
                        .foregroundColor(isSelected ? ChatTheme.primary : (isFocused ? ChatTheme.primary : ChatTheme.secondary))
                    Text(description)
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isFocused ? ChatTheme.statusRunning.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canInteract)
    }

    @ViewBuilder
    private func otherRow(questionIndex: Int, otherIndex: Int, isMulti: Bool, isSelected: Bool, isFocused: Bool, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { onTapOption(questionIndex: questionIndex, optionIndex: otherIndex) }) {
                HStack(alignment: .top, spacing: 6) {
                    Text(isFocused ? "\u{276F}" : " ")
                        .chatScaledFont(size: 11, weight: .bold, design: .monospaced)
                        .foregroundColor(ChatTheme.statusRunning)
                        .frame(width: 10, alignment: .leading)
                    Image(systemName: selectionIcon(isMulti: isMulti, isSelected: isSelected))
                        .chatScaledFont(size: 11)
                        .foregroundColor(isSelected ? ChatTheme.statusRunning : ChatTheme.muted)
                        .frame(width: 14, alignment: .center)
                    Text("\(otherIndex + 1).")
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(isFocused ? ChatTheme.primary : ChatTheme.tertiary)
                        .frame(width: 18, alignment: .trailing)
                    Text("Other")
                        .chatScaledFont(size: 11, weight: isFocused ? .semibold : .medium)
                        .foregroundColor(isSelected ? ChatTheme.primary : (isFocused ? ChatTheme.primary : ChatTheme.secondary))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isFocused ? ChatTheme.statusRunning.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canInteract)

            if isSelected {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text("Type your answer…")
                            .chatScaledFont(size: 11)
                            .foregroundColor(ChatTheme.tertiary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: Binding(
                        get: { flow.state(for: questionIndex).otherText },
                        set: { newValue in flow.update(questionIndex) { $0.otherText = newValue } }
                    ))
                    .textFieldStyle(.plain)
                    .chatScaledFont(size: 11)
                    .foregroundColor(ChatTheme.primary)
                    .focused($otherFieldFocused)
                    .onSubmit { advanceFromOtherField(at: questionIndex) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ChatTheme.inputBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(otherFieldFocused ? ChatTheme.statusRunning : ChatTheme.inputBorder, lineWidth: 1)
                )
                .padding(.leading, 32)
                .onTapGesture { flow.otherEditingIndex = questionIndex }
                .disabled(!canInteract)
            }
        }
    }

    private func selectionIcon(isMulti: Bool, isSelected: Bool) -> String {
        if isMulti {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    @ViewBuilder
    private func questionFooterButtons(at index: Int) -> some View {
        HStack(spacing: 10) {
            if index > 0 {
                Button(action: { jumpTo(step: index - 1) }) {
                    Label("Back", systemImage: "chevron.left")
                        .chatScaledFont(size: 11)
                }
                .buttonStyle(.plain)
                .foregroundColor(ChatTheme.secondary)
                .disabled(!canInteract)
            }
            Spacer(minLength: 0)
            let isLast = index == questions.count - 1
            Button(action: { jumpTo(step: index + 1) }) {
                Label(isLast ? "Review" : "Next", systemImage: "chevron.right")
                    .chatScaledFont(size: 11, weight: .medium)
                    .labelStyle(ReverseIconLabelStyle())
            }
            .buttonStyle(.plain)
            .foregroundColor(isQuestionAnswered(at: index) ? ChatTheme.statusRunning : ChatTheme.tertiary)
            .disabled(!canInteract || !isQuestionAnswered(at: index))
        }
        .padding(.top, 4)
    }

    // MARK: - Submit View (final review)

    @ViewBuilder
    private var submitView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review your answers")
                .chatScaledFont(size: 12, weight: .semibold)
                .foregroundColor(ChatTheme.primary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(questions.enumerated()), id: \.offset) { idx, q in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\u{2022}")
                            .foregroundColor(ChatTheme.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(q.question)
                                .chatScaledFont(size: 11, weight: .medium)
                                .foregroundColor(ChatTheme.secondary)
                            Text(displayAnswer(at: idx))
                                .chatScaledFont(size: 11)
                                .foregroundColor(isQuestionAnswered(at: idx) ? ChatTheme.statusRunning : Color.orange)
                        }
                    }
                }
            }
            if canInteract && !canSubmitTransport, let transportUnavailableMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .chatScaledFont(size: 11)
                        .foregroundColor(.orange)
                    Text(transportUnavailableMessage)
                        .chatScaledFont(size: 11)
                        .foregroundColor(ChatTheme.secondary)
                }
                .padding(.top, 4)
            }
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "xmark")
                        .chatScaledFont(size: 11)
                }
                .buttonStyle(.plain)
                .foregroundColor(ChatTheme.tertiary)
                .disabled(!canInteract)
                Spacer(minLength: 0)
                Button(action: submit) {
                    Label("Submit Answers", systemImage: "paperplane.fill")
                        .chatScaledFont(size: 11, weight: .semibold)
                        .labelStyle(ReverseIconLabelStyle())
                }
                .buttonStyle(.plain)
                .foregroundColor(canSubmit ? ChatTheme.statusRunning : ChatTheme.tertiary)
                .disabled(!canSubmit)
            }
            .padding(.top, 6)
        }
    }

    private func displayAnswer(at index: Int) -> String {
        guard index < questions.count else { return "" }
        let q = questions[index]
        let s = flow.state(for: index)
        if q.multiSelect {
            let sorted = s.multiSelectedIndices.sorted()
            let labels = sorted.compactMap { idx -> String? in
                if idx < q.options.count { return q.options[idx].label }
                let trimmed = s.otherText.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return labels.isEmpty ? "(no answer)" : labels.joined(separator: ", ")
        } else {
            guard let idx = s.singleSelectedIndex else { return "(no answer)" }
            if idx < q.options.count { return q.options[idx].label }
            let trimmed = s.otherText.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "(no answer)" : trimmed
        }
    }

    // MARK: - Footer Hint

    @ViewBuilder
    private var footerHint: some View {
        if isPending && canInteract {
            Text("↑/↓ navigate · 1-9 jump · ⏎ pick · ⇥/⇧⇥ next/prev · ⌃C cancel · esc exit")
                .chatScaledFont(size: 10, design: .monospaced)
                .foregroundColor(ChatTheme.tertiary)
        }
    }

    // MARK: - Actions

    private func onTapOption(questionIndex: Int, optionIndex: Int) {
        guard canInteract, questionIndex < questions.count else { return }
        let q = questions[questionIndex]
        let otherIndex = q.options.count
        flow.update(questionIndex) { state in
            state.optionFocus = optionIndex
            if q.multiSelect {
                if state.multiSelectedIndices.contains(optionIndex) {
                    state.multiSelectedIndices.remove(optionIndex)
                } else {
                    state.multiSelectedIndices.insert(optionIndex)
                }
            } else {
                state.singleSelectedIndex = optionIndex
            }
        }
        if optionIndex == otherIndex {
            flow.otherEditingIndex = questionIndex
        } else {
            flow.otherEditingIndex = nil
        }
    }

    private func jumpTo(step: Int) {
        guard step >= 0, step <= questions.count else { return }
        flow.currentStep = step
        flow.otherEditingIndex = nil
    }

    /// Enter-to-commit from the Other text field: select the Other option
    /// if it isn't already, then advance to the next step (or the Submit
    /// review when this is the last question). No-op if the field is
    /// empty so users don't lose their place by hitting Enter early.
    private func advanceFromOtherField(at index: Int) {
        guard canInteract, index < questions.count else { return }
        let q = questions[index]
        let otherIndex = q.options.count
        flow.update(index) { state in
            if q.multiSelect {
                state.multiSelectedIndices.insert(otherIndex)
            } else {
                state.singleSelectedIndex = otherIndex
            }
        }
        guard isQuestionAnswered(at: index) else { return }
        flow.otherEditingIndex = nil
        otherFieldFocused = false
        jumpTo(step: index + 1)
    }

    private var canSubmit: Bool {
        canInteract && allAnswered && canSubmitTransport
    }

    private func submit() {
        guard canInteract, allAnswered, canSubmitTransport, let sessionId else { return }
        // Clear the saved draft eagerly. Once submit fires, the draft is
        // dead conceptually — even if the socket round-trip fails and
        // the form has to be re-shown, restoring the half-state would
        // be wrong (it could re-submit the same answers, or render
        // `submitted=true` ghost-state). A blank form on retry is
        // correct UX.
        AskUserQuestionDraftStore.shared.clear(sessionId: sessionId)
        flow.submitted = true
        onSubmitAnswers(questions, formAnswers())
    }

    private func cancel() {
        guard let sessionId else { return }
        // Same eager-clear rationale as `submit()`. Once cancel fires
        // there's no path back to the form for these answers.
        AskUserQuestionDraftStore.shared.clear(sessionId: sessionId)
        Self.logger.info("cancel sid=\(sessionId.prefix(8), privacy: .public)")
        flow.canceled = true
        onCancel()
    }

    private func formAnswers() -> [AskUserQuestionAnswerBuilder.Answer] {
        questions.indices.map { i in
            let s = flow.state(for: i)
            return AskUserQuestionAnswerBuilder.Answer(
                singleSelected: s.singleSelectedIndex,
                multiSelected: s.multiSelectedIndices,
                otherText: s.otherText
            )
        }
    }

    // The previous AskUserQuestion submit path drove claude-code's
    // TUI by synthesizing arrow/tab/text/enter keystrokes via
    // AppleScript (`AskUserQuestionKeystrokeBuilder` in Core, then
    // `iTerm2Adapter.sendSteps` / `GhosttyScripting.sendSteps`).
    // Removed because iTerm2's `write text` bracketed-paste wrapping
    // and React/Ink mount-timing made delivery racy — the form
    // submit landed on Cancel about 1 in 5 times. The new path
    // (`submit()` above) responds to the open hook socket with
    // `behavior: 'allow' + updatedInput = {questions, answers}`,
    // which short-circuits the TUI entirely. The keystroke builder
    // and its tests stay in Core for now as a documented record of
    // the TUI navigation contract — see
    // `AskUserQuestionKeystrokeBuilderTests`.

    // MARK: - Keyboard Monitor (NSEvent)

    private func installMonitor() {
        guard canInteract, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return handleKey(event) ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Returns true if the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard canInteract else { return false }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+C — cancel the form. Handled at the top so it works
        // even while the user is typing in the Other input. Matches
        // the chat input's Ctrl+C semantics (cancel an in-flight
        // operation, see SubmittableTextView.keyDown).
        if mods == .control, event.charactersIgnoringModifiers == "c" {
            cancel()
            return true
        }

        // Escape — let it bubble to ChatView's local ESC monitor,
        // which exits the chat panel back to the notch session view.
        // The question stays pending in claude-code (no cancel sent).
        // User can re-open the chat to answer, or hit Ctrl+C inside
        // the form to actually cancel.
        if event.keyCode == 53 { return false }

        // Pass through only if the user is in an actually editable text
        // field — the Other input, the chat input below, or anywhere
        // else they're really typing. Selectable-but-read-only text
        // views (which SwiftUI focuses when you click into chat-history
        // text for selection) report `isEditable == false`, so the
        // keyboard nav keeps working after a stray click. Without this
        // guard, clicking anywhere in the chat history froze nav until
        // the user clicked back into the question form.
        //
        // Tab stays bound to form navigation even when typing in the
        // Other field — without this exception the user has to click
        // out of the field before keyboard nav works again.
        if let firstResponder = NSApp.keyWindow?.firstResponder,
           let textView = firstResponder as? NSText, textView.isEditable {
            let isFormNav = event.keyCode == 0x30 /* tab */
            if !isFormNav { return false }
        }

        // Tab / Shift+Tab — step forward/back through questions+SubmitView.
        if event.keyCode == 0x30 {
            if mods == .shift {
                if flow.currentStep > 0 { jumpTo(step: flow.currentStep - 1) }
            } else if mods.isEmpty {
                let next = flow.currentStep + 1
                if next <= questions.count {
                    // Block forward step if current question isn't answered.
                    if isOnSubmitStep || isQuestionAnswered(at: flow.currentStep) {
                        jumpTo(step: next)
                    }
                }
            }
            return true
        }

        // On the SubmitView, the only key we consume is Enter (submit).
        if isOnSubmitStep {
            if event.keyCode == 36 { submit(); return true }
            return false
        }

        let qIdx = flow.currentStep
        guard qIdx < questions.count else { return false }
        let q = questions[qIdx]
        let optionsCount = q.options.count + 1 // declared + Other

        switch event.keyCode {
        case 126: // up
            flow.update(qIdx) { $0.optionFocus = max(0, $0.optionFocus - 1) }
            return true
        case 125: // down
            flow.update(qIdx) { $0.optionFocus = min(optionsCount - 1, $0.optionFocus + 1) }
            return true
        case 36: // return
            let focused = flow.state(for: qIdx).optionFocus
            onTapOption(questionIndex: qIdx, optionIndex: focused)
            // Single-select non-Other: auto-advance to mirror claude-code.
            if !q.multiSelect && focused < q.options.count {
                jumpTo(step: qIdx + 1)
            }
            return true
        case 49: // space
            if q.multiSelect {
                let focused = flow.state(for: qIdx).optionFocus
                onTapOption(questionIndex: qIdx, optionIndex: focused)
                return true
            }
            return false
        default:
            // Digit row 1-9 → keyCodes 18-26.
            if event.keyCode >= 18, event.keyCode <= 26 {
                let digit = Int(event.keyCode) - 17
                if digit >= 1, digit <= optionsCount {
                    let optIdx = digit - 1
                    onTapOption(questionIndex: qIdx, optionIndex: optIdx)
                    if !q.multiSelect && optIdx < q.options.count {
                        jumpTo(step: qIdx + 1)
                    }
                    return true
                }
            }
            return false
        }
    }
}

/// Trailing-icon Label (text first, then chevron). SwiftUI's default
/// LabelStyle puts the icon first; flipping it for "Next →" / "Submit →"
/// reads more naturally as a forward action.
private struct ReverseIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

// MARK: - AskUserQuestion Result View

struct AskUserQuestionResultContent: View {
    let result: AskUserQuestionResult
    /// True when this view is rendered directly under a chat-history
    /// tool header that already displays the question text. The header
    /// would otherwise duplicate `question.question`, so the inline
    /// path passes `true` and the drill-down detail keeps `false`.
    var hideQuestionText: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    if !hideQuestionText {
                        Text(question.question)
                            .chatScaledFont(size: 11)
                            .foregroundColor(ChatTheme.secondary)
                    }

                    if let answer = result.answers["\(index)"] {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .chatScaledFont(size: 9)
                            Text(answer)
                                .chatScaledFont(size: 11, weight: .medium)
                        }
                        .foregroundColor(ChatTheme.statusSuccess)
                    }
                }
            }
        }
    }
}

// MARK: - BashOutput Result View

struct BashOutputResultContent: View {
    let result: BashOutputResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Status
            HStack(spacing: 6) {
                Text("Status: \(result.status)")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.secondary)

                if let exitCode = result.exitCode {
                    Text("Exit: \(exitCode)")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(exitCode == 0 ? ChatTheme.statusSuccess.opacity(0.85) : ChatTheme.statusError.opacity(0.85))
                }
            }

            // Output
            if !result.stdout.isEmpty {
                CodePreview(content: result.stdout, maxLines: 10, language: "bash")
            }

            if !result.stderr.isEmpty {
                Text(result.stderr)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.statusError)
                    .lineLimit(5)
            }
        }
    }
}

// MARK: - KillShell Result View

struct KillShellResultContent: View {
    let result: KillShellResult

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .chatScaledFont(size: 11)
                .foregroundColor(ChatTheme.statusError.opacity(0.85))

            Text(result.message.isEmpty ? "Shell \(result.shellId) terminated" : result.message)
                .chatScaledFont(size: 11, design: .monospaced)
                .foregroundColor(ChatTheme.secondary)
        }
    }
}

// MARK: - ExitPlanMode Result View

struct ExitPlanModeResultContent: View {
    let result: ExitPlanModeResult
    @State private var isExpanded = false

    /// Read plan from result or from file on disk
    private var planText: String? {
        if let plan = result.plan, !plan.isEmpty { return plan }
        // Fallback: read from file
        if let path = result.filePath {
            let expanded = path.hasPrefix("~") ? path.replacingOccurrences(of: "~", with: NSHomeDirectory()) : path
            return try? String(contentsOfFile: expanded, encoding: .utf8)
        }
        // Last resort: most recent plan file
        let plansDir = NSHomeDirectory() + "/.claude/plans"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: plansDir) {
            let sorted = files.filter { $0.hasSuffix(".md") }.sorted { a, b in
                let aDate = (try? FileManager.default.attributesOfItem(atPath: plansDir + "/" + a))?[.modificationDate] as? Date ?? .distantPast
                let bDate = (try? FileManager.default.attributesOfItem(atPath: plansDir + "/" + b))?[.modificationDate] as? Date ?? .distantPast
                return aDate > bDate
            }
            if let recent = sorted.first {
                return try? String(contentsOfFile: plansDir + "/" + recent, encoding: .utf8)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Plan file path
            if let path = result.filePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.fill")
                        .chatScaledFont(size: 10)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .chatScaledFont(size: 11, design: .monospaced)
                }
                .foregroundColor(ChatTheme.link)
            }

            // Plan content with full markdown rendering
            if let plan = planText {
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

// MARK: - MCP Result View

struct MCPResultContent: View {
    let result: MCPResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Server and tool info (formatted as Title Case)
            HStack(spacing: 4) {
                Image(systemName: "puzzlepiece")
                    .chatScaledFont(size: 10)
                Text("\(MCPToolFormatter.toTitleCase(result.serverName)) - \(MCPToolFormatter.toTitleCase(result.toolName))")
                    .chatScaledFont(size: 10, design: .monospaced)
            }
            .foregroundColor(Catppuccin.mauve.opacity(0.7))

            // Raw result (formatted as key-value pairs)
            ForEach(Array(result.rawResult.prefix(5)), id: \.key) { key, value in
                HStack(alignment: .top, spacing: 4) {
                    Text("\(key):")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                    Text("\(String(describing: value).prefix(100))")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Generic Result View

struct GenericResultContent: View {
    let result: GenericResult

    var body: some View {
        if let content = result.rawContent, !content.isEmpty {
            GenericTextContent(text: content)
        } else {
            Text("Completed")
                .chatScaledFont(size: 11, design: .monospaced)
                .foregroundColor(ChatTheme.tertiary)
        }
    }
}

struct GenericTextContent: View {
    let text: String

    var body: some View {
        Text(text)
            .chatScaledFont(size: 11, design: .monospaced)
            .foregroundColor(ChatTheme.secondary)
            .lineLimit(15)
    }
}

// MARK: - Helper Views

/// Convert a Highlightr `NSAttributedString` into a SwiftUI `AttributedString`
/// that carries only foreground colors. Highlightr bakes an `NSFont` reference
/// into every run; the default `AttributedString(ns)` bridge preserves it,
/// which forces SwiftUI's text path to measure through AppKit. AppKit's line
/// metrics differ subtly from SwiftUI's native path, and the discrepancy adds
/// up in a flipped LazyVStack chat as phantom intrinsic height (the chronic
/// gap regression). Stripping fonts and paragraph styles here keeps the
/// rendering pipeline pure SwiftUI from this point on. Callers supply the
/// font via `.font(.system(size:design:.monospaced))` on the `Text` view.
func swiftUIAttributedFromHighlighted(_ ns: NSAttributedString) -> AttributedString {
    var out = AttributedString()
    let full = NSRange(location: 0, length: ns.length)
    let nsString = ns.string as NSString
    var cursor = 0
    while cursor < ns.length {
        var effective = NSRange(location: cursor, length: 0)
        let color = ns.attribute(.foregroundColor, at: cursor, longestEffectiveRange: &effective, in: full) as? NSColor
        guard effective.length > 0 else { break }
        let runText = nsString.substring(with: effective)
        var part = AttributedString(runText)
        if let color {
            part.foregroundColor = Color(nsColor: color)
        }
        out.append(part)
        cursor = effective.location + effective.length
    }
    return out
}

/// Pre-compute per-line `AttributedString`s for `content`. When a `language`
/// is supplied, runs a single Highlightr pass over the full content and
/// slices the result by line so multi-line tokens stay continuously colored.
/// Falls back to plain attributed strings tinted with `defaultColor` when no
/// language is given or Highlightr declines to highlight.
func highlightedLines(content: String, language: String?, defaultColor: Color) -> [AttributedString] {
    let rawLines = content.components(separatedBy: "\n")
    let highlighted: NSAttributedString? = {
        guard let language else { return nil }
        return SyntaxHighlighterCache.shared.highlight(code: content, language: language)
    }()

    var out: [AttributedString] = []
    var cursor = 0
    for line in rawLines {
        let len = (line as NSString).length
        if let highlighted, cursor + len <= highlighted.length {
            let slice = highlighted.attributedSubstring(from: NSRange(location: cursor, length: len))
            // Empty highlighted lines collapse to zero-height; substitute a
            // single space so each line still occupies a row in the stack.
            if line.isEmpty {
                var s = AttributedString(" ")
                s.foregroundColor = defaultColor
                out.append(s)
            } else {
                out.append(swiftUIAttributedFromHighlighted(slice))
            }
            cursor += len + 1 // joining \n
        } else {
            var s = AttributedString(line.isEmpty ? " " : line)
            s.foregroundColor = defaultColor
            out.append(s)
        }
    }
    return out
}

/// File code view with filename header and line numbers (matches Edit tool styling)
struct FileCodeView: View {
    /// Filename header rendered above the code block. Pass `nil` to
    /// suppress the strip — useful inline under a tool-call row that
    /// already names the file (avoids the redundant duplicate label
    /// in the code box).
    let filename: String?
    let content: String
    let startLine: Int
    let totalLines: Int
    let maxLines: Int
    /// Highlightr language id used to syntax-color content lines. When nil,
    /// renders plain monospace text. Use `syntaxLanguage(for: filePath)` to
    /// derive from the file extension at the call site.
    var language: String? = nil
    /// When non-nil, the bottom "... (N more lines)" overflow indicator
    /// becomes a clickable button that calls this closure (used to open the
    /// drill-down detail view). When nil, it stays a static label.
    var onOverflowTap: (() -> Void)? = nil

    @State private var isHoveringOverflow = false

    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    private var displayLines: [AttributedString] {
        let all = highlightedLines(content: content, language: language, defaultColor: ChatTheme.primary)
        return Array(all.prefix(maxLines))
    }

    private var hasMoreAfter: Bool {
        lines.count > maxLines
    }

    private var hasLinesBefore: Bool {
        startLine > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header — suppressed when caller passes nil
            // (e.g. inline previews under a tool-call row that already
            // names the file).
            if let filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.tertiary)
                    Text(filename)
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(ChatTheme.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ChatTheme.cardBg)
                .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight]))
            }

            // Top overflow indicator. When the filename header is
            // suppressed AND we're showing the "lines before" hint,
            // round the top corners so the card doesn't have a flat
            // edge butting against the row above.
            if hasLinesBefore {
                Text("...")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(ChatTheme.cardBg)
                    .clipShape(RoundedCorner(
                        radius: 6,
                        corners: filename == nil ? [.topLeft, .topRight] : []
                    ))
            }

            // Code lines with line numbers
            ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                let lineNumber = startLine + index
                let isFirst = index == 0
                let isLast = index == displayLines.count - 1 && !hasMoreAfter
                // Round the TOP corners of the very first code line
                // when we have neither a filename header nor a "lines
                // before" overflow indicator above it.
                let needsTopRound = isFirst && filename == nil && !hasLinesBefore
                CodeLineView(
                    content: line,
                    lineNumber: lineNumber,
                    isFirst: needsTopRound,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator. When a tap handler is wired the
            // label becomes a button so users can click the "more lines"
            // text directly to expand. Brightens on hover for discoverability.
            if hasMoreAfter {
                let label = "... (\(lines.count - maxLines) more lines, click to expand)"
                if let onOverflowTap {
                    Button(action: onOverflowTap) {
                        Text(label)
                            .chatScaledFont(size: 10, design: .monospaced)
                            .foregroundColor(isHoveringOverflow ? ChatTheme.secondary : ChatTheme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.leading, 46)
                            .padding(.vertical, 3)
                            .background(ChatTheme.cardBg)
                            .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringOverflow = $0 }
                } else {
                    Text("... (\(lines.count - maxLines) more lines)")
                        .chatScaledFont(size: 10, design: .monospaced)
                        .foregroundColor(ChatTheme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 46)
                        .padding(.vertical, 3)
                        .background(ChatTheme.cardBg)
                        .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight]))
                }
            }
        }
    }

    private struct CodeLineView: View {
        let content: AttributedString
        let lineNumber: Int
        var isFirst: Bool = false
        let isLast: Bool

        private var roundedCorners: RoundedCorner.RectCorner {
            var corners: RoundedCorner.RectCorner = []
            if isFirst { corners.insert([.topLeft, .topRight]) }
            if isLast { corners.insert([.bottomLeft, .bottomRight]) }
            return corners
        }

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 8)

                // Line content. AttributedString carries Highlightr's per-token
                // colors (or the default tint when no language is set), so the
                // surrounding `.foregroundColor` modifier is intentionally omitted.
                Text(content)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(ChatTheme.cardBg)
            .clipShape(RoundedCorner(radius: 6, corners: roundedCorners))
        }
    }
}

struct CodePreview: View {
    let content: String
    let maxLines: Int
    /// Highlightr language id used to syntax-color content lines. Pass
    /// `"bash"` for shell stdout, `syntaxLanguage(for: filePath)` for file
    /// content, or nil for plain monospace.
    var language: String? = nil

    var body: some View {
        let attributed = highlightedLines(content: content, language: language, defaultColor: ChatTheme.secondary)
        let displayLines = Array(attributed.prefix(maxLines))
        let hasMore = attributed.count > maxLines

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .chatScaledFont(size: 11, design: .monospaced)
            }

            if hasMore {
                Text("... (\(attributed.count - maxLines) more lines)")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .padding(.top, 2)
            }
        }
    }
}

struct FileListView: View {
    let files: [String]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(files.prefix(limit).enumerated()), id: \.offset) { _, file in
                HStack(spacing: 4) {
                    Image(systemName: "doc")
                        .chatScaledFont(size: 9)
                        .foregroundColor(ChatTheme.tertiary)
                    Text(URL(fileURLWithPath: file).lastPathComponent)
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(ChatTheme.secondary)
                        .lineLimit(1)
                }
            }

            if files.count > limit {
                Text("... and \(files.count - limit) more files")
                    .chatScaledFont(size: 10)
                    .foregroundColor(ChatTheme.tertiary)
            }
        }
    }
}

/// Renders a unified diff with absolute line numbers and context lines.
/// Each row is its own `HStack { gutter, prefix, content }` so wrapping
/// inside a long content line stays inside the content column instead of
/// sliding back to the card's left edge. The whole row gets a single
/// `.background()` so wrapped continuations also pick up the red/green
/// tint. Single-pass syntax highlighter still runs on the full joined
/// source so multi-line tokens (triple-quoted strings, multi-line
/// comments) keep continuous coloring across rows; per-row rendering just
/// slices the result.
struct DiffView: View {
    let patches: [PatchHunk]
    var filename: String? = nil
    var filePath: String? = nil
    /// When non-nil, render at most this many diff rows. Used to keep
    /// inline previews from blowing up the message height. Drill-down
    /// passes nil to render the full diff.
    var maxRows: Int? = nil
    /// When non-nil and `maxRows` truncation drops at least one row, the
    /// "… and N more changes" line below the diff becomes a clickable
    /// button that calls this closure.
    var onOverflowTap: (() -> Void)? = nil
    /// When non-nil, an expand glyph appears on the filename header row.
    /// Used by the pending-Edit chat row to open the to-be-edited file in
    /// a full-panel reader.
    var onExpand: (() -> Void)? = nil

    @State private var isHoveringOverflow = false
    @State private var isHoveringExpand = false

    private var language: String? { syntaxLanguage(for: filePath) }

    var body: some View {
        let processed = processedRows()
        let gutterWidth = computeGutterWidth(rows: processed.rows)
        let prepared = prepareRows(processed.rows)

        VStack(alignment: .leading, spacing: 0) {
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.tertiary)
                    Text(name)
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(ChatTheme.primary)
                    Spacer(minLength: 0)
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .chatScaledFont(size: 10, weight: .medium)
                                .foregroundColor(isHoveringExpand ? ChatTheme.secondary : ChatTheme.tertiary)
                                .frame(width: 22, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringExpand = $0 }
                        .help("Show the whole file (esc to close)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ChatTheme.cardBg)
            }

            // Per-row HStack layout. Wrapping a long content line keeps the
            // wrapped portion inside the content column. Plain VStack rather
            // than LazyVStack — LazyVStack inside a non-scrolling container
            // expands to fill available space and reserves phantom height
            // above/below the diff card. Inline previews are capped at 12
            // rows so eager realization is cheap; drill-down's outer
            // ScrollView already provides lazy windowing at the message-list
            // level.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(prepared.enumerated()), id: \.offset) { _, item in
                    diffRowView(item, gutterWidth: gutterWidth)
                }

                // Inline overflow appended as a sentinel row inside the
                // diff stack when no external handler is provided. With a
                // handler, the clickable button below takes over.
                if onOverflowTap == nil, processed.overflowCount > 0 {
                    overflowSentinelView(count: processed.overflowCount, gutterWidth: gutterWidth)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if let onOverflowTap, processed.overflowCount > 0 {
                let count = processed.overflowCount
                Button(action: onOverflowTap) {
                    Text("… and \(count) more change\(count == 1 ? "" : "s"), click to expand")
                        .chatScaledFont(size: 11, design: .monospaced)
                        .foregroundColor(isHoveringOverflow ? ChatTheme.secondary : ChatTheme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .onHover { isHoveringOverflow = $0 }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ChatTheme.cardBg.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ChatTheme.inputBorder.opacity(0.4), lineWidth: 1)
                )
        )
    }

    /// One rendered row: gutter + prefix + content, all sharing the row's
    /// tint via a single `.background` on the HStack so wrapped
    /// continuations of the content column also pick it up.
    @ViewBuilder
    private func diffRowView(_ item: PreparedRow, gutterWidth: Int) -> some View {
        if item.row.lineNumber == -1 {
            // Hunk separator
            Text(String(repeating: " ", count: gutterWidth) + "  …")
                .chatScaledFont(size: 11, design: .monospaced)
                .foregroundColor(ChatTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top, spacing: 0) {
                // Gutter (line number + trailing space)
                Text(String(format: "%\(gutterWidth)d ", item.row.lineNumber))
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)

                // Prefix column (+, -, or two spaces)
                Text(prefixString(for: item.row.type))
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(prefixColor(for: item.row.type))

                // Content column. Takes remaining width and wraps inside
                // its own column. The intrinsic height grows with the
                // wrapped line count via fixedSize(vertical: true).
                Text(item.content)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .background(item.row.type.backgroundColor)
        }
    }

    private func overflowSentinelView(count: Int, gutterWidth: Int) -> some View {
        Text(String(repeating: " ", count: gutterWidth) + "  … and \(count) more change\(count == 1 ? "" : "s")")
            .chatScaledFont(size: 11, design: .monospaced)
            .foregroundColor(ChatTheme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func prefixString(for type: DiffLineType) -> String {
        switch type {
        case .added: return "+ "
        case .removed: return "- "
        case .context: return "  "
        }
    }

    private func prefixColor(for type: DiffLineType) -> Color {
        switch type {
        case .added: return ChatTheme.statusSuccess
        case .removed: return ChatTheme.statusError
        case .context: return ChatTheme.secondary
        }
    }

    private func computeGutterWidth(rows: [DiffRow]) -> Int {
        let widestNum = rows.map { $0.lineNumber > 0 ? $0.lineNumber : 0 }.max() ?? 0
        return max(3, String(widestNum).count)
    }

    /// Pre-computes each row's content `AttributedString`. Runs a single
    /// Highlightr pass over the joined source, then slices the result per
    /// row so multi-line tokens stay continuously colored. Falls back to
    /// plain text colored by row type when no language is detected. Then
    /// runs a second pass that paints intra-line word-change highlights
    /// on adjacent removed/added pairs so a one-word edit (e.g.
    /// `system` → `service`) shows up as a strong red/green span instead
    /// of two near-identical full-line tints.
    private func prepareRows(_ rows: [DiffRow]) -> [PreparedRow] {
        let highlightSource = rows.compactMap { $0.lineNumber < 0 ? nil : $0.text }
            .joined(separator: "\n")
        let highlighted: NSAttributedString? = {
            guard let language else { return nil }
            return SyntaxHighlighterCache.shared.highlight(code: highlightSource, language: language)
        }()

        var prepared: [PreparedRow] = []
        var cursor = 0
        for row in rows {
            if row.lineNumber < 0 {
                prepared.append(PreparedRow(row: row, content: AttributedString(row.text)))
                continue
            }
            let lineLen = (row.text as NSString).length
            let content: AttributedString
            if let highlighted, cursor + lineLen <= highlighted.length {
                let slice = highlighted.attributedSubstring(
                    from: NSRange(location: cursor, length: lineLen)
                )
                content = swiftUIAttributedFromHighlighted(slice)
                cursor += lineLen + 1 // +1 for the joining \n
            } else {
                var s = AttributedString(row.text)
                s.foregroundColor = row.type.textColor
                content = s
            }
            prepared.append(PreparedRow(row: row, content: content))
        }

        // Pass 2: intra-line diff highlighting. Only fires for true
        // in-place edits — exactly one removed line immediately followed
        // by exactly one added line, AND the changed span covers ≤60%
        // of either side. Larger asymmetric blocks (5 removed → 4 added,
        // etc.) skip this pass entirely; pairing the last removed with
        // the first added in those cases produced an ugly full-line
        // bold-and-tinted slab on the boundary row, which read as
        // "agent-visor thinks every character changed" when really
        // those two lines just had nothing to do with each other. The
        // 60% coverage cap catches the same failure mode for 1:1 pairs
        // that happen to be near-rewrites of each other.
        var i = 0
        while i < prepared.count {
            guard prepared[i].row.type == .removed else { i += 1; continue }
            var removedEnd = i
            while removedEnd < prepared.count && prepared[removedEnd].row.type == .removed {
                removedEnd += 1
            }
            var addedEnd = removedEnd
            while addedEnd < prepared.count && prepared[addedEnd].row.type == .added {
                addedEnd += 1
            }
            let removedCount = removedEnd - i
            let addedCount = addedEnd - removedEnd
            defer { i = max(addedEnd, i + 1) }
            guard removedCount == 1, addedCount == 1 else { continue }

            let removedIdx = i
            let addedIdx = removedEnd
            let oldText = prepared[removedIdx].row.text
            let newText = prepared[addedIdx].row.text
            let (oldRange, newRange) = intraLineDiffRanges(old: oldText, new: newText)
            let oldLen = (oldText as NSString).length
            let newLen = (newText as NSString).length
            let oldCoverage = oldLen > 0 ? Double(oldRange.length) / Double(oldLen) : 0
            let newCoverage = newLen > 0 ? Double(newRange.length) / Double(newLen) : 0
            guard oldCoverage <= 0.6, newCoverage <= 0.6 else { continue }

            if oldRange.length > 0 {
                var attr = prepared[removedIdx].content
                applyIntraLineHighlight(&attr, range: oldRange, color: ChatTheme.statusError)
                prepared[removedIdx] = PreparedRow(row: prepared[removedIdx].row, content: attr)
            }
            if newRange.length > 0 {
                var attr = prepared[addedIdx].content
                applyIntraLineHighlight(&attr, range: newRange, color: ChatTheme.statusSuccess)
                prepared[addedIdx] = PreparedRow(row: prepared[addedIdx].row, content: attr)
            }
        }
        return prepared
    }

    /// NSRange (UTF-16-indexed) of the characters that differ between
    /// `old` and `new`. Computed by stripping the longest common prefix
    /// and the longest common suffix; the middle is what changed. For
    /// `running system` vs `running service` this returns spans over
    /// `ystem` and `ervice` respectively. When one line fully contains
    /// the other (pure insertion or deletion) the corresponding range
    /// has length 0 and the call site skips the highlight pass.
    private func intraLineDiffRanges(old: String, new: String) -> (NSRange, NSRange) {
        let oldNS = old as NSString
        let newNS = new as NSString
        let oldLen = oldNS.length
        let newLen = newNS.length
        var prefix = 0
        let maxPrefix = min(oldLen, newLen)
        while prefix < maxPrefix && oldNS.character(at: prefix) == newNS.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLen - prefix
            && suffix < newLen - prefix
            && oldNS.character(at: oldLen - 1 - suffix) == newNS.character(at: newLen - 1 - suffix) {
            suffix += 1
        }
        return (
            NSRange(location: prefix, length: oldLen - prefix - suffix),
            NSRange(location: prefix, length: newLen - prefix - suffix)
        )
    }

    /// Paint a subtle background tint on `nsRange` of an existing
    /// AttributedString. No underline (Text.LineStyle is unbroken solid
    /// and cuts through descenders like `g`/`p`/`y`/`j`/`q`, which is a
    /// real typography problem and can't be skipped without
    /// `text-decoration-skip-ink`-style support that SwiftUI doesn't
    /// expose). No bold, no foreground override — the changed span
    /// reads as "same hue as the row tint, slightly more saturated."
    /// 0.21 alpha lands subtly above the 0.15 row-level tint without
    /// dominating bright syntax-highlighted code or compounding when
    /// the same edited identifier appears multiple times on one line.
    private func applyIntraLineHighlight(
        _ attr: inout AttributedString,
        range nsRange: NSRange,
        color: Color
    ) {
        guard nsRange.length > 0 else { return }
        let str = String(attr.characters)
        guard let strRange = Range(nsRange, in: str) else { return }
        let lowerOffset = str.distance(from: str.startIndex, to: strRange.lowerBound)
        let upperOffset = str.distance(from: str.startIndex, to: strRange.upperBound)
        let chars = attr.characters
        guard lowerOffset >= 0, upperOffset >= lowerOffset,
              upperOffset <= chars.count else { return }
        let lower = chars.index(chars.startIndex, offsetBy: lowerOffset)
        let upper = chars.index(chars.startIndex, offsetBy: upperOffset)
        attr[lower..<upper].backgroundColor = color.opacity(0.21)
    }

    /// Build the row list and figure out how many were dropped by truncation.
    /// Separated out so the body can decide whether to render an inline
    /// sentinel inside the diff text or a separate clickable button below.
    private func processedRows() -> (rows: [DiffRow], overflowCount: Int) {
        var allRows: [DiffRow] = []
        for (idx, patch) in patches.enumerated() {
            allRows.append(contentsOf: numberedRows(for: patch))
            if idx < patches.count - 1 {
                allRows.append(DiffRow(lineNumber: -1, text: "", type: .context))
            }
        }
        guard let cap = maxRows else { return (allRows, 0) }
        let realCount = allRows.filter { $0.lineNumber >= 0 }.count
        guard realCount > cap else { return (allRows, 0) }
        var keep: [DiffRow] = []
        var realKept = 0
        for row in allRows {
            if realKept >= cap && row.lineNumber >= 0 { break }
            keep.append(row)
            if row.lineNumber >= 0 { realKept += 1 }
        }
        while let last = keep.last, last.lineNumber == -1 { keep.removeLast() }
        return (keep, realCount - realKept)
    }

    /// Walks a hunk's lines and assigns the correct absolute line number to
    /// each row. Removed rows take the next old-side number; added and
    /// context rows take the next new-side number — matches how Ghostty's
    /// TUI displays the gutter (a context line after additions reads as
    /// its new-file row, not its pre-edit row).
    private func numberedRows(for patch: PatchHunk) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldNum = patch.oldStart
        var newNum = patch.newStart
        for line in patch.lines {
            if line.hasPrefix("+") {
                rows.append(DiffRow(lineNumber: newNum, text: String(line.dropFirst()), type: .added))
                newNum += 1
            } else if line.hasPrefix("-") {
                rows.append(DiffRow(lineNumber: oldNum, text: String(line.dropFirst()), type: .removed))
                oldNum += 1
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(DiffRow(lineNumber: newNum, text: text, type: .context))
                oldNum += 1
                newNum += 1
            }
        }
        return rows
    }

}

private struct PreparedRow {
    let row: DiffRow
    let content: AttributedString
}

private struct DiffRow {
    let lineNumber: Int
    let text: String
    let type: DiffLineType
}

enum DiffLineType {
    case added
    case removed
    case context

    var textColor: Color {
        switch self {
        case .added: return ChatTheme.statusSuccess
        case .removed: return ChatTheme.statusError
        case .context: return ChatTheme.secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .added: return ChatTheme.statusSuccess.opacity(0.15)
        case .removed: return ChatTheme.statusError.opacity(0.15)
        case .context: return .clear
        }
    }
}

struct SimpleDiffView: View {
    let oldString: String
    let newString: String
    var filename: String? = nil
    /// When non-nil, an expand glyph appears on the filename header row. The
    /// caller wires this to a closure that opens the to-be-edited file in a
    /// full-panel reader. Kept as a closure so SimpleDiffView itself stays
    /// ignorant of PendingEditContext and ChatPresentationState.
    var onExpand: (() -> Void)? = nil

    @State private var isHoveringExpand = false

    /// Compute diff using LCS algorithm
    private var diffLines: [DiffLine] {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")

        // Compute LCS to find matching lines
        let lcs = computeLCS(oldLines, newLines)

        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0
        var lcsIdx = 0

        while oldIdx < oldLines.count || newIdx < newLines.count {
            // Limit output
            if result.count >= 12 { break }

            let lcsLine = lcsIdx < lcs.count ? lcs[lcsIdx] : nil

            if oldIdx < oldLines.count && (lcsLine == nil || oldLines[oldIdx] != lcsLine) {
                // Line in old but not in LCS - removed
                result.append(DiffLine(text: oldLines[oldIdx], type: .removed, lineNumber: oldIdx + 1))
                oldIdx += 1
            } else if newIdx < newLines.count && (lcsLine == nil || newLines[newIdx] != lcsLine) {
                // Line in new but not in LCS - added
                result.append(DiffLine(text: newLines[newIdx], type: .added, lineNumber: newIdx + 1))
                newIdx += 1
            } else {
                // Matching line in LCS - skip (context)
                oldIdx += 1
                newIdx += 1
                lcsIdx += 1
            }
        }

        return result
    }

    /// Compute Longest Common Subsequence of two string arrays
    private func computeLCS(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count

        // DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find LCS
        var lcs: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return lcs.reversed()
    }

    private var hasMoreChanges: Bool {
        let oldLines = oldString.components(separatedBy: "\n")
        let newLines = newString.components(separatedBy: "\n")
        let lcs = computeLCS(oldLines, newLines)
        let totalChanges = (oldLines.count - lcs.count) + (newLines.count - lcs.count)
        return totalChanges > 12
    }

    /// Whether there are lines before the first diff line
    private var hasLinesBefore: Bool {
        guard let firstLine = diffLines.first else { return false }
        return firstLine.lineNumber > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Filename header
            if let name = filename {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .chatScaledFont(size: 10)
                        .foregroundColor(ChatTheme.tertiary)
                    Text(name)
                        .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundColor(ChatTheme.primary)
                    Spacer(minLength: 0)
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .chatScaledFont(size: 10, weight: .medium)
                                .foregroundColor(isHoveringExpand ? ChatTheme.secondary : ChatTheme.tertiary)
                                .frame(width: 22, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringExpand = $0 }
                        .help("Show the whole file (esc to close)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(ChatTheme.cardBg)
                .clipShape(RoundedCorner(radius: 6, corners: [.topLeft, .topRight] as RoundedCorner.RectCorner))
            }

            // Top overflow indicator
            if hasLinesBefore {
                Text("...")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(ChatTheme.cardBg)
                    .clipShape(RoundedCorner(radius: 6, corners: filename == nil ? [.topLeft, .topRight] as RoundedCorner.RectCorner : [] as RoundedCorner.RectCorner))
            }

            // Diff lines
            ForEach(Array(diffLines.enumerated()), id: \.offset) { index, line in
                let isFirst = index == 0 && filename == nil && !hasLinesBefore
                let isLast = index == diffLines.count - 1 && !hasMoreChanges
                DiffLineView(
                    line: line.text,
                    type: line.type,
                    lineNumber: line.lineNumber,
                    isFirst: isFirst,
                    isLast: isLast
                )
            }

            // Bottom overflow indicator
            if hasMoreChanges {
                Text("...")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(ChatTheme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 46)
                    .padding(.vertical, 3)
                    .background(ChatTheme.cardBg)
                    .clipShape(RoundedCorner(radius: 6, corners: [.bottomLeft, .bottomRight] as RoundedCorner.RectCorner))
            }
        }
    }

    private struct DiffLine {
        let text: String
        let type: DiffLineType
        let lineNumber: Int
    }

    private struct DiffLineView: View {
        let line: String
        let type: DiffLineType
        let lineNumber: Int
        let isFirst: Bool
        let isLast: Bool

        private var corners: RoundedCorner.RectCorner {
            if isFirst && isLast {
                return .allCorners
            } else if isFirst {
                return [.topLeft, .topRight]
            } else if isLast {
                return [.bottomLeft, .bottomRight]
            }
            return []
        }

        var body: some View {
            HStack(spacing: 0) {
                // Line number
                Text("\(lineNumber)")
                    .chatScaledFont(size: 10, design: .monospaced)
                    .foregroundColor(type.textColor.opacity(0.6))
                    .frame(width: 28, alignment: .trailing)
                    .padding(.trailing, 4)

                // +/- indicator
                Text(type == .added ? "+" : "-")
                    .chatScaledFont(size: 11, weight: .medium, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .frame(width: 14)

                // Line content
                Text(line.isEmpty ? " " : line)
                    .chatScaledFont(size: 11, design: .monospaced)
                    .foregroundColor(type.textColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(type.backgroundColor)
            .clipShape(RoundedCorner(radius: 6, corners: corners))
        }
    }
}

// Helper for selective corner rounding (macOS compatible)
struct RoundedCorner: Shape {
    var radius: CGFloat
    var corners: RectCorner

    struct RectCorner: OptionSet {
        let rawValue: Int
        static let topLeft = RectCorner(rawValue: 1 << 0)
        static let topRight = RectCorner(rawValue: 1 << 1)
        static let bottomLeft = RectCorner(rawValue: 1 << 2)
        static let bottomRight = RectCorner(rawValue: 1 << 3)
        static let allCorners: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let tl = corners.contains(.topLeft) ? radius : 0
        let tr = corners.contains(.topRight) ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                       radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                       radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                       radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        }
        path.closeSubpath()

        return path
    }
}
