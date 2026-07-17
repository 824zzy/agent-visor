//
//  ChatViewHost.swift
//  AgentVisor
//
//  Phase 5 (apple2apple): mounts the existing notch ChatView inside
//  the window's detail pane. Shares the live NotchViewModel +
//  ClaudeSessionMonitor instances owned by NotchWindowController so
//  both surfaces observe the same state. Looks up the SessionState
//  from SessionStore on appear; shows a placeholder until the store
//  has finished bootstrapping.
//

import AgentVisorCore
import Combine
import SwiftUI

@MainActor
final class ChatViewHostModel: ObservableObject {
    @Published var session: SessionState?
    private var cancellables: Set<AnyCancellable> = []
    private let sessionId: String

    init(sessionId: String) {
        self.sessionId = sessionId
        SessionStore.shared.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.session = sessions.first { $0.sessionId == sessionId }
            }
            .store(in: &cancellables)
    }
}

struct ChatViewHost: View {
    let sessionId: String
    @StateObject private var model: ChatViewHostModel

    init(sessionId: String) {
        self.sessionId = sessionId
        _model = StateObject(wrappedValue: ChatViewHostModel(sessionId: sessionId))
    }

    var body: some View {
        // Window mode mounts `WindowChatView`, which reuses the same
        // row primitives the notch's ChatView uses (MessageItemView,
        // groupedTimelineRows, ToolResultDetailView, …) so chat
        // content renders identically: markdown, code blocks, LaTeX,
        // tool cards, plan cards, edit hunks, drilldown overlay. No
        // composer / approval bar yet — those land in a follow-up.
        WindowChatView(sessionId: sessionId)
    }
}
