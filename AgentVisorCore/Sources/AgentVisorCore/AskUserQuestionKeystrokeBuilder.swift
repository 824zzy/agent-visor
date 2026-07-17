import Foundation

/// **Deprecated as of 2026-05-26.** No longer in the AskUserQuestion
/// submit path — agent-visor now responds to claude-code's
/// `PermissionRequest` hook with `behavior: 'allow' + updatedInput`
/// containing the answers structurally, instead of driving the TUI.
/// See `AskUserQuestionAnswerBuilder` for the replacement and the
/// commit that introduced it for context. Kept here (and in tests)
/// as a documented record of upstream's TUI navigation contract;
/// candidate for removal once the new path has soaked in production.
///
/// Pure synthesis of the keystroke sequence that drives claude-code's
/// AskUserQuestion TUI from a fresh "first question, no answer" state
/// to the final "Submit answers" press on the review screen.
///
/// Lifted out of `ToolResultViews.AskUserQuestionPendingContent` so the
/// algorithm can be unit-tested without standing up a SwiftUI view +
/// AppleScript runtime. The view now constructs `Question` /
/// `Answer` value types and calls `build(...)`.
///
/// Mirrors the upstream TUI shape from
/// `claude-code-main/src/components/permissions/AskUserQuestionPermissionRequest`:
/// each question is a `<Select>` (or `<SelectMulti>`) with `n` text
/// options plus an auto-appended `<input>` "Other" row at index `n`.
/// After the final answer, claude-code shows `SubmitQuestionsView`,
/// a 2-option `<Select>` whose default focus is "Submit answers" — so
/// reaching the review screen and pressing `enter` once is enough.
public enum AskUserQuestionKeystrokeBuilder {

    public struct Question: Equatable, Sendable {
        public let optionsCount: Int
        public let multiSelect: Bool

