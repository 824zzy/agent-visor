import Foundation

/// The state that must still match immediately before a destructive clear
/// chunk. Keeping this value in Core makes the cancellation safety rule
/// executable in tests instead of leaving it in an async view closure.
public struct ComposerCancellationClearState: Equatable, Sendable {
    public let sessionId: String
    public let submissionId: String
    public let clearedRevision: Int
    public let textIsEmpty: Bool
    public let attachmentIDs: [String]

    public init(
        sessionId: String,
        submissionId: String,
        clearedRevision: Int,
        textIsEmpty: Bool,
        attachmentIDs: [String]
    ) {
        self.sessionId = sessionId
        self.submissionId = submissionId
        self.clearedRevision = clearedRevision
        self.textIsEmpty = textIsEmpty
        self.attachmentIDs = attachmentIDs
    }
}

public enum ComposerCancellationClearStep: Equatable, Sendable {
    case proceed
    case aborted
}

/// A small, deterministic state machine for chunked terminal prompt clears.
/// It aborts permanently on the first failed chunk or state mismatch, so a
/// caller cannot continue deleting after a partial failure or user mutation.
public struct ComposerCancellationClearProgress: Equatable, Sendable {
    public let expected: ComposerCancellationClearState
    public private(set) var completedChunks: Int = 0
    public private(set) var isAborted = false

    public init(expected: ComposerCancellationClearState) {
        self.expected = expected
    }

    public mutating func beginChunk(current: ComposerCancellationClearState) -> ComposerCancellationClearStep {
        guard !isAborted, current == expected else {
            isAborted = true
            return .aborted
        }
        return .proceed
    }

    @discardableResult
    public mutating func finishChunk(succeeded: Bool) -> ComposerCancellationClearStep {
        guard !isAborted, succeeded else {
            isAborted = true
            return .aborted
        }
        completedChunks += 1
        return .proceed
    }

    public mutating func abort() {
        isAborted = true
    }
}
