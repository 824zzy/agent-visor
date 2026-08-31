import AgentVisorCore
import Combine
import Foundation

/// MainActor-owned view cache for the blocking terminal identity probe.
///
/// SwiftUI reads only this immutable cached state. Every refresh is keyed by
/// the exact session/generation/process/TTY/host identity, and an old result
/// is discarded if any of those fields changes while the probe is running.
@MainActor
final class TerminalIdentityCapabilityCache: ObservableObject {
    @Published private(set) var states: [TerminalIdentityCapabilityKey: TerminalIdentityCapability] = [:]

    private var currentKeyBySession: [String: TerminalIdentityCapabilityKey] = [:]
    private var requestIDBySession: [String: UUID] = [:]
    private var tasksBySession: [String: Task<Void, Never>] = [:]
    private let verify: @Sendable (SessionState) -> Bool

    init(
        verify: @escaping @Sendable (SessionState) -> Bool = {
            TerminalProcessIdentityResolver.isVerified($0)
        }
    ) {
        self.verify = verify
    }

    func state(
        for session: SessionState,
        generationID: String
    ) -> TerminalIdentityCapability {
        let key = TerminalIdentityCapabilityPolicy.key(
            session: session,
            generationID: generationID
        )
        return states[key] ?? .loading(for: key)
    }

    /// Starts one off-main-actor probe for the current exact identity. A
    /// repeated render of the same identity does not start another probe.
    func refresh(
        session: SessionState,
        generationID: String
    ) {
        let key = TerminalIdentityCapabilityPolicy.key(
            session: session,
            generationID: generationID
        )
        let sessionID = session.sessionId
        if currentKeyBySession[sessionID] == key,
           let current = states[key],
           !current.isLoading {
            return
        }

        tasksBySession[sessionID]?.cancel()
        if let previousKey = currentKeyBySession[sessionID], previousKey != key {
            states.removeValue(forKey: previousKey)
        }
        currentKeyBySession[sessionID] = key
        let requestID = UUID()
        requestIDBySession[sessionID] = requestID
        states[key] = .loading(for: key)

        let verifier = verify
        tasksBySession[sessionID] = Task { [weak self] in
            // `verify` performs bounded ps/process-tree reads. Keep all of
            // that blocking work outside the MainActor and publish only the
            // exact matching result back to the cache.
            let verified = await Task.detached(priority: .userInitiated) {
                verifier(session)
            }.value
            guard !Task.isCancelled else { return }
            self?.apply(
                verified: verified,
                key: key,
                sessionID: sessionID,
                requestID: requestID
            )
        }
    }

    func cancel(sessionID: String) {
        tasksBySession.removeValue(forKey: sessionID)?.cancel()
        requestIDBySession.removeValue(forKey: sessionID)
        if let key = currentKeyBySession.removeValue(forKey: sessionID) {
            states.removeValue(forKey: key)
        }
    }

    private func apply(
        verified: Bool,
        key: TerminalIdentityCapabilityKey,
        sessionID: String,
        requestID: UUID
    ) {
        guard requestIDBySession[sessionID] == requestID,
              currentKeyBySession[sessionID] == key,
              let current = states[key],
              current.isLoading else {
            // A stale completion must not resurrect a capability for a
            // replaced process, session, or generation.
            return
        }
        states[key] = current.applying(isVerified: verified, for: key)
        tasksBySession.removeValue(forKey: sessionID)
    }
}