        public init(optionsCount: Int, multiSelect: Bool) {
            self.optionsCount = optionsCount
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

    /// Pause inserted after a keystroke that triggers a TUI state
    /// transition (an enter that advances to the next question, a tab
    /// that toggles input mode). Tuned to 0.25s to give React/Ink
    /// enough time to commit the new component before subsequent keys
    /// arrive — without this, the next question's first keystroke
    /// lands on a stale component and gets dropped.
    public static let stateTransitionDelay: Double = 0.25

    /// Slightly longer pause after typing the Other text, because the
    /// TextInput has to commit its value to React state before the
    /// trailing enter selects the option.
    public static let textCommitDelay: Double = 0.4

    /// Extra pause before pressing the final review-submit enter.
    /// The transition from the last question to SubmitQuestionsView
    /// is heavier than between-question transitions because React
    /// unmounts QuestionView and mounts a new component tree
    /// (QuestionNavigationBar + Review title + answer list +
    /// PermissionRuleExplanation + Select). Empirically the standard
    /// 0.25s state-transition delay isn't enough — the final enter
    /// has been observed firing while the review-screen `<Select>`
    /// is still mid-mount, which drops the keystroke or routes it
    /// somewhere unexpected and ends up triggering the tool's
    /// rejection path.
    public static let reviewMountDelay: Double = 0.8

    public static func build(questions: [Question], answers: [Answer]) -> [KeystrokeStep] {
        precondition(questions.count == answers.count, "questions and answers must align")
        var steps: [KeystrokeStep] = []
        for (q, a) in zip(questions, answers) {
            steps.append(contentsOf: buildOne(question: q, answer: a))
        }
        // Wait for SubmitQuestionsView to fully mount before pressing
        // its default-focused "Submit answers" option.
        steps.append(.delay(reviewMountDelay))
        steps.append(.key("enter"))
        return steps
    }

    private static func buildOne(question q: Question, answer a: Answer) -> [KeystrokeStep] {
        let otherIndex = q.optionsCount

        if q.multiSelect {
            return buildMulti(otherIndex: otherIndex, answer: a)
        } else {
            return buildSingle(otherIndex: otherIndex, answer: a)
        }
    }

    // MARK: - Single-select

    private static func buildSingle(otherIndex: Int, answer a: Answer) -> [KeystrokeStep] {
        guard let idx = a.singleSelected else { return [] }
        var steps: [KeystrokeStep] = []
        if idx < otherIndex {
            // Plain text option. Navigate down N times, press enter to
            // pick it. <Select>'s onChange auto-fires onAnswer, which
            // advances the form to the next question (or to the
            // SubmitQuestionsView review screen on the final question).
            steps.append(contentsOf: navigationKeys(from: 0, to: idx))
            steps.append(.key("enter"))
            steps.append(.delay(stateTransitionDelay))
        } else {
            // "Other" — input row at otherIndex. Sequence:
            //   1. arrowDown × N → land on the Other row.
            //   2. tab → focus the TextInput (per upstream's
            //      <Select>: tab on the input row enters edit mode).
            //   3. type the text.
            //   4. enter → commits the input. <Select>'s onChange
            //      fires with value="__other__", onAnswer receives the
            //      text, and the form auto-advances exactly like a
            //      plain-option pick.
            //
            // No extra arrowDown/enter is appended after the commit:
            // the form has already advanced, and SubmitQuestionsView
            // defaults focus to "Submit answers" (index 0). The
            // trailing build()-level enter alone is the review submit.
            // The previous implementation appended arrowDown+enter
            // here, which on a single-question form overshot from
            // "Submit answers" to "Cancel" and silently discarded
            // the user's answers.
            steps.append(contentsOf: navigationKeys(from: 0, to: otherIndex))
            steps.append(.key("tab"))
            steps.append(.delay(stateTransitionDelay))
            steps.append(.text(a.otherText))
            steps.append(.delay(textCommitDelay))
            steps.append(.key("enter"))
            steps.append(.delay(stateTransitionDelay))
        }
        return steps
    }

    // MARK: - Multi-select

    private static func buildMulti(otherIndex: Int, answer a: Answer) -> [KeystrokeStep] {
        // SelectMulti accepts enter as a toggle (per upstream's
        // use-multi-select-state.ts) — toggle each pick in order, then
        // press the SubmitMulti footer button.
        var steps: [KeystrokeStep] = []
        var pos = 0
        let regular = a.multiSelected.filter { $0 < otherIndex }.sorted()
        for idx in regular {
            steps.append(contentsOf: navigationKeys(from: pos, to: idx))
            steps.append(.key("enter"))
            pos = idx
        }
        let otherSelected = a.multiSelected.contains(otherIndex) &&
            !a.otherText.trimmingCharacters(in: .whitespaces).isEmpty
        if otherSelected {
            steps.append(contentsOf: navigationKeys(from: pos, to: otherIndex))
            steps.append(.key("tab"))
            steps.append(.delay(stateTransitionDelay))
            steps.append(.text(a.otherText))
            steps.append(.delay(textCommitDelay))
            // After typing, focus stays on the Other input. Tab back
            // to exit input mode so the next "down" triggers the
            // SelectMulti's onDownFromLastItem footer focus instead
            // of being absorbed by the TextInput.
            steps.append(.key("tab"))
            steps.append(.delay(stateTransitionDelay))
            pos = otherIndex
        }
        // Walk to the last option, then one more arrowDown to land on
        // the SelectMulti footer's Submit/Next button. Press enter to
        // fire onSubmit (advances to next question or to the review
        // screen).
        steps.append(contentsOf: navigationKeys(from: pos, to: otherIndex))
        steps.append(.key("arrowDown"))
        steps.append(.key("enter"))
        steps.append(.delay(stateTransitionDelay))
        return steps
    }

    private static func navigationKeys(from: Int, to: Int) -> [KeystrokeStep] {
        if from == to { return [] }
        if to > from { return Array(repeating: .key("arrowDown"), count: to - from) }
        return Array(repeating: .key("arrowUp"), count: from - to)
    }
}
