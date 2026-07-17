//
//  CodexApprovalDecisionMapperTests.swift
//  AgentVisorCoreTests
//
//  Truth table for mapping agent-visor's approval intent onto the
//  per-request-type decision vocabulary Codex's app-server expects.
//

import XCTest
@testable import AgentVisorCore

final class CodexApprovalDecisionMapperTests: XCTestCase {

    private func decisionString(method: String, intent: CodexApprovalIntent) -> String? {
        let result = CodexApprovalDecisionMapper.result(for: method, intent: intent)
        return (result?["decision"]?.value) as? String
    }

    func testCommandExecutionVocabulary() {
        let m = CodexAppServerProtocol.ServerRequestMethod.commandExecutionApproval
        XCTAssertEqual(decisionString(method: m, intent: .allow), "accept")
        XCTAssertEqual(decisionString(method: m, intent: .allowForSession), "acceptForSession")
        XCTAssertEqual(decisionString(method: m, intent: .deny), "decline")
        XCTAssertEqual(decisionString(method: m, intent: .cancel), "cancel")
    }

    func testFileChangeVocabulary() {
        let m = CodexAppServerProtocol.ServerRequestMethod.fileChangeApproval
        XCTAssertEqual(decisionString(method: m, intent: .allow), "accept")
        XCTAssertEqual(decisionString(method: m, intent: .allowForSession), "acceptForSession")
        XCTAssertEqual(decisionString(method: m, intent: .deny), "decline")
        XCTAssertEqual(decisionString(method: m, intent: .cancel), "cancel")
    }

    func testReviewDecisionVocabularyForExecAndApplyPatch() {
        // The legacy exec/applyPatch requests use ReviewDecision spelling.
        for m in [
            CodexAppServerProtocol.ServerRequestMethod.execCommandApproval,
            CodexAppServerProtocol.ServerRequestMethod.applyPatchApproval,
        ] {
            XCTAssertEqual(decisionString(method: m, intent: .allow), "approved")
            XCTAssertEqual(decisionString(method: m, intent: .allowForSession), "approved_for_session")
            XCTAssertEqual(decisionString(method: m, intent: .deny), "denied")
            XCTAssertEqual(decisionString(method: m, intent: .cancel), "abort")
        }
    }

    func testPermissionsApprovalGrantsRequestedProfileForTurn() {
        let m = CodexAppServerProtocol.ServerRequestMethod.permissionsApproval
        let params = AnyCodableEquatableBox([
            "permissions": [
                "fileSystem": [
                    "entries": [
                        [
                            "access": "write",
                            "path": ["type": "path", "path": "/tmp/demo"],
                        ]
                    ]
                ],
                "network": ["enabled": true],
            ]
        ])

        let result = CodexApprovalDecisionMapper.result(for: m, intent: .allow, requestParams: params)
        let permissions = result?["permissions"]?.value as? [String: Any]
        let fileSystem = permissions?["fileSystem"] as? [String: Any]
        let network = permissions?["network"] as? [String: Any]
        XCTAssertNotNil(fileSystem?["entries"])
        XCTAssertEqual(network?["enabled"] as? Bool, true)
        XCTAssertEqual(result?["scope"]?.value as? String, "turn")
    }

    func testPermissionsApprovalCanGrantForSession() {
        let m = CodexAppServerProtocol.ServerRequestMethod.permissionsApproval
        let params = AnyCodableEquatableBox(["permissions": ["network": ["enabled": true]]])

        let result = CodexApprovalDecisionMapper.result(for: m, intent: .allowForSession, requestParams: params)

        XCTAssertEqual(result?["scope"]?.value as? String, "session")
    }

    func testPermissionsDenialGrantsEmptyProfile() {
        let m = CodexAppServerProtocol.ServerRequestMethod.permissionsApproval
        let params = AnyCodableEquatableBox(["permissions": ["network": ["enabled": true]]])

        let result = CodexApprovalDecisionMapper.result(for: m, intent: .deny, requestParams: params)
        let permissions = result?["permissions"]?.value as? [String: Any]

        XCTAssertEqual(permissions?.isEmpty, true)
        XCTAssertEqual(result?["scope"]?.value as? String, "turn")
    }

    func testUnknownMethodReturnsNil() {
        // A server-request we don't know how to answer must not produce
        // a guessed decision — the transport rejects it instead.
        XCTAssertNil(CodexApprovalDecisionMapper.result(for: "mcpServer/elicitation/request", intent: .allow))
    }

    func testUserInputResultShape() {
        let result = CodexApprovalDecisionMapper.userInputResult(
            answersByQuestionId: ["q1": ["Yes"], "q2": ["A", "B"]]
        )
        // { answers: { q1: { answers: ["Yes"] }, q2: { answers: ["A","B"] } } }
        let answers = result["answers"]?.value as? [String: Any]
        let q1 = answers?["q1"] as? [String: Any]
        XCTAssertEqual(q1?["answers"] as? [String], ["Yes"])
        let q2 = answers?["q2"] as? [String: Any]
        XCTAssertEqual(q2?["answers"] as? [String], ["A", "B"])
    }

    func testCodexUserInputAnswerBuilderKeysByQuestionId() {
        let questions = [
            CodexUserInputAnswerBuilder.Question(
                id: "confirm",
                optionLabels: ["Yes", "No"]
            ),
            CodexUserInputAnswerBuilder.Question(
                id: "details",
                optionLabels: [],
                isOther: true
            ),
        ]
        let answers = [
            CodexUserInputAnswerBuilder.Answer(singleSelected: 0),
            CodexUserInputAnswerBuilder.Answer(otherText: "ship it"),
        ]

        XCTAssertEqual(
            CodexUserInputAnswerBuilder.build(questions: questions, answers: answers),
            ["confirm": ["Yes"], "details": ["ship it"]]
        )
    }

    func testCodexUserInputResultFromCapturedFixtureShape() throws {
        let fixture = #"""
        {"id":"req-1","method":"item/tool/requestUserInput","params":{"threadId":"T1","turnId":"U1","questions":[{"id":"q1","question":"Pick one","isOther":false,"options":[{"label":"Alpha","description":"first"},{"label":"Beta","description":"second"}]},{"id":"q2","question":"Add detail","isOther":true,"options":[]}]}}
        """#.data(using: .utf8)!

        guard case let .serverRequest(_, method, params) = CodexAppServerProtocol.classify(fixture) else {
            return XCTFail("expected requestUserInput server request")
        }
        XCTAssertEqual(CodexAppServerProtocol.ServerRequestMethod.kind(method), .userInput)
        let rawQuestions = try XCTUnwrap(params.dictionary?["questions"] as? [[String: Any]])
        XCTAssertEqual(rawQuestions.count, 2)
        XCTAssertEqual(rawQuestions.first?["id"] as? String, "q1")
        XCTAssertEqual(rawQuestions.first?["question"] as? String, "Pick one")
        let firstOptions = try XCTUnwrap(rawQuestions.first?["options"] as? [[String: Any]])
        XCTAssertEqual(firstOptions.first?["label"] as? String, "Alpha")
    }
}
