import XCTest
@testable import AgentVisorCore

final class AgentIDTests: XCTestCase {
    func testRawValuesAreStableWireFormat() {
        // Raw values are what hook scripts stamp into the JSON payload.
        // Changing any of these is a wire-format break — keep this test
        // green or coordinate a script update.
        XCTAssertEqual(AgentID.claudeCode.rawValue, "claude")
        XCTAssertEqual(AgentID.auggie.rawValue, "auggie")
        XCTAssertEqual(AgentID.codex.rawValue, "codex")
        XCTAssertEqual(AgentID.cursor.rawValue, "cursor")
    }

    func testDecodesFromRawWireValue() throws {
        let json = #"{"agent":"auggie"}"#
        struct Probe: Codable { let agent: AgentID }
        let decoded = try JSONDecoder().decode(Probe.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.agent, .auggie)
    }

    func testDecodingUnknownAgentValueThrows() {
        let json = #"{"agent":"some-future-agent"}"#
        struct Probe: Codable { let agent: AgentID }
        XCTAssertThrowsError(try JSONDecoder().decode(Probe.self, from: Data(json.utf8)))
    }

    func testRoundTripsThroughJSON() throws {
        struct Probe: Codable, Equatable { let agent: AgentID }
        for agent in AgentID.allCases {
            let data = try JSONEncoder().encode(Probe(agent: agent))
            let back = try JSONDecoder().decode(Probe.self, from: data)
            XCTAssertEqual(back.agent, agent)
        }
    }
}
