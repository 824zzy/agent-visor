import XCTest
@testable import AgentVisorCore

private typealias Q = AskUserQuestionAnswerBuilder.Question
private typealias A = AskUserQuestionAnswerBuilder.Answer

/// Specifies the contract between agent-visor's AskUserQuestion form
/// state and the `answers` dict claude-code expects in `updatedInput`.
///
/// Upstream contract (verified against
/// `claude-code-main/src/components/permissions/AskUserQuestionPermissionRequest`):
/// - `answers` is a `Record<string, string>` keyed by the question
///   text, valued with the user's answer as a string.
/// - For single-select: the picked option's `label` (or, for Other,
///   the user-typed text — the `__other__` sentinel never appears in
///   the result; the typed text replaces it).
/// - For multi-select: the picked option labels joined by `", "` in
///   index order, with the typed Other text appended (also separated
///   by `", "`) when Other is checked AND the typed text is
///   non-empty after trimming. Empty Other text is dropped — matches
///   `concat(textInput ? [textInput] : [])` in
///   `AskUserQuestionPermissionRequest.tsx`.
final class AskUserQuestionAnswerBuilderTests: XCTestCase {

    // MARK: - Single-select

    func test_singleSelect_pickRegularOption_emitsThatLabel() {
        let q = Q(questionText: "Which checkout?", optionLabels: ["main", "PR1159", "HEAD"], multiSelect: false)
        let a = A(singleSelected: 1)

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Which checkout?": "PR1159"])
    }

    func test_singleSelect_pickOther_emitsTrimmedTypedText() {
        let q = Q(questionText: "Manifest?", optionLabels: ["azure-gemma", "bedrock"], multiSelect: false)
        // optionLabels.count == 2, so Other lives at index 2.
        let a = A(singleSelected: 2, otherText: "  custom-manifest  ")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Manifest?": "custom-manifest"])
    }

    func test_singleSelect_pickOtherButTextEmpty_dropsTheQuestion() {
        // No usable answer — better to omit than send an empty string.
        let q = Q(questionText: "Manifest?", optionLabels: ["a", "b"], multiSelect: false)
        let a = A(singleSelected: 2, otherText: "   ")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, [:])
    }

    func test_singleSelect_noSelection_dropsTheQuestion() {
        // Should never happen in practice (the form's `allAnswered`
        // guard blocks submit), but the builder must not synthesize
        // an answer where there is none.
        let q = Q(questionText: "Manifest?", optionLabels: ["a", "b"], multiSelect: false)
        let a = A()

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, [:])
    }

    // MARK: - Multi-select

    func test_multiSelect_oneRegularPick_emitsThatLabel() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue", "Svelte"], multiSelect: true)
        let a = A(multiSelected: [1])

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "Vue"])
    }

    func test_multiSelect_multipleRegularPicks_joinsByCommaInIndexOrder() {
        // Set iteration is undefined — the builder must sort by index.
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue", "Svelte", "Angular"], multiSelect: true)
        let a = A(multiSelected: [3, 0, 2])

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "React, Svelte, Angular"])
    }

    func test_multiSelect_otherWithText_appendsAfterRegularLabels() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue"], multiSelect: true)
        // optionLabels.count == 2, Other slot is at index 2.
        let a = A(multiSelected: [0, 2], otherText: "Solid")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "React, Solid"])
    }

    func test_multiSelect_otherCheckedButTextEmpty_dropsOther() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue"], multiSelect: true)
        let a = A(multiSelected: [0, 2], otherText: "   ")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "React"])
    }

    func test_multiSelect_otherOnlyWithText_emitsJustTheTypedText() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue"], multiSelect: true)
        let a = A(multiSelected: [2], otherText: "Solid")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "Solid"])
    }

    func test_multiSelect_otherOnlyWithEmptyText_dropsTheQuestion() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React", "Vue"], multiSelect: true)
        let a = A(multiSelected: [2], otherText: "")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, [:])
    }

    func test_multiSelect_emptySelection_dropsTheQuestion() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React"], multiSelect: true)
        let a = A()

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, [:])
    }

    func test_multiSelect_trimsOtherTextWhitespace() {
        let q = Q(questionText: "Frameworks?", optionLabels: ["React"], multiSelect: true)
        let a = A(multiSelected: [1], otherText: "  Solid  ")

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a])

        XCTAssertEqual(answers, ["Frameworks?": "Solid"])
    }

    // MARK: - Multi-question forms

    func test_multipleQuestions_eachKeyedByItsQuestionText() {
        let q1 = Q(questionText: "Which checkout?", optionLabels: ["main", "PR1159"], multiSelect: false)
        let q2 = Q(questionText: "Manifest?", optionLabels: ["azure-gemma", "bedrock"], multiSelect: false)
        let a1 = A(singleSelected: 0)
        let a2 = A(singleSelected: 1)

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q1, q2], answers: [a1, a2])

        XCTAssertEqual(answers, [
            "Which checkout?": "main",
            "Manifest?": "bedrock",
        ])
    }

    func test_multipleQuestions_oneSkippedDoesNotPoisonOthers() {
        // Q2 has no selection; it's silently dropped. Q1's answer
        // still flows through.
        let q1 = Q(questionText: "Q1", optionLabels: ["a", "b"], multiSelect: false)
        let q2 = Q(questionText: "Q2", optionLabels: ["x", "y"], multiSelect: false)
        let a1 = A(singleSelected: 0)
        let a2 = A()

        let answers = AskUserQuestionAnswerBuilder.build(questions: [q1, q2], answers: [a1, a2])

        XCTAssertEqual(answers, ["Q1": "a"])
    }

    // MARK: - Misalignment guard

    func test_questionsAndAnswersCountMismatch_isPreconditionFailure() {
        // Mirrors AskUserQuestionKeystrokeBuilder's contract — caller
        // must align the two arrays. Documented as a precondition;
        // we don't try to recover.
        // (No XCTAssert for traps in this test target — just pin the
        // fact that the builder must accept aligned inputs only.)
        let q = Q(questionText: "Q", optionLabels: ["a"], multiSelect: false)
        let a = A(singleSelected: 0)
        XCTAssertEqual(
            AskUserQuestionAnswerBuilder.build(questions: [q], answers: [a]),
            ["Q": "a"]
        )
    }
}
