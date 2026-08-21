import AppKit
import AgentVisorCore
import SwiftUI

/// Full-window Chat destination entered from the Sessions browser.
/// It reuses the same source-agnostic conversation/composer surface as
/// Claude Code; Pi reaches it through its provider parser and text sender.
struct SessionChatWorkspace: View {
    let sessionId: String
    let ownerName: String
    let canOpenOriginal: Bool
    let onBack: () -> Void
    let onOpenOriginal: () -> Void
    @StateObject private var model: ChatViewHostModel

    init(
        sessionId: String,
        ownerName: String,
        canOpenOriginal: Bool,
        onBack: @escaping () -> Void,
        onOpenOriginal: @escaping () -> Void
    ) {
        self.sessionId = sessionId
        self.ownerName = ownerName
        self.canOpenOriginal = canOpenOriginal
        self.onBack = onBack
        self.onOpenOriginal = onOpenOriginal
        _model = StateObject(wrappedValue: ChatViewHostModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.session {
                chatHeader(session)
                Divider().overlay(ChatTheme.cardBorder)
                ChatViewHost(sessionId: sessionId)
            } else {
                unavailableHeader
                ContentUnavailableView(
                    "Session unavailable",
                    systemImage: "rectangle.slash",
                    description: Text("Return to Sessions and choose another conversation.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChatTheme.headerBg)
    }

    private func chatHeader(_ session: SessionState) -> some View {
        HStack(spacing: 6) {
            backButton
            HStack(spacing: 7) {
                SessionStatusDot(session: session, diameter: 7, colorScheme: .adaptive)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(sessionStatusAccessibilityLabel(session))
                    .help(SessionPhaseHelpers.phaseDescription(for: session.phase))
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(ChatTheme.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if canOpenOriginal {
                    Button(action: onOpenOriginal) {
                        Label("Open in \(ownerName)", systemImage: "arrow.up.forward")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 32)
                            .chatHeaderActionHover()
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                detailsMenu(session)
            }
            .fixedSize()
        }
        .mainContentRail(alignment: .leading)
        .frame(height: 46)
        .background(ChatTheme.headerBg)
    }

    private var unavailableHeader: some View {
        HStack {
            backButton
            Spacer()
        }
        .mainContentRail(alignment: .leading)
        .frame(height: 46)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Label("Sessions", systemImage: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .chatHeaderActionHover()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel("Back to Sessions")
    }

    private func detailsMenu(_ session: SessionState) -> some View {
        Menu {
            Text("Source: \(agentDisplayName(for: session))")
            Text("Owner: \(ownerName)")
            Text("Project: \(session.bestProjectName)")
            Text("Path: \(displayPath(session.cwd))")
            modelDetailRows(session)
            if let tool = session.lastToolName, !tool.isEmpty {
                Text("Last tool: \(tool)")
            }
            Divider()
            Button("Copy session path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.cwd, forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
                .chatHeaderActionHover()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Session details")
        .help("Session details")
    }

    @ViewBuilder
    private func modelDetailRows(_ session: SessionState) -> some View {
        if let modelID = session.modelName, !modelID.isEmpty {
            let displayModelName = session.displayModelName ?? modelID
            Text("Model: \(displayModelName)")
            if displayModelName != modelID {
                Text("Model ID: \(modelID)")
            }
        }
    }

    private func sessionStatusAccessibilityLabel(_ session: SessionState) -> String {
        "Status: \(SessionPhaseHelpers.phaseDescription(for: session.phase))"
    }

    private func agentDisplayName(for session: SessionState) -> String {
        AgentRegistry.provider(for: session.agentID)?.displayName ?? session.agentID.rawValue
    }

    private func displayPath(_ path: String) -> String {
        ProjectDisplayNamePolicy.displayPath(
            forCwd: path,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
}

private struct ChatHeaderActionHoverStyle: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundColor(isHovered ? ChatTheme.link : ChatTheme.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? ChatTheme.link.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

private extension View {
    func chatHeaderActionHover() -> some View {
        modifier(ChatHeaderActionHoverStyle())
    }
}
