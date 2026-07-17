import XCTest
@testable import AgentVisorCore

private typealias Q = AskUserQuestionKeystrokeBuilder.Question
private typealias A = AskUserQuestionKeystrokeBuilder.Answer
private let stateDelay = AskUserQuestionKeystrokeBuilder.stateTransitionDelay
private let textDelay = AskUserQuestionKeystrokeBuilder.textCommitDelay
private let reviewDelay = AskUserQuestionKeystrokeBuilder.reviewMountDelay

final class AskUserQuestionKeystrokeBuilderTests: XCTestCase {

    // MARK: - Regression: single-select Other on the last question
    //
    // The original bug: with a single-select question ending in "Other"
    // typed text, the synthesizer emitted an extra arrowDown after
    // committing the input. claude-code's <Select> auto-advances on
    // option selection, so the extra arrowDown landed *on the next
    // screen* (SubmitQuestionsView), moving focus from "Submit answers"
    // to "Cancel". The trailing enter then confirmed Cancel — silently
    // discarding the user's answers without any indication of failure.
    //
    // Captured here as a literal sequence assertion (see
    // test_singleSelect_otherWithText below); this case is the
    // narrow regression cover.

    func test_finalEnter_isPrecededByReviewMountDelay() {
        // The transition from the last question to SubmitQuestionsView
        // is slower than between-question transitions because React
        // unmounts QuestionView and mounts a new component tree.
        // Pressing the final enter too soon was observed firing
        // before the review-screen <Select> mounted, which routed the
        // keystroke somewhere unexpected and triggered the tool's
        // rejection path. The build() trailer must always insert a
        // longer mount-time pause before the submit press.
        let q = Q(optionsCount: 3, multiSelect: false)
        let a = A(singleSelected: 0)
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        guard steps.count >= 2 else {
            XCTFail("expected at least 2 trailing steps; got \(steps)")
            return
        }
        XCTAssertEqual(steps.last, .key("enter"), "trailing step must be the review-submit enter")
        XCTAssertEqual(steps[steps.count - 2], .delay(reviewDelay), "final enter must be preceded by reviewMountDelay")
        XCTAssertGreaterThanOrEqual(reviewDelay, 0.5, "reviewMountDelay must be substantially longer than stateTransitionDelay to outlast SubmitQuestionsView's mount")
    }

    func test_singleOther_lastEnterPressIsTheReviewSubmit() {
        let questions = [Q(optionsCount: 3, multiSelect: false)]
        let answers = [A(singleSelected: 3, otherText: "x")]

        let steps = AskUserQuestionKeystrokeBuilder.build(
            questions: questions, answers: answers
        )

        // build() always appends a trailing .key("enter") for the
        // SubmitQuestionsView press. Asserting it's the final step
        // and that nothing follows it is the smallest defense
        // against accidentally re-introducing post-submit keys.
        XCTAssertEqual(steps.last, .key("enter"))
    }

    // MARK: - Single-select happy paths

    func test_singleSelect_picksOptionByIndexAndAdvances() {
        // 3 plain options, picking index 1.
        let q = Q(optionsCount: 3, multiSelect: false)
        let a = A(singleSelected: 1)
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(steps, [
            .key("arrowDown"),               // 0 → 1
            .key("enter"),                   // pick option 1; <Select> auto-advances form
            .delay(stateDelay),
            .delay(reviewDelay),             // wait for SubmitQuestionsView to mount
            .key("enter"),                   // final submit on review screen
        ])
    }

    func test_singleSelect_pickingFirstOptionEmitsNoArrows() {
        let q = Q(optionsCount: 4, multiSelect: false)
        let a = A(singleSelected: 0)
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(steps, [
            .key("enter"),                   // already on index 0
            .delay(stateDelay),
            .delay(reviewDelay),
            .key("enter"),                   // submit
        ])
    }

