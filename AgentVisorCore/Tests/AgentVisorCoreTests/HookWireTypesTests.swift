import XCTest
@testable import AgentVisorCore

/// Pins the Swift→Python wire format for hook responses. The names
/// here are load-bearing: the Python hook script (`agent-visor-state.py`)
/// reads the snake_case keys, and getting a casing wrong silently
/// drops the field on the floor.
final class HookWireTypesTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Encoding shape

    func test_encodesUpdatedInputAsSnakeCase() throws {
        let response = HookResponse(
            decision: "allow",
            updatedInput: ["answers": AnyCodable(["q": "a"])]
        )

        let json = try jsonObject(from: response)

        XCTAssertNotNil(json["updated_input"], "missing snake_case key — Python hook will not see it")
        XCTAssertNil(json["updatedInput"], "camelCase key leaked — would break the snake_case wire convention with Python")
    }

    func test_encodesDecisionAndReasonAtTopLevel() throws {
        let response = HookResponse(decision: "deny", reason: "Cancelled by user")

        let json = try jsonObject(from: response)

        XCTAssertEqual(json["decision"] as? String, "deny")
        XCTAssertEqual(json["reason"] as? String, "Cancelled by user")
    }

    func test_omitsUpdatedInputWhenNil() throws {
        let response = HookResponse(decision: "allow")

        let json = try jsonObject(from: response)

        XCTAssertNil(json["updated_input"], "nil updatedInput must not appear on the wire — would confuse the Python hook")
    }

    func test_omitsReasonWhenNil() throws {
        let response = HookResponse(decision: "allow")

        let json = try jsonObject(from: response)

        XCTAssertNil(json["reason"])
    }

    func test_encodesUpdatedPermissionsAsSnakeCase() throws {
        let suggestion: [String: Any] = [
            "type": "addRules",
            "rules": [["toolName": "Bash", "ruleContent": "git status"]],
            "behavior": "allow",
            "destination": "projectSettings",
        ]
        let response = HookResponse(
            decision: "allow",
            updatedPermissions: [AnyCodable(suggestion)]
        )

        let json = try jsonObject(from: response)

        XCTAssertNotNil(json["updated_permissions"], "missing snake_case key — Python hook will not see it")
        XCTAssertNil(json["updatedPermissions"], "camelCase key leaked — would break the snake_case wire convention with Python")
        XCTAssertEqual((json["updated_permissions"] as? [Any])?.count, 1)
    }

    func test_omitsUpdatedPermissionsWhenNil() throws {
        let response = HookResponse(decision: "allow")

        let json = try jsonObject(from: response)

        XCTAssertNil(json["updated_permissions"], "nil updatedPermissions must not appear on the wire")
    }

    // MARK: - Roundtrip

    func test_roundtrip_preservesNestedAnyCodableValues() throws {
        let answers: [String: Any] = ["Q1": "a, b", "Q2": "c"]
        let questions: [[String: Any]] = [
            ["question": "Q1", "options": [["label": "a"], ["label": "b"]]],
            ["question": "Q2", "options": [["label": "c"]]],
        ]
        let original = HookResponse(
            decision: "allow",
            updatedInput: [
                "questions": AnyCodable(questions),
                "answers": AnyCodable(answers),
            ]
        )

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HookResponse.self, from: data)

        XCTAssertEqual(decoded.decision, "allow")
        XCTAssertNil(decoded.reason)
        guard let updatedInput = decoded.updatedInput else {
            XCTFail("updated_input dropped during roundtrip")
            return
        }
        XCTAssertEqual(updatedInput.keys.sorted(), ["answers", "questions"])

        // Spot-check the nested shapes survived AnyCodable.
        let decodedAnswers = updatedInput["answers"]?.value as? [String: String]
        XCTAssertEqual(decodedAnswers, ["Q1": "a, b", "Q2": "c"])

        let decodedQuestions = updatedInput["questions"]?.value as? [[String: Any]]
        XCTAssertEqual(decodedQuestions?.count, 2)
        XCTAssertEqual(decodedQuestions?[0]["question"] as? String, "Q1")
    }

    // MARK: - AnyCodable shape preservation
    //
    // The questions payload claude-code expects is an array of dicts
    // with mixed-type values (strings, bools, nested arrays). This
    // test pins that AnyCodable encodes/decodes that shape losslessly.

    func test_anyCodable_preservesArrayOfDicts() throws {
        let payload: [[String: Any]] = [
            ["question": "Q1", "multiSelect": false, "options": [["label": "a"], ["label": "b"]]],
        ]
        let wrapped = AnyCodable(payload)

        let data = try encoder.encode(wrapped)
        let decoded = try decoder.decode(AnyCodable.self, from: data)

        let unwrapped = decoded.value as? [[String: Any]]
        XCTAssertEqual(unwrapped?.count, 1)
        XCTAssertEqual(unwrapped?[0]["question"] as? String, "Q1")
        XCTAssertEqual(unwrapped?[0]["multiSelect"] as? Bool, false)
        let nestedOptions = unwrapped?[0]["options"] as? [[String: Any]]
        XCTAssertEqual(nestedOptions?.count, 2)
        XCTAssertEqual(nestedOptions?[0]["label"] as? String, "a")
    }

    // MARK: - Helpers

    private func jsonObject(from value: HookResponse) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "HookWireTypesTests", code: 0)
        }
        return obj
    }
}
