import XCTest
@testable import AgentVisorCore

/// The fingerprint is a content hash over the *answer-affecting* shape of
/// an AskUserQuestion prompt. It's the cache key for an in-flight draft
/// stored on `SessionStore`: when the user navigates away from the chat
/// and back, we use the fingerprint to decide whether the saved draft is
/// still valid for the prompt now displayed.
///
/// The cases below pin the fingerprint inputs:
///   - question text, multiSelect flag, option labels, option ORDER, and
///     question count CHANGE the fingerprint (drafts must not survive
///     these — they'd associate stored answers with the wrong content).
///   - `header` and option `description` do NOT (they're presentational
///     only; an edit there shouldn't invalidate the user's typing).
///
/// We do not assert specific hash strings — only equality / inequality
/// against a baseline. Otherwise a hash-implementation swap would break
/// every test for no semantic reason.
final class AskUserQuestionDraftFingerprintTests: XCTestCase {

    // MARK: - Helpers

    private func makeQuestion(
        question: String = "Pick one",
        header: String = "h1",
        multiSelect: Bool = false,
        options: [(String, String)] = [("A", "first"), ("B", "second")]
    ) -> AskUserQuestionDraftFingerprint.Question {
        let opts = options.map {
            AskUserQuestionDraftFingerprint.Option(label: $0.0, description: $0.1)
        }
        return .init(question: question, header: header, options: opts, multiSelect: multiSelect)
    }

    // MARK: - Stable on no-op

    func test_sameInput_sameFingerprint() {
        let qs = [makeQuestion()]
        XCTAssertEqual(
            AskUserQuestionDraftFingerprint.compute(questions: qs),
            AskUserQuestionDraftFingerprint.compute(questions: qs)
        )
    }

    // MARK: - Inputs that MUST change the fingerprint

    func test_questionTextEdit_changesFingerprint() {
        let baseline = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(question: "Pick one")])
        let edited = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(question: "Choose one")])
        XCTAssertNotEqual(baseline, edited)
    }

    func test_optionLabelEdit_changesFingerprint() {
        let baseline = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("A", "x"), ("B", "y")])
        ])
        let edited = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("Apple", "x"), ("B", "y")])
        ])
        XCTAssertNotEqual(baseline, edited)
    }

    func test_optionReorder_changesFingerprint() {
        // Indices are how stored selections are addressed. Reorder ⇒ new mapping.
        let baseline = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("A", "x"), ("B", "y")])
        ])
        let reordered = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("B", "y"), ("A", "x")])
        ])
        XCTAssertNotEqual(baseline, reordered)
    }

    func test_multiSelectFlip_changesFingerprint() {
        let single = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(multiSelect: false)])
        let multi = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(multiSelect: true)])
        XCTAssertNotEqual(single, multi)
    }

    func test_questionCountChange_changesFingerprint() {
        let one = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion()])
        let two = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(), makeQuestion(question: "Pick another")])
        XCTAssertNotEqual(one, two)
    }

    func test_questionOrderSwap_changesFingerprint() {
        let q1 = makeQuestion(question: "First")
        let q2 = makeQuestion(question: "Second")
        XCTAssertNotEqual(
            AskUserQuestionDraftFingerprint.compute(questions: [q1, q2]),
            AskUserQuestionDraftFingerprint.compute(questions: [q2, q1])
        )
    }

    // MARK: - Inputs that MUST NOT change the fingerprint

    func test_headerEdit_doesNotChangeFingerprint() {
        // `header` is the chip label only; it doesn't affect what the
        // user is answering. Editing it shouldn't trash the draft.
        let baseline = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(header: "Old chip")])
        let edited = AskUserQuestionDraftFingerprint.compute(questions: [makeQuestion(header: "New chip")])
        XCTAssertEqual(baseline, edited)
    }

    func test_descriptionEdit_doesNotChangeFingerprint() {
        // Option `description` is supplementary text under the label;
        // selections are by label/index, so a description edit should
        // preserve the draft.
        let baseline = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("A", "first"), ("B", "second")])
        ])
        let edited = AskUserQuestionDraftFingerprint.compute(questions: [
            makeQuestion(options: [("A", "REWRITTEN"), ("B", "second")])
        ])
        XCTAssertEqual(baseline, edited)
    }

    // MARK: - Determinism

    func test_fingerprint_isDeterministicAcrossCalls() {
        // Guard against any implementation that introduces non-determinism
        // (e.g. an unordered dictionary iteration leaking into the hash).
        let qs = [
            makeQuestion(question: "First", options: [("A", "x"), ("B", "y"), ("C", "z")]),
            makeQuestion(question: "Second", multiSelect: true, options: [("X", "1"), ("Y", "2")]),
        ]
        let first = AskUserQuestionDraftFingerprint.compute(questions: qs)
        for _ in 0..<10 {
            XCTAssertEqual(AskUserQuestionDraftFingerprint.compute(questions: qs), first)
        }
    }
}
