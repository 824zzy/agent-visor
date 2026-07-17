import Foundation
import XCTest
@testable import AgentVisorCore

final class CodexRPCSessionTests: XCTestCase {
    func testConnectPerformsInitializeHandshake() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(transport: transport)

        let userAgent = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")
        let methods = await transport.sentMethods()

        XCTAssertEqual(userAgent, "codex-cli/test")
        XCTAssertEqual(methods, ["initialize", "initialized"])
    }

    func testNotificationIsDeliveredToHandler() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(transport: transport)
        let received = expectation(description: "notification delivered")
        await session.setHandlers(CodexRPCSessionHandlers(
            onNotification: { method, _ in
                XCTAssertEqual(method, "thread/status/changed")
                received.fulfill()
            }
        ))
        _ = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")

        try await transport.emit([
            "jsonrpc": "2.0",
            "method": "thread/status/changed",
            "params": ["threadId": "thread-1", "status": ["type": "idle"]],
        ])

        await fulfillment(of: [received], timeout: 1)
    }

    func testRespondSendsServerRequestResult() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(transport: transport)
        _ = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")

        try await session.respond(
            id: .string("approval-1"),
            result: ["decision": AnyCodable("accept")]
        )

        let lastObject = await transport.lastSentObject()
        let response = try XCTUnwrap(lastObject)
        XCTAssertEqual(response["id"] as? String, "approval-1")
        XCTAssertEqual((response["result"] as? [String: Any])?["decision"] as? String, "accept")
    }

    func testTransportCloseFailsPendingRequest() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(transport: transport)
        _ = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")

        let request = Task {
            try await session.request(
                method: CodexAppServerProtocol.Method.threadRead,
                params: CodexAppServerProtocol.threadReadParams(threadId: "thread-1")
            )
        }
        for _ in 0..<20 {
            if await transport.sentMethods().contains(CodexAppServerProtocol.Method.threadRead) {
                break
            }
            await Task.yield()
        }
        await transport.emitClose()

        do {
            _ = try await request.value
            XCTFail("Expected transport close")
        } catch {
            XCTAssertEqual(error as? CodexRPCSessionError, .transportClosed)
        }
    }

    func testRequestTimesOutWhenTransportDropsResponse() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(
            transport: transport,
            requestTimeoutNanoseconds: 20_000_000
        )
        _ = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")

        do {
            _ = try await session.request(method: "thread/read")
            XCTFail("Expected request timeout")
        } catch {
            XCTAssertEqual(
                error as? CodexRPCSessionError,
                .requestTimedOut(method: "thread/read")
            )
        }
    }

    func testCancellingRequestResumesCaller() async throws {
        let transport = ScriptedCodexRPCTransport()
        let session = CodexRPCSession(
            transport: transport,
            requestTimeoutNanoseconds: 5_000_000_000
        )
        _ = try await session.connect(clientName: "agent-visor", clientVersion: "1.0")

        let request = Task {
            try await session.request(method: "thread/read")
        }
        for _ in 0..<20 {
            if await transport.sentMethods().contains("thread/read") { break }
            await Task.yield()
        }
        request.cancel()

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private actor ScriptedCodexRPCTransport: CodexRPCTransport {
    private var onMessage: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var methods: [String] = []
    private var sentObjects: [[String: Any]] = []

    func start(
        onMessage: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws {
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func send(_ message: Data) async throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message) as? [String: Any])
        sentObjects.append(object)
        guard let method = object["method"] as? String else { return }
        methods.append(method)
        guard method == "initialize",
              let id = object["id"] else { return }
        let response = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "result": ["userAgent": "codex-cli/test"],
        ])
        onMessage?(response)
    }

    func close() async {}

    func emitClose() {
        onClose?()
    }

    func emit(_ object: [String: Any]) throws {
        onMessage?(try JSONSerialization.data(withJSONObject: object))
    }

    func sentMethods() -> [String] {
        methods
    }

    func lastSentObject() -> [String: Any]? {
        sentObjects.last
    }
}
