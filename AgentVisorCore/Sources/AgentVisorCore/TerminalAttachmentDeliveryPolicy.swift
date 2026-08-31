import Foundation

/// The result of one ordered terminal attachment submission.  A transport
/// adapter reports a pre-write failure when it can prove that no terminal
/// bytes were emitted; otherwise a failed step is conservatively treated as
/// potentially partial.
public enum TerminalAttachmentDeliveryStep: Equatable, Sendable {
    case succeeded(step: String)
    case failedBeforeWrite(step: String, reason: String)
    case failedAfterWrite(step: String, reason: String)
}

/// Provider-neutral result consumed by the composer recovery ledger.
public enum TerminalAttachmentDeliveryOutcome: Equatable, Sendable {
    case delivered
    case failedBeforeWrite(reason: String)
    case uncertainAfterPartialWrite(reason: String, completedSteps: [String])

    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }
}

/// Result of dispatching terminal text through one AppleScript tier.
///
/// `accepted` means that the script returned its explicit success sentinel.
/// `provenRejected` means that the script returned its explicit `fail`
/// sentinel before accepting text, so a caller may select another tier.
/// `indeterminate` covers launch, execution, and timeout failures after the
/// dispatch was started. The text may already be in the terminal, so callers
/// must not send the same text through another tier.
public enum TerminalTextDispatchResult: Equatable, Sendable {
    case accepted
    case provenRejected(reason: String)
    case indeterminate(reason: String)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    /// Compatibility spelling for callers that describe the explicit script
    /// sentinel as a pre-write rejection.
    public static func rejectedBeforeWrite(reason: String) -> Self {
        .provenRejected(reason: reason)
    }

    /// Compatibility spelling for callers that describe an indeterminate
    /// AppleScript completion as unknown.
    public static func unknown(reason: String) -> Self {
        .indeterminate(reason: reason)
    }
}

/// AppleScript dispatch has the same three-state contract for text and named
/// terminal actions. Keep a descriptive alias for app-side seams.
public typealias AppleScriptDispatchResult = TerminalTextDispatchResult

/// Pure ordering semantics for attachment-aware terminal sends.
///
/// The caller must stop invoking transport adapters after the first failed
/// step. This policy intentionally accepts a complete result list so tests
/// can prove that a later step never changes the first failure's outcome.
public enum TerminalAttachmentDeliveryPolicy {
    /// Convert one text-dispatch result to the provider-neutral delivery
    /// outcome. A successful text action is complete only for callers whose
    /// action has no later submit step; text-plus-Enter callers should use
    /// `textAndEnterOutcome` after dispatching Enter separately.
    public static func textDispatchOutcome(
        _ result: TerminalTextDispatchResult
    ) -> TerminalAttachmentDeliveryOutcome {
        switch result {
        case .accepted:
            return .delivered
        case .provenRejected(let reason):
            return .failedBeforeWrite(reason: boundedReason(reason))
        case .indeterminate(let reason):
            return .uncertainAfterPartialWrite(
                reason: boundedReason(reason),
                completedSteps: ["text"]
            )
        }
    }

    /// Run ordered text-delivery tiers. Only an explicit script rejection may
    /// select the next tier. A timeout or other indeterminate result owns the
    /// text boundary and therefore stops immediately to prevent a duplicate.
    public static func runTextDispatchTiers(
        _ tiers: [String],
        perform: (String) -> TerminalTextDispatchResult
    ) -> TerminalTextDispatchResult {
        guard !tiers.isEmpty else {
            return .provenRejected(reason: "No terminal delivery tier is available.")
        }
        var lastRejection: String?
        for tier in tiers {
            switch perform(tier) {
            case .accepted:
                return .accepted
            case .provenRejected(let reason):
                lastRejection = reason
            case .indeterminate(let reason):
                return .indeterminate(reason: reason)
            }
        }
        return .provenRejected(
            reason: lastRejection ?? "The terminal rejected the message before write."
        )
    }

    /// Executes an ordered synchronous adapter sequence and stops at the
    /// first failure.  AppKit adapters use the same ordering contract in
    /// their async wrappers; keeping this runner in Core makes the critical
    /// no-later-write guarantee executable without an app target.
    public static func run(
        steps: [String],
        perform: (String) -> TerminalAttachmentDeliveryStep
    ) -> TerminalAttachmentDeliveryOutcome {
        var results: [TerminalAttachmentDeliveryStep] = []
        for step in steps {
            let result = perform(step)
            results.append(result)
            switch result {
            case .succeeded:
                continue
            case .failedBeforeWrite, .failedAfterWrite:
                return outcome(for: results)
            }
        }
        return outcome(for: results)
    }

