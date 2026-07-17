import AppKit
import AgentVisorCore
import SwiftUI

enum SessionWorkspaceMode {
    case brief
    case transcript
}

private enum SessionInspectorTheme {
    static var canvas: Color { Catppuccin.mantle }
    static var card: Color { Catppuccin.base }
    static var cardBorder: Color { Catppuccin.surface0 }
}

struct SessionWorkspaceDetail: View {
    let sessionId: String
    @StateObject private var model: ChatViewHostModel
    @State private var mode: SessionWorkspaceMode = .brief

    init(sessionId: String) {
        self.sessionId = sessionId
        _model = StateObject(wrappedValue: ChatViewHostModel(sessionId: sessionId))
    }

    var body: some View {
        Group {
            if let session = model.session {
                switch mode {
                case .brief:
                    SessionBriefView(session: session) {
                        mode = .transcript
                    }
                case .transcript:
                    SessionTranscriptView(
                        session: session,
                        onShowBrief: { mode = .brief }
                    )
                }
            } else {
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "rectangle.slash",
                    description: Text("This session is no longer in the recent workspace.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SessionInspectorTheme.canvas)
    }
}

struct HistoricalSessionInspector: View {
    let item: SessionBrowserItem
    let onOpen: () -> Void

    var body: some View {
        ZStack {
            SessionInspectorTheme.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    InspectorCard(title: "Saved session", tint: Catppuccin.overlay) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(ChatTheme.tertiary)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(ChatTheme.cardBorder.opacity(0.55)))
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Outside the live status window")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(ChatTheme.primary)
                                Text("Agent Visor keeps this thread searchable, but Codex remains the source of truth for its conversation and current state.")
                                    .font(.system(size: 12))
                                    .foregroundColor(ChatTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    InspectorCard(title: "Session context", tint: Catppuccin.lavender) {
                        VStack(spacing: 10) {
                            contextRow(label: "Owner", value: item.ownerName)
                            contextRow(label: "Project", value: item.projectName)
                            contextRow(label: "Path", value: displayPath(item.cwd), monospaced: true)
                            contextRow(label: "Updated", value: updatedText)
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .dimmedScroller()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            AgentBrandLogo(agent: item.agentID, size: 38)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    InspectorChip(text: item.sourceName, tint: AgentBrand.tint(for: item.agentID))
                    InspectorChip(text: item.projectName, tint: Catppuccin.lavender)
                }
            }
            Spacer(minLength: 20)
            Button(action: onOpen) {
                Label("Open in \(item.ownerName)", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ChatTheme.link)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private func contextRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundColor(ChatTheme.secondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var updatedText: String {
        RelativeTimestampFormatter.format(since: item.sortDate).map { "\($0) ago" } ?? "Recently"
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

private struct SessionBriefView: View {
    let session: SessionState
    let onInspectTranscript: () -> Void

    private var presentation: SessionInspectorPresentation {
        SessionInspectorPolicy.presentation(
            phase: inspectorPhase,
            ownerDisplayName: ownerDisplayName,
            canOpenOriginal: canOpenOriginal,
            canInspectTranscript: true,
            canHandleAttention: canHandleAttention
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                if let permission = session.activePermission {
                    attentionCard(permission)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        latestActivityCard
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        sessionContextCard
                            .frame(width: 320, alignment: .topLeading)
                    }
                    VStack(spacing: 16) {
                        latestActivityCard
                        sessionContextCard
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .dimmedScroller()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AgentBrandLogo(agent: session.agentID, size: 36)
            VStack(alignment: .leading, spacing: 8) {
                Text(session.displayTitle)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    InspectorChip(text: agentDisplayName, tint: AgentBrand.tint(for: session.agentID))
                    InspectorChip(text: session.bestProjectName, tint: Catppuccin.lavender)
                    if ownerDisplayName != agentDisplayName {
                        InspectorChip(text: ownerDisplayName, tint: Catppuccin.sky)
                    }
                }
            }
            Spacer(minLength: 20)
            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if let secondary = presentation.secondaryAction {
                InspectorActionButton(
                    action: secondary,
                    prominent: false,
                    tint: actionTint(for: secondary.action),
                    perform: perform
                )
            }
            if let primary = presentation.primaryAction {
                InspectorActionButton(
                    action: primary,
                    prominent: true,
                    tint: actionTint(for: primary.action),
                    perform: perform
                )
            }
        }
    }

    private var statusCard: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            statusCardContent(now: context.date)
        }
    }

    private func statusCardContent(now: Date) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: statusSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(statusTint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                Text(presentation.statusDetail)
                    .font(.system(size: 12))
                    .foregroundColor(ChatTheme.secondary)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 4) {
                Text(freshnessText(now: now))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ChatTheme.secondary)
                Text(evidenceText)
                    .font(.system(size: 10))
                    .foregroundColor(ChatTheme.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(cardBackground(tint: statusTint))
    }

    private func attentionCard(_ permission: PermissionContext) -> some View {
        InspectorCard(title: "Waiting on you", tint: Catppuccin.yellow) {
            VStack(alignment: .leading, spacing: 7) {
                let toolName = PendingActionPresentation.contextualToolName(permission.toolName)
                Text(toolName == "AskUserQuestion"
                     ? "Question from the agent"
                     : toolName ?? PendingActionPresentation.genericToolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                if let input = permission.formattedInput, !input.isEmpty {
                    Text(input)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(ChatTheme.secondary)
                        .lineLimit(5)
                } else {
                    Text("Open the request to review and respond.")
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.secondary)
                }
            }
        }
    }

    private var latestActivityCard: some View {
        InspectorCard(title: "Latest activity", tint: Catppuccin.blue) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: activitySymbol)
                    Text(activityLabel)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ChatTheme.tertiary)

                Text(latestActivityAttributed)
                    .font(.system(size: 14))
                    .foregroundColor(ChatTheme.primary)
                    .lineSpacing(3)
                    .lineLimit(10)
                    .textSelection(.enabled)

                if let first = session.firstUserMessage,
                   normalized(first) != normalized(latestActivityText) {
                    Divider().overlay(SessionInspectorTheme.cardBorder)
                    Text("Started with")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(ChatTheme.tertiary)
                    Text(attributedExcerpt(first))
                        .font(.system(size: 12))
                        .foregroundColor(ChatTheme.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    private var sessionContextCard: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            InspectorCard(title: "Session context", tint: Catppuccin.lavender) {
                VStack(spacing: 10) {
                    contextRow(label: "Owner", value: ownerDisplayName)
                    contextRow(label: "Project", value: session.bestProjectName)
                    contextRow(label: "Path", value: displayPath(session.cwd), monospaced: true)
                    if let model = session.modelName, !model.isEmpty {
                        contextRow(label: "Model", value: model)
                    }
                    if let tool = session.lastToolName, !tool.isEmpty {
                        contextRow(label: "Last tool", value: tool)
                    }
                    contextRow(label: "Updated", value: activityAgeText(now: context.date))
                }
            }
        }
    }

    private func contextRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(ChatTheme.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundColor(ChatTheme.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func perform(_ action: SessionInspectorAction) {
        switch action {
        case .openOriginal:
            SessionNavigationRecencyStore.shared.record(session)
            SessionNavigator.navigateToSession(session)
        case .inspectTranscript:
            onInspectTranscript()
        }
    }

    private var inspectorPhase: SessionInspectorPhase {
        switch session.phase {
        case .waitingForApproval: return .needsAttention
        case .waitingForInput: return .ready
        case .processing: return .working
        case .compacting: return .compacting
        case .idle: return .recent
        case .ended: return .ended
        }
    }

    private var canOpenOriginal: Bool {
        session.phase != .ended && session.origin != .visorSpawned
    }

    private var canHandleAttention: Bool {
        guard session.phase.isWaitingForApproval else { return false }
        if session.agentID == .claudeCode { return true }
        return session.agentID == .codex && session.codexControlCapability != .observed
    }

    private var ownerDisplayName: String {
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

    private var agentDisplayName: String {
        switch session.agentID {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .auggie: return "Auggie"
        }
    }

    private var statusTint: Color {
        sessionStatusColor(for: session.phase, idleAge: session.statusIdleAge)
    }

    private var statusSymbol: String {
        switch session.phase {
        case .waitingForApproval: return "exclamationmark.bubble.fill"
        case .waitingForInput: return "checkmark.circle.fill"
        case .processing: return "waveform.path"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .idle: return "clock"
        case .ended: return "stop.circle"
        }
    }

    private var latestActivityText: String {
        if let message = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        if let summary = session.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        if let tool = session.lastToolName, !tool.isEmpty {
            if session.phase == .processing || session.phase == .compacting {
                return "Running \(tool)."
            }
            return "\(tool) was the latest tool used."
        }
        return "No activity summary is available yet."
    }

    private var latestActivityAttributed: AttributedString {
        attributedExcerpt(latestActivityText)
    }

    private func attributedExcerpt(_ source: String) -> AttributedString {
        SessionActivityExcerptFormatter.attributedText(source)
    }

    private var activityLabel: String {
        switch session.lastMessageRole {
        case "user": return "Latest request"
        case "assistant": return "Latest result"
        case "tool": return "Latest tool activity"
        default: return "Session activity"
        }
    }

    private var activitySymbol: String {
        switch session.lastMessageRole {
        case "user": return "person.fill"
        case "assistant": return "sparkles"
        case "tool": return "hammer.fill"
        default: return "text.bubble"
        }
    }

    private func activityAgeText(now: Date) -> String {
        let conversationalDate = SidebarRecency.sortDate(
            lastActivityDate: session.lastActivityDate,
            lastUserMessageDate: session.lastUserMessageDate,
            lastActivity: session.lastActivity
        )
        let date = max(conversationalDate, session.phaseObservedAt ?? .distantPast)
        guard let compact = RelativeTimestampFormatter.format(since: date, now: now) else { return "Just now" }
        return "\(compact) ago"
    }

    private func actionTint(for action: SessionInspectorAction) -> Color {
        switch action {
        case .openOriginal:
            return Catppuccin.blue
        case .inspectTranscript:
            return session.phase.isWaitingForApproval ? Catppuccin.yellow : Catppuccin.lavender
        }
    }

    private func freshnessText(now: Date) -> String {
        guard let observedAt = session.phaseObservedAt else { return "Status inferred" }
        guard let compact = RelativeTimestampFormatter.format(since: observedAt, now: now) else { return "Synced just now" }
        return "Synced \(compact) ago"
    }

    private var evidenceText: String {
        switch session.phaseEvidenceSource {
        case .hook: return "Live hook"
        case .transcriptMarker: return "Transcript marker"
        case .transcriptHeuristic: return "Transcript heuristic"
        case .rediscovery: return "Rediscovery"
        case .localAction: return "Local action"
        case .none: return "Observed session activity"
        }
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cardBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(SessionInspectorTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.75)
            )
    }
}

private struct SessionTranscriptView: View {
    let session: SessionState
    let onShowBrief: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onShowBrief) {
                    Label("Session brief", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundColor(ChatTheme.secondary)

                Divider()
                    .frame(height: 18)

                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                Text(session.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(ChatTheme.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if session.phase != .ended && session.origin != .visorSpawned {
                    Button {
                        SessionNavigationRecencyStore.shared.record(session)
                        SessionNavigator.navigateToSession(session)
                    } label: {
                        Label("Open in original", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(ChatTheme.link)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(SessionInspectorTheme.card)

            Divider().overlay(SessionInspectorTheme.cardBorder)
            ChatViewHost(sessionId: session.sessionId)
        }
    }
}

private struct InspectorChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(ChatTheme.chipForeground(tint))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.11)))
    }
}

private struct InspectorActionButton: View {
    let action: SessionInspectorActionPresentation
    let prominent: Bool
    let tint: Color
    let perform: (SessionInspectorAction) -> Void

    var body: some View {
        Button {
            perform(action.action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(action.title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(prominent ? Catppuccin.base : ChatTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? tint : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(prominent ? tint : SessionInspectorTheme.cardBorder, lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var symbol: String {
        switch action.action {
        case .openOriginal: return "arrow.up.forward.app"
        case .inspectTranscript: return "text.bubble"
        }
    }
}

private struct InspectorCard<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Capsule()
                    .fill(tint)
                    .frame(width: 16, height: 3)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ChatTheme.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SessionInspectorTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(SessionInspectorTheme.cardBorder, lineWidth: 0.5)
                )
        )
    }
}
