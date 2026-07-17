import CryptoKit
import Foundation

/// Persistence wire-format for an in-progress AskUserQuestion form.
///
/// The view layer (`AskUserQuestionPendingContent`) holds the live
/// `@Published` state in its own `QuestionFlowState` class. This snapshot
/// is the *value-type projection* that gets stashed in
/// `SessionStore.drafts` so the live state can be rebuilt on view
/// remount (e.g. after the user navigates to the sessions list and back).
///
/// Scope is intentionally narrower than the live state:
///   - Includes: `currentStep` (form nav cursor) and `perQuestion`
///     (selections + Other-text + arrow cursor).
///   - Excludes: `submitted` / `canceled` (terminal flags — restoring a
///     "submitted" form would render it as already-submitted), and
///     `otherEditingIndex` (transient `@FocusState`; forcing focus on
///     remount would be jarring, especially if the user navigated away
///     to escape the keyboard).
public struct QuestionFlowSnapshot: Equatable, Codable, Sendable {
    public var currentStep: Int
    public var perQuestion: [Int: QuestionLocalStateSnapshot]

    public init(currentStep: Int = 0, perQuestion: [Int: QuestionLocalStateSnapshot] = [:]) {
        self.currentStep = currentStep
        self.perQuestion = perQuestion
    }
}

/// Codable mirror of the view's `QuestionLocalState`. Kept distinct from
/// the view-layer struct so persistence concerns don't bleed back into
/// the SwiftUI reactive layer.
public struct QuestionLocalStateSnapshot: Equatable, Codable, Sendable {
    public var singleSelectedIndex: Int?
    public var multiSelectedIndices: Set<Int>
    public var otherText: String
    public var optionFocus: Int

    public init(
        singleSelectedIndex: Int? = nil,
        multiSelectedIndices: Set<Int> = [],
        otherText: String = "",
        optionFocus: Int = 0
    ) {
        self.singleSelectedIndex = singleSelectedIndex
        self.multiSelectedIndices = multiSelectedIndices
        self.otherText = otherText
        self.optionFocus = optionFocus
    }
}

/// Content fingerprint of an AskUserQuestion prompt. Used as a cache
/// key for stored drafts: the draft is only valid if the prompt now
/// being rendered hashes to the same fingerprint.
///
/// The fingerprint covers ONLY the inputs that, if changed, would make
/// stored answers misleading or wrong:
///   - question text — identifies the question.
///   - `multiSelect` — flips the answer shape (radio vs. checkbox).
///   - option labels in order — addressing is by index.
///   - question count and order.
///
/// It deliberately excludes:
///   - `header` — chip label only, doesn't shift answer semantics.
///   - option `description` — supplementary text; selections are by
///     label/index, so an edit shouldn't trash the user's typing.
public enum AskUserQuestionDraftFingerprint {
    /// Lightweight projection of `AskUserQuestionPendingDecoder.Question`
    /// holding only the fields the fingerprint actually consumes.
    /// Avoids a Core dep on the view-layer decoder type.
    public struct Question: Equatable, Sendable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiSelect: Bool

        public init(question: String, header: String, options: [Option], multiSelect: Bool) {
            self.question = question
            self.header = header
            self.options = options
            self.multiSelect = multiSelect
        }
    }

    public struct Option: Equatable, Sendable {
        public let label: String
        public let description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    /// Compute the fingerprint. Deterministic across calls and processes.
    /// Field separator `\u{1f}` (ASCII Unit Separator) is a single byte
    /// that won't appear in real prompt text, so we don't need to escape
    /// embedded delimiters.
    public static func compute(questions: [Question]) -> String {
        var hasher = SHA256()
        let unitSep = "\u{1f}".data(using: .utf8)!
        let recordSep = "\u{1e}".data(using: .utf8)!  // record separator — between questions

        for q in questions {
            hasher.update(data: q.question.data(using: .utf8) ?? Data())
            hasher.update(data: unitSep)
            hasher.update(data: (q.multiSelect ? "M" : "S").data(using: .utf8)!)
            hasher.update(data: unitSep)
            for opt in q.options {
                hasher.update(data: opt.label.data(using: .utf8) ?? Data())
                hasher.update(data: unitSep)
            }
            hasher.update(data: recordSep)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
