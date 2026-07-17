import XCTest
@testable import AgentVisorCore

final class CodexWebSocketCodecTests: XCTestCase {
    func testHandshakeRequestTargetsRPCAndOmitsJSONRPCFraming() throws {
        let request = CodexWebSocketCodec.handshakeRequest(
            path: "/rpc",
            host: "localhost",
            key: "dGhlIHNhbXBsZSBub25jZQ=="
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("GET /rpc HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: localhost\r\n"))
        XCTAssertTrue(text.contains("Upgrade: websocket\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(
            request,
            Data([
                "GET /rpc HTTP/1.1",
                "Host: localhost",
                "Upgrade: websocket",
                "Connection: Upgrade",
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
                "Sec-WebSocket-Version: 13",
                "",
                "",
            ].joined(separator: "\r\n").utf8)
        )
    }

    func testHandshakeValidationUsesRFC6455AcceptValue() throws {
        let response = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Upgrade: websocket\r
            Connection: Upgrade\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            \r

            """.utf8
        )

        XCTAssertNoThrow(
            try CodexWebSocketCodec.validateHandshakeResponse(
                response,
                key: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        )
    }

    func testHandshakeValidationRequiresUpgradeHeaders() {
        let response = Data(
            """
            HTTP/1.1 101 Switching Protocols\r
            Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r
            \r

            """.utf8
        )

        XCTAssertThrowsError(
            try CodexWebSocketCodec.validateHandshakeResponse(
                response,
                key: "dGhlIHNhbXBsZSBub25jZQ=="
            )
        ) { error in
            XCTAssertEqual(error as? CodexWebSocketCodecError, .invalidHandshake)
        }
    }

    func testClientTextFrameIsMaskedUsingRFC6455Example() {
        let frame = CodexWebSocketCodec.clientFrame(
            payload: Data("Hello".utf8),
            opcode: .text,
            maskKey: [0x37, 0xFA, 0x21, 0x3D]
        )

        XCTAssertEqual(
            Array(frame),
            [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58]
        )
    }

    func testDecoderWaitsForCompleteFrameAcrossChunks() throws {
        var decoder = CodexWebSocketStreamDecoder()
        let frame = Data([0x81, 0x05]) + Data("Hello".utf8)

        XCTAssertEqual(try decoder.append(frame.prefix(3)), [])
        XCTAssertEqual(
            try decoder.append(frame.dropFirst(3)),
            [.message(Data("Hello".utf8))]
        )
    }

    func testDecoderReassemblesFragmentedTextAndSurfacesPing() throws {
        var decoder = CodexWebSocketStreamDecoder()
        let first = Data([0x01, 0x03]) + Data("Hel".utf8)
        let ping = Data([0x89, 0x01, 0x2A])
        let last = Data([0x80, 0x02]) + Data("lo".utf8)

        XCTAssertEqual(
            try decoder.append(first + ping + last),
            [.ping(Data([0x2A])), .message(Data("Hello".utf8))]
        )
    }

    func testDecoderRejectsMaskedServerFrame() {
        var decoder = CodexWebSocketStreamDecoder()
        let frame = CodexWebSocketCodec.clientFrame(
            payload: Data("Hello".utf8),
            opcode: .text,
            maskKey: [1, 2, 3, 4]
        )

        XCTAssertThrowsError(try decoder.append(frame)) { error in
            XCTAssertEqual(error as? CodexWebSocketCodecError, .maskedServerFrame)
        }
    }
}
