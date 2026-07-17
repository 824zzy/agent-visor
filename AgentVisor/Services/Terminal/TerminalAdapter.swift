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

protocol TerminalAdapter {
    /// Send text to the session's pane in the background. Implementations
    /// must not steal focus from the frontmost app. Returns true if the
    /// terminal accepted the delivery.
    func sendText(_ text: String, toSession session: SessionState) -> Bool

    /// Bring the session's exact pane to the front. Returns true only when
    /// the owning app is frontmost and keyboard input targets that pane.
    func focusSession(_ session: SessionState) -> Bool
}