    func test_singleSelect_otherWithText() {
        let q = Q(optionsCount: 2, multiSelect: false)
        let a = A(singleSelected: 2, otherText: "free form")
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(steps, [
            .key("arrowDown"),               // 0 → 1
            .key("arrowDown"),               // 1 → 2 (Other slot)
            .key("tab"),                     // enter input edit mode
            .delay(stateDelay),
            .text("free form"),
            .delay(textDelay),
            .key("enter"),                   // commit input + auto-advance
            .delay(stateDelay),
            .delay(reviewDelay),
            .key("enter"),                   // submit on review (default focus = "Submit answers")
        ])
    }

    // MARK: - Multi-select happy paths

    func test_multiSelect_togglesEachPickThenSubmits() {
        // 4 plain options + Other (auto-appended at index 4). Picks
        // are 0 and 2; Other is unchecked.
        let q = Q(optionsCount: 4, multiSelect: true)
        let a = A(multiSelected: [0, 2])
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(steps, [
            .key("enter"),                   // toggle option 0 (pos=0 already)
            .key("arrowDown"),               // 0 → 1
            .key("arrowDown"),               // 1 → 2
            .key("enter"),                   // toggle option 2
            .key("arrowDown"),               // 2 → 3
            .key("arrowDown"),               // 3 → 4 (Other row — still "last item")
            .key("arrowDown"),               // last → footer (onDownFromLastItem)
            .key("enter"),                   // fire onSubmit
            .delay(stateDelay),
            .delay(reviewDelay),
            .key("enter"),                   // final review submit
        ])
    }

    func test_multiSelect_withOtherTypedText_tabsBackOutOfInput() {
        let q = Q(optionsCount: 2, multiSelect: true)
        let a = A(multiSelected: [0, 2], otherText: "extra")
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(steps, [
            .key("enter"),                   // toggle option 0
            .key("arrowDown"),               // 0 → 1
            .key("arrowDown"),               // 1 → 2 (Other)
            .key("tab"),                     // enter input mode
            .delay(stateDelay),
            .text("extra"),
            .delay(textDelay),
            .key("tab"),                     // exit input mode (so next arrowDown moves focus)
            .delay(stateDelay),
            // already on otherIndex (=2 = lastOption), so navigation is empty.
            .key("arrowDown"),               // last option → footer
            .key("enter"),                   // onSubmit
            .delay(stateDelay),
            .delay(reviewDelay),
            .key("enter"),                   // final submit
        ])
    }

    func test_multiSelect_otherCheckedButTextEmpty_isIgnored() {
        // claude-code's `concat(textInput ? [textInput] : [])` drops
        // empty Other text from final values. The synthesizer must
        // also skip the input-edit dance for an empty Other.
        let q = Q(optionsCount: 2, multiSelect: true)
        let a = A(multiSelected: [1, 2], otherText: "   ")
        let steps = AskUserQuestionKeystrokeBuilder.build(questions: [q], answers: [a])

        XCTAssertFalse(steps.contains(.key("tab")), "should not enter input mode when Other text is empty/whitespace")
        XCTAssertFalse(steps.contains(where: { if case .text = $0 { return true } else { return false } }), "should not type empty text")
    }

    // MARK: - Multi-question forms

    func test_multipleQuestions_keystrokesAreConcatenatedInOrder() {
        // Two single-select questions, picking index 1 then index 0.
        let q1 = Q(optionsCount: 3, multiSelect: false)
        let q2 = Q(optionsCount: 2, multiSelect: false)
        let a1 = A(singleSelected: 1)
        let a2 = A(singleSelected: 0)
        let steps = AskUserQuestionKeystrokeBuilder.build(
            questions: [q1, q2], answers: [a1, a2]
        )

        XCTAssertEqual(steps, [
            .key("arrowDown"), .key("enter"), .delay(stateDelay),  // q1 pick
            .key("enter"), .delay(stateDelay),                     // q2 pick (already at 0)
            .delay(reviewDelay),
            .key("enter"),                                         // review submit
        ])
    }

}
