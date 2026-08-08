import Foundation

/// Repairs a Pi row that stayed pinned to an active phase because Agent
/// Visor never observed the runtime's completion event.
///
/// Pi lifecycle delivery is best-effort: the bundled extension opens one
/// short-lived unix socket per event with a 100 ms budget, no acknowledgement,
/// and no retry. A single dropped `Stop` used to pin a finished session to
/// Working permanently, because every other repair path is deliberately
/// closed for a hook-tracked Pi row — transcript inference stops once hook
/// evidence exists, a heartbeat is phase-neutral, and only `waitingForInput`
/// has a staleness ceiling (`HookReadyExpirationPolicy`). The observed
/// regression was a session whose turn ended at 18:07 still rendering the
/// orange Working dot 20 minutes later.
///
/// The runtime's own idle flag closes that hole without inferring attention
/// from silence: `is_idle` is exact evidence reported by the same process
/// that would have emitted `agent_settled`. A heartbeat therefore stays
/// phase-neutral in every case except one — the runtime says nothing is
/// running while Agent Visor still shows work in flight.
///
/// Scope is intentionally one-directional. This policy only clears a stale
/// active phase; it never promotes an Idle or Ready row to Working, so a
/// heartbeat sampled just before a completion cannot resurrect Working after
/// the real `Stop` already landed.
public enum PiIdleHeartbeatRecoveryPolicy {
    public enum Outcome: Equatable, Sendable {
        /// Leave the row exactly as it is.
        case none
        /// Publish the completion the dropped event should have published,
        /// including the user-visible Ready episode (pulse, attention row,
        /// notification).
        case ready
        /// Clear the active phase quietly. Used when the completion boundary
        /// is too old to still be news, so recovery does not ring a
        /// notification for a turn that finished long ago.
        case idle
    }

    /// How recently the transcript must have been written for a recovered
    /// completion to still count as a Ready episode.
    ///
    /// Pi writes the turn's final assistant message immediately before
    /// `agent_settled`, so the transcript's modification time is the real
    /// completion boundary. One heartbeat interval is 10s: an ordinary
    /// dropped-event recovery lands well inside this window and behaves
    /// exactly like the event that was lost. A row rescued minutes later
    /// (long-dropped event, Agent Visor restart) resolves silently instead.
    public static let readyGraceWindow: TimeInterval = 90

    /// Cheap pre-check so callers can skip resolving the transcript
    /// modification date — which for Pi means touching the filesystem — on
    /// every phase-neutral heartbeat.
    public static func shouldResolveCompletionBoundary(
        isHeartbeat: Bool,
        reportedIdle: Bool?,
        currentPhaseIsActive: Bool
    ) -> Bool {
        isHeartbeat && reportedIdle == true && currentPhaseIsActive
    }

    /// - Parameters:
    ///   - isHeartbeat: this event is Pi's periodic liveness heartbeat.
    ///   - reportedIdle: the runtime's `is_idle` flag. `nil` means the
    ///     runtime did not report one (older extension copy still loaded in a
    ///     live process, or an unavailable probe), which must keep the
    ///     previous phase-neutral behavior.
    ///   - currentPhaseIsActive: the row currently shows Working, i.e.
    ///     `.processing` or `.compacting`.
    ///   - transcriptModifiedAt: last write to the session's transcript, the
    ///     runtime's own completion boundary. `nil` when it cannot be read.
    public static func outcome(
        isHeartbeat: Bool,
        reportedIdle: Bool?,
        currentPhaseIsActive: Bool,
        transcriptModifiedAt: TimeInterval?,
        now: TimeInterval,
        readyGrace: TimeInterval = readyGraceWindow
    ) -> Outcome {
        guard shouldResolveCompletionBoundary(
            isHeartbeat: isHeartbeat,
            reportedIdle: reportedIdle,
            currentPhaseIsActive: currentPhaseIsActive
        ) else { return .none }

        // No readable boundary: still clear the wrong Working state, but stay
        // quiet rather than guessing that a completion just happened.
        guard let transcriptModifiedAt else { return .idle }

        // A transcript written in the future is clock skew, not old news.
        guard transcriptModifiedAt <= now else { return .ready }

        return (now - transcriptModifiedAt) <= readyGrace ? .ready : .idle
    }
}
