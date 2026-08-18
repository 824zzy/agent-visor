import Foundation

/// How a row's process identity should change when discovery finds it again.
public enum RediscoveredPidUpdate: Equatable, Sendable {
    /// Keep whatever the row already holds.
    case leave
    /// Drop the row's pid. Discovery saw the session but no process of its
    /// own, which is the shape of a thread inside a shared app process.
    case clear
    /// Adopt the pid discovery reported.
    case set(Int)
}

/// What rediscovery should change on one row.
///
/// Discovery runs every few seconds and can find a session the store believes
/// ended. Whether that proves the session is back depends on the agent's
/// process model, so the agent's provider answers, and the store applies the
/// answer the same way for everyone.
public struct RediscoveredAttachment: Equatable, Sendable {
    /// Move an ended row back to idle, because discovery proves it is live.
    public var revivesEndedRow: Bool
    /// What to do with the row's pid.
    public var pid: RediscoveredPidUpdate
    /// Take the last-activity time from the transcript when the file is newer
    /// than the row. Threads inside a shared app process have no hooks of
    /// their own, so the file is their only clock.
    public var refreshesActivityFromTranscript: Bool

    public init(
        revivesEndedRow: Bool = false,
        pid: RediscoveredPidUpdate = .leave,
        refreshesActivityFromTranscript: Bool = false
    ) {
        self.revivesEndedRow = revivesEndedRow
        self.pid = pid
        self.refreshesActivityFromTranscript = refreshesActivityFromTranscript
    }
}

/// Phase for a row whose agent keeps its own record of being busy or idle.
///
/// Claude Code writes that record beside the session, and rediscovery reads it.
/// The record only ever corrects a row that disagrees with it: a busy record
/// lifts an idle or ready row to working, and an idle record settles a working
/// row to ready. It never reports an approval, an end, or a compaction, so it
/// must not overwrite those phases, which carry stronger evidence.
public enum RediscoveredActivityPhasePolicy {
    public static func phase(
        for activity: ClaudeCodeSessionMetadataActivity,
        currentPhase: SessionPhase
    ) -> SessionPhase? {
        switch (activity, currentPhase) {
        case (.working, .idle), (.working, .waitingForInput):
            return .processing
        case (.idle, .processing):
            return .waitingForInput
        default:
            return nil
        }
    }
}
