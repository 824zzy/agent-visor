import XCTest
@testable import AgentVisorCore

final class ClaudeImageBlockParserTests: XCTestCase {
    func testBase64ImageBecomesStableDataURI() {
        let block: [String: Any] = [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/png",
                "data": "abc123",
            ],
        ]

        XCTAssertEqual(
            ClaudeImageBlockParser.attachment(from: block),
            ChatImageAttachment(source: .dataURI, value: "data:image/png;base64,abc123")
        )
        XCTAssertEqual(
            ClaudeImageBlockParser.reference(from: block),
            "data:image/png;base64,abc123"
        )
    }

    func testLocalPathImageKeepsExactReference() {
        let block: [String: Any] = [
            "type": "image",
            "source": ["type": "path", "path": "/tmp/diagram.png"],
        ]
        XCTAssertEqual(
            ClaudeImageBlockParser.attachment(from: block),
            ChatImageAttachment(source: .localPath, value: "/tmp/diagram.png")
        )
    }

    func testMalformedOrNonImageBlockIsIgnored() {
        XCTAssertNil(ClaudeImageBlockParser.attachment(from: ["type": "text", "text": "x"]))
        XCTAssertNil(ClaudeImageBlockParser.attachment(from: [
            "type": "image",
            "source": ["type": "base64", "media_type": "text/plain", "data": "abc"],
        ]))
    }
}
