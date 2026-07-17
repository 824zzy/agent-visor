import Foundation

/// Pure mapping from Agent Visor's AskUserQuestion form state to Codex
/// app-server's `item/tool/requestUserInput` answer payload.
public enum CodexUserInputAnswerBuilder {
    public struct Question: Equatable, Sendable {
        public let id: String
        public let optionLabels: [String]
        public let multiSelect: Bool
        public let isOther: Bool

        public init(id: String, optionLabels: [String], multiSelect: Bool = false, isOther: Bool = false) {
            self.id = id
            self.optionLabels = optionLabels
            self.multiSelect = multiSelect
            self.isOther = isOther
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

    public static func build(questions: [Question], answers: [Answer]) -> [String: [String]] {
        precondition(questions.count == answers.count, "questions and answers must align")
        var out: [String: [String]] = [:]
        for (question, answer) in zip(questions, answers) {
            guard !question.id.isEmpty else { continue }
            let values = answerStrings(for: question, given: answer)
            if !values.isEmpty {
                out[question.id] = values
            }
        }
        return out
    }

    private static func answerStrings(for question: Question, given answer: Answer) -> [String] {
        let otherIndex = question.optionLabels.count
        let trimmedOther = answer.otherText.trimmingCharacters(in: .whitespacesAndNewlines)

        if question.optionLabels.isEmpty {
            return trimmedOther.isEmpty ? [] : [trimmedOther]
        }

        if question.multiSelect {
            var values = answer.multiSelected
                .filter { $0 < otherIndex }
                .sorted()
                .map { question.optionLabels[$0] }
            if (answer.multiSelected.contains(otherIndex) || question.isOther), !trimmedOther.isEmpty {
                values.append(trimmedOther)
            }
            return values
        }

        if let index = answer.singleSelected, index < otherIndex {
            return [question.optionLabels[index]]
        }

        if (answer.singleSelected == otherIndex || question.isOther), !trimmedOther.isEmpty {
            return [trimmedOther]
        }

        return []
    }
}
