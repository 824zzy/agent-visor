import Foundation
@testable import AgentVisorCore

/// Builds a `SessionState` for tests.
///
/// The model has 30 stored fields and one memberwise init with defaults. A test that names
/// every field hides the one field it cares about, so this helper exposes only the fields the
/// policies read, and leaves the rest at their defaults.
///
/// It exists because the session model now lives in this package. Before that move, no test in
/// this target could build a session, so every policy had to take loose fields instead.
enum SessionStateFixture {
    static func make(
        sessionId: String = "session-1",
        cwd: String = "/Users/tester/project",
        agentID: AgentID = .claudeCode,
        pid: Int? = nil,
        tty: String? = nil,
        terminalHost: TerminalHost? = nil,
        phase: SessionPhase = .idle,
        sessionName: String? = nil,
        chatItems: [ChatHistoryItem] = [],
        firstUserMessage: String? = nil,
        lastActivityDate: Date? = nil,
        summary: String? = nil,
        modelName: String? = nil,
        modelDisplayName: String? = nil,
        lastActivity: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> SessionState {
        var session = SessionState(
            sessionId: sessionId,
            cwd: cwd,
            agentID: agentID,
            pid: pid,
            tty: tty,
            terminalHost: terminalHost,
            phase: phase,
            chatItems: chatItems,
            conversationInfo: conversationInfo(
                summary: summary,
                firstUserMessage: firstUserMessage,
                lastActivityDate: lastActivityDate
            ),
            lastActivity: lastActivity
        )
        session.sessionName = sessionName
        session.modelName = modelName
        session.modelDisplayName = modelDisplayName
        return session
    }

    /// A `ConversationInfo` with only the fields the policies read.
    static func conversationInfo(
        summary: String? = nil,
        firstUserMessage: String? = nil,
        lastActivityDate: Date? = nil
    ) -> ConversationInfo {
        ConversationInfo(
            summary: summary,
            lastMessage: nil,
            lastMessageRole: nil,
            lastToolName: nil,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: nil,
            lastActivityDate: lastActivityDate,
            lastCwd: nil,
            lastModelName: nil,
            lastContextTokens: nil,
            lastPermissionMode: nil
        )
    }
}
