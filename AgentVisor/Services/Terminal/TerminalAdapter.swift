//
//  TerminalAdapter.swift
//  AgentVisor
//
//  Common surface that the Ghostty and iTerm2 implementations conform to.
//  Lets the rest of the app stay terminal-agnostic: pick the right adapter
//  via TerminalAdapterRegistry and call methods without knowing which
//  terminal is hosting the session.
//

import Foundation
import AgentVisorCore

protocol TerminalAdapter {
    /// Send text to the session's pane in the background. Implementations
    /// must not steal focus from the frontmost app. Returns true if the
    /// terminal accepted the delivery.
    func sendText(_ text: String, toSession session: SessionState) -> Bool

    /// Send text followed by the adapter's submit action and preserve a
    /// partial-write result when text was accepted but Enter failed.
    func sendTextOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalAttachmentDeliveryOutcome

    /// Bring the session's exact pane to the front. Returns true only when
    /// the owning app is frontmost and keyboard input targets that pane.
    nonisolated func focusSession(_ session: SessionState) -> Bool
}

extension TerminalAdapter {
    func sendTextOutcome(
        _ text: String,
        toSession session: SessionState,
        operationID: String?
    ) -> TerminalAttachmentDeliveryOutcome {
        let delivered: Bool
        if let operationID {
            delivered = ProcessExecutor.withOperationID(operationID) {
                sendText(text, toSession: session)
            }
        } else {
            delivered = sendText(text, toSession: session)
        }
        return delivered
            ? .delivered
            : .failedBeforeWrite(reason: "The terminal rejected the message before confirmation.")
    }

    /// Compatibility entry point for serialized Chat sends. Existing
    /// navigation-only adapters keep their small protocol surface, while
    /// synchronous AppleScript implementations inherit the lane's operation
    /// identity through the executor's thread-local context.
    func sendText(
        _ text: String,
        toSession session: SessionState,
        operationID: String
    ) -> Bool {
        ProcessExecutor.withOperationID(operationID) {
            sendText(text, toSession: session)
        }
    }
}
