import Foundation

/// The last turn-boundary marker observed in an agent's transcript.
/// Codex rollouts emit these explicitly (`task_started` / `task_complete`),
/// which makes turn-completion deterministic. Agents whose transcript has
/// no such marker (e.g. Cursor's bare `{role, message}` log) report
/// `.none` and fall back to the role + quiescence heuristic.
public enum TurnMarker: Equatable, Sendable {
    case started
    case completed
    case none
}

/// Role of the last meaningful transcript entry — used by the heuristic
/// path when explicit turn markers aren't available.
public enum LastEntryRole: Equatable, Sendable {
    case user
    case assistant
    case tool
    case none
}

/// Phase inferred purely from transcript shape, for OBSERVED agents that
/// expose no hook seam (Codex.app GUI threads, Cursor IDE Agents Window).
/// Hooked agents (claude-code, codex CLI) get their phase from hook
/// events and never go through this path.
public enum InferredPhase: Equatable, Sendable {
    case processing
    case waitingForInput
    case idle
}

/// Whether an inferred `.idle` should be allowed to CLEAR an observed
/// session's current phase. For observed agents (no hook, no process-death
/// signal) transcript inference is the only thing that can pull a session
/// out of an active phase — so a `.idle` inference must clear a stuck
/// `.processing` / `.waitingForInput`. It must NOT touch anything else
/// (`.idle` already, `.waitingForApproval` set by a hook, `.ended`,
/// `.compacting`), where it would either be a no-op or clobber real state.
///
/// `currentPhaseIsActive` = the session is currently `.processing` or
/// `.waitingForInput`. Kept as a bare bool so Core stays free of the app's
/// `SessionPhase` type.
public enum ObservedIdleClearPolicy {
    public static func shouldClear(currentPhaseIsActive: Bool) -> Bool {
        currentPhaseIsActive
    }
}

public enum ObservedApprovalRecoveryPolicy {
    public static func shouldApply(
        currentPhaseIsWaitingForApproval: Bool,
        inferredPhase: InferredPhase
    ) -> Bool {
        guard currentPhaseIsWaitingForApproval else { return true }
        return inferredPhase != .processing
    }
}

/// Derives a session phase from transcript signals. Pure / value-in-
/// value-out so it's unit-testable without files, a clock, or a watcher.
///
/// Two regimes:
///   - **Deterministic** (Codex): a `task_complete` marker means the turn
///     ended → `.waitingForInput`; `task_started` means a turn is running
///     → `.processing`. No timing needed.
///   - **Heuristic** (Cursor): with `.none` marker, a transcript whose
///     last entry is an assistant message AND has been quiescent (no new
///     bytes) for `quiescenceThreshold` seconds is treated as "your turn".
///     A shorter quiescence means the assistant is probably still
///     streaming → `.processing`.
public enum TranscriptPhaseInferrer {
    /// Default quiescence window for the heuristic (Cursor) path. Long
    /// enough to ride out mid-turn pauses between streamed chunks, short
    /// enough that "your turn" lands promptly after the agent stops.
    public static let defaultQuiescenceThreshold: TimeInterval = 6

    /// Upper bound on the "your turn" / "processing" window. A transcript
    /// quiet *longer* than this is a dormant old session, not one actively
    /// working or awaiting the user — so it stays idle and out of the
    /// attention stream. Applies to BOTH paths: the heuristic (assistant-
    /// last) and Codex's deterministic markers. The marker path used to be
    /// exempt on the assumption the discovery active-window kept it tight,
    /// but that window is now user-configurable up to 42h — so a thread you
    /// finished a day ago would otherwise show as "your turn", sort above
    /// live work, and pulse its status dot.
    public static let defaultStaleCeiling: TimeInterval = 30 * 60

    public static func infer(
        turnMarker: TurnMarker,
        lastEntryRole: LastEntryRole,
        quiescentSeconds: TimeInterval,
        quiescenceThreshold: TimeInterval = defaultQuiescenceThreshold,
        staleCeiling: TimeInterval = defaultStaleCeiling
    ) -> InferredPhase {
        // Deterministic path: explicit markers win — but only while the
        // transcript is recent. A thread quiet past the stale ceiling is
        // dormant regardless of its last marker; surfacing it as
        // "your turn"/"processing" sorts a day-old thread above live work
        // and pulses its status dot (the discovery window can be up to 42h).
        switch turnMarker {
        case .completed:
            return quiescentSeconds > staleCeiling ? .idle : .waitingForInput
        case .started:
            return quiescentSeconds > staleCeiling ? .idle : .processing
        case .none:
            break
        }

        // Heuristic path (no markers).
        switch lastEntryRole {
        case .none:
            return .idle
        case .user, .tool:
            // The user just spoke, or a tool just ran — the agent owes a
            // response, unless the transcript has gone dormant.
            return quiescentSeconds > staleCeiling ? .idle : .processing
        case .assistant:
            if quiescentSeconds < quiescenceThreshold {
                // Likely still streaming the same turn.
                return .processing
            }
            if quiescentSeconds > staleCeiling {
                // Dormant old session — finished long ago, not "your turn".
                return .idle
            }
            return .waitingForInput
        }
    }
}