    /// Runs a compound terminal transaction while revalidating its target at
    /// the boundary of every irreversible step. A verifier failure is a
    /// definite pre-write failure for that step, so callers must not invoke
    /// remaining steps or guess whether a replacement process received bytes.
    /// AppKit routes supply the live PID/start-token/TTY/host check; Core
    /// tests can model a process swap without opening a terminal.
    public static func run(
        steps: [String],
        verifyTarget: () -> Bool,
        perform: (String) -> TerminalAttachmentDeliveryStep
    ) -> TerminalAttachmentDeliveryOutcome {
        var results: [TerminalAttachmentDeliveryStep] = []
        for step in steps {
            guard verifyTarget() else {
                results.append(.failedBeforeWrite(
                    step: step,
                    reason: "Terminal target identity changed before " + step + "."
                ))
                return outcome(for: results)
            }
            let result = perform(step)
            results.append(result)
            switch result {
            case .succeeded:
                continue
            case .failedBeforeWrite, .failedAfterWrite:
                return outcome(for: results)
            }
        }
        return outcome(for: results)
    }

    /// Generic form used by host adapters whose steps carry structured
    /// payloads (for example `KeystrokeStep`). The name closure keeps the
    /// recovery outcome human-readable without exposing adapter internals.
    public static func run<Step>(
        steps: [Step],
        verifyTarget: () -> Bool,
        name: (Step) -> String,
        perform: (Step) -> TerminalAttachmentDeliveryStep
    ) -> TerminalAttachmentDeliveryOutcome {
        var results: [TerminalAttachmentDeliveryStep] = []
        for step in steps {
            let stepName = name(step)
            guard verifyTarget() else {
                results.append(.failedBeforeWrite(
                    step: stepName,
                    reason: "Terminal target identity changed before " + stepName + "."
                ))
                return outcome(for: results)
            }
            let result = perform(step)
            results.append(result)
            switch result {
            case .succeeded:
                continue
            case .failedBeforeWrite, .failedAfterWrite:
                return outcome(for: results)
            }
        }
        return outcome(for: results)
    }

    public static func outcome(
        for steps: [TerminalAttachmentDeliveryStep]
    ) -> TerminalAttachmentDeliveryOutcome {
        var completed: [String] = []
        for step in steps {
            switch step {
            case .succeeded(let name):
                completed.append(name)
            case .failedBeforeWrite(_, let reason):
                guard completed.isEmpty else {
                    return .uncertainAfterPartialWrite(
                        reason: boundedReason(reason),
                        completedSteps: completed
                    )
                }
                return .failedBeforeWrite(reason: boundedReason(reason))
            case .failedAfterWrite(_, let reason):
                return .uncertainAfterPartialWrite(
                    reason: boundedReason(reason),
                    completedSteps: completed
                )
            }
        }
        return .delivered
    }

    /// Maps a two-action text submission to the honest delivery state. The
    /// terminal adapters issue text and Enter as separate actions, so a
    /// rejected Enter can happen after the text was already accepted.
    public static func textAndEnterOutcome(
        textDispatch: TerminalTextDispatchResult,
        enterDispatch: TerminalTextDispatchResult
    ) -> TerminalAttachmentDeliveryOutcome {
        switch textDispatch {
        case .accepted:
            switch enterDispatch {
            case .accepted:
                return .delivered
            case .provenRejected(let reason), .indeterminate(let reason):
                return .uncertainAfterPartialWrite(
                    reason: boundedReason(reason),
                    completedSteps: ["text"]
                )
            }
        case .provenRejected(let reason):
            return .failedBeforeWrite(reason: boundedReason(reason))
        case .indeterminate(let reason):
            return .uncertainAfterPartialWrite(
                reason: boundedReason(reason),
                completedSteps: ["text"]
            )
        }
    }

    /// Compatibility form for adapters that still expose only Boolean
    /// success. New AppleScript paths should preserve the richer dispatch
    /// state through the overload above.
    public static func textAndEnterOutcome(
        textAccepted: Bool,
        enterAccepted: Bool,
        textFailureReason: String = "Terminal text was rejected before write.",
        enterFailureReason: String = "Terminal Enter was rejected after text was accepted."
    ) -> TerminalAttachmentDeliveryOutcome {
        textAndEnterOutcome(
            textDispatch: textAccepted
                ? .accepted
                : .provenRejected(reason: textFailureReason),
            enterDispatch: enterAccepted
                ? .accepted
                : .provenRejected(reason: enterFailureReason)
        )
    }

    private static func boundedReason(_ raw: String) -> String {
        // ponytail: failure text is capped so an adapter cannot inflate the
        // recovery ledger with an unbounded diagnostic. Keep this in sync
        // with ComposerSendRecoveryLedger.maxReasonBytes.
        var result = ""
        var bytes = 0
        for scalar in raw.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= ComposerSendRecoveryLedger.maxReasonBytes else {
                break
            }
            result.unicodeScalars.append(scalar)
            bytes += scalarBytes
        }
        return result.isEmpty ? "Terminal delivery failed." : result
    }
}
