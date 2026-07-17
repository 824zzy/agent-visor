import Foundation

/// Pure mapping from agent-visor's AskUserQuestion form state to the
/// `answers` dict claude-code's `AskUserQuestionTool` expects in
/// `updatedInput`.
///
/// claude-code's `AskUserQuestionTool.call({questions, answers})`
/// returns `{questions, answers}` straight from input — no TUI is
/// required when the hook responds with `behavior: 'allow' +
/// updatedInput`. This builder produces the `answers` half of that
/// payload.
///
/// Contract mirrors upstream's `AskUserQuestionPermissionRequest.tsx`
/// `submitAnswers` — see that file for the canonical reference. In
/// particular:
/// - Multi-select Other text is dropped when empty/whitespace, mirroring
///   `concat(textInput ? [textInput] : [])`.
/// - Question text is the dict key (claude-code uses it to look up the
///   answer in `mapToolResultToToolResultBlockParam`).
public enum AskUserQuestionAnswerBuilder {

    public struct Question: Equatable, Sendable {
        public let questionText: String
        public let optionLabels: [String]
        public let multiSelect: Bool

        public init(questionText: String, optionLabels: [String], multiSelect: Bool) {
            self.questionText = questionText
            self.optionLabels = optionLabels
            self.multiSelect = multiSelect
        }
    }

    public struct Answer: Equatable, Sendable {
        public let singleSelected: Int?
        public let multiSelected: Set<Int>
        public let otherText: String

        public init(singleSelected: Int? = nil, multiSelected: Set<Int> = [], otherText: String = "") {
            self.singleSelected = singleSelected
            self.multiSelected = multiSelected
            self.otherText = otherText
        }
    }

    public static func build(questions: [Question], answers: [Answer]) -> [String: String] {
        precondition(questions.count == answers.count, "questions and answers must align")
        var out: [String: String] = [:]
        for (q, a) in zip(questions, answers) {
            if let value = answer(for: q, given: a) {
                out[q.questionText] = value
            }
        }
        return out
    }

    private static func answer(for q: Question, given a: Answer) -> String? {
        let otherIndex = q.optionLabels.count
        let trimmedOther = a.otherText.trimmingCharacters(in: .whitespacesAndNewlines)

        if q.multiSelect {
            // Regular picks first, sorted by index for stable output.
            let regulars = a.multiSelected
                .filter { $0 < otherIndex }
                .sorted()
                .map { q.optionLabels[$0] }
            let otherPicked = a.multiSelected.contains(otherIndex)
            var parts = regulars
            if otherPicked && !trimmedOther.isEmpty {
                parts.append(trimmedOther)
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        } else {
            guard let idx = a.singleSelected else { return nil }
            if idx < otherIndex {
                return q.optionLabels[idx]
            }
            // Single-select Other: typed text or drop.
            return trimmedOther.isEmpty ? nil : trimmedOther
        }
    }
}
