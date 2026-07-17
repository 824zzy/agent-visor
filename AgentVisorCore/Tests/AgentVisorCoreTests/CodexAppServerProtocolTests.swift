//
//  CodexAppServerProtocolTests.swift
//  AgentVisorCoreTests
//
//  Framing + classification for Codex's app-server JSON-RPC protocol.
//  Shapes asserted here are transcribed from the schema emitted by
//  `codex app-server generate-json-schema` (CLI 0.135.0).
//

import XCTest
@testable import AgentVisorCore

final class CodexAppServerProtocolTests: XCTestCase {

    func testVisibleUserMessageTextStripsCodexAttachmentPreamble() {
        let raw = """
        # Files mentioned by the user:

        ## codex-clipboard-a.png: /tmp/codex-clipboard-a.png

        ## My request for Codex:

        She has the access. Do you think it is fine for us to ask permission from her?
        """

        XCTAssertEqual(
            CodexUserMessageText.visibleText(raw: raw, imageCount: 1),
            "She has the access. Do you think it is fine for us to ask permission from her?"
        )
    }

    private func json(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Outgoing request encoding

    func testInitializeRequestWireShape() throws {
        let req = CodexRPCRequest(
            id: .int(1),
            method: CodexAppServerProtocol.Method.initialize,
            params: CodexAppServerProtocol.initializeParams(name: "agent-visor", version: "1.0")
        )
        let obj = json(try CodexAppServerProtocol.encodeLine(req))
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? Int, 1)
        XCTAssertEqual(obj["method"] as? String, "initialize")
        let params = obj["params"] as? [String: Any]
        let clientInfo = params?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "agent-visor")
        XCTAssertEqual(clientInfo?["version"] as? String, "1.0")
    }

    func testInitializeCanOptIntoExperimentalAPI() {
        let params = CodexAppServerProtocol.initializeParams(
            name: "agent-visor",
            version: "1.0",
            experimentalApi: true
        )

        let capabilities = params["capabilities"]?.value as? [String: Any]
        XCTAssertEqual(capabilities?["experimentalApi"] as? Bool, true)
    }

    func testAccountRateLimitsReadUsesStableMethodWithoutParams() throws {
        let request = CodexRPCRequest(
            id: .int(12),
            method: CodexAppServerProtocol.Method.accountRateLimitsRead
        )

        let object = json(try CodexAppServerProtocol.encodeLine(request))

        XCTAssertEqual(object["method"] as? String, "account/rateLimits/read")
        XCTAssertNil(object["params"])
        XCTAssertEqual(
            CodexAppServerProtocol.NotificationMethod.accountRateLimitsUpdated,
            "account/rateLimits/updated"
        )
    }

    func testTurnStartParamsCarryTextInputItem() throws {
        let req = CodexRPCRequest(
            id: .int(7),
            method: CodexAppServerProtocol.Method.turnStart,
            params: CodexAppServerProtocol.turnStartParams(threadId: "thread-abc", text: "hello codex")
        )
        let obj = json(try CodexAppServerProtocol.encodeLine(req))
        XCTAssertEqual(obj["method"] as? String, "turn/start")
        let params = obj["params"] as? [String: Any]
        XCTAssertEqual(params?["threadId"] as? String, "thread-abc")
        let input = params?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 1)
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "hello codex")
    }

    func testTurnStartParamsCarryTextAndLocalImageItems() throws {
        let req = CodexRPCRequest(
            id: .int(8),
            method: CodexAppServerProtocol.Method.turnStart,
            params: CodexAppServerProtocol.turnStartParams(
                threadId: "thread-img",
                text: "describe this",
                localImagePaths: ["/tmp/a.png", "/tmp/b.jpg"]
            )
        )
        let obj = json(try CodexAppServerProtocol.encodeLine(req))
        let params = obj["params"] as? [String: Any]
        let input = params?["input"] as? [[String: Any]]
        XCTAssertEqual(input?.count, 3)
        XCTAssertEqual(input?[0]["type"] as? String, "text")
        XCTAssertEqual(input?[0]["text"] as? String, "describe this")
        XCTAssertEqual(input?[1]["type"] as? String, "localImage")
        XCTAssertEqual(input?[1]["path"] as? String, "/tmp/a.png")
        XCTAssertEqual(input?[2]["type"] as? String, "localImage")
        XCTAssertEqual(input?[2]["path"] as? String, "/tmp/b.jpg")
    }

    func testTurnStartParamsCarryImageOnlyInputItem() throws {
        let params = CodexAppServerProtocol.turnStartParams(
            threadId: "thread-img-only",
            text: "",
            localImagePaths: ["/tmp/only.png"]
        )
        let input = params["input"]?.value as? [[String: String]]
        XCTAssertEqual(input, [["type": "localImage", "path": "/tmp/only.png"]])
    }

    func testThreadStartParamsCarryWorkingDirectoryAndPermissionOverrides() throws {
        let req = CodexRPCRequest(
            id: .int(9),
            method: CodexAppServerProtocol.Method.threadStart,
            params: CodexAppServerProtocol.threadStartParams(
                cwd: "/tmp/project",
                approvalPolicy: "never",
                sandboxPolicyType: "danger-full-access"
            )
        )

        let obj = json(try CodexAppServerProtocol.encodeLine(req))
        XCTAssertEqual(obj["method"] as? String, "thread/start")
        let params = obj["params"] as? [String: Any]
        XCTAssertEqual(params?["cwd"] as? String, "/tmp/project")
        XCTAssertEqual(params?["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params?["sandbox"] as? String, "danger-full-access")
        XCTAssertEqual(params?["threadSource"] as? String, "user")
    }

    func testTurnStartParamsCarryFullAccessOverrides() throws {
        let params = CodexAppServerProtocol.turnStartParams(
            threadId: "T1",
            text: "continue",
            approvalPolicy: "never",
            sandboxPolicyType: "danger-full-access"
        )

        XCTAssertEqual(params["approvalPolicy"]?.value as? String, "never")
        let sandboxPolicy = params["sandboxPolicy"]?.value as? [String: Any]
        XCTAssertEqual(sandboxPolicy?["type"] as? String, "dangerFullAccess")
    }

    func testThreadResumeParamsCarryThreadId() throws {
        let params = CodexAppServerProtocol.threadResumeParams(threadId: "T1")
        let req = CodexRPCRequest(id: .int(2), method: CodexAppServerProtocol.Method.threadResume, params: params)
        let obj = json(try CodexAppServerProtocol.encodeLine(req))
        XCTAssertEqual((obj["params"] as? [String: Any])?["threadId"] as? String, "T1")
    }

    func testThreadReadParamsRequestSummaryWithoutTurns() {
        let params = CodexAppServerProtocol.threadReadParams(threadId: "T1")

        XCTAssertEqual(params["threadId"]?.value as? String, "T1")
        XCTAssertEqual(params["includeTurns"]?.value as? Bool, false)
    }

    func testThreadResumeParamsCarryPermissionOverrides() throws {
        let params = CodexAppServerProtocol.threadResumeParams(
            threadId: "T1",
            approvalPolicy: "never",
            sandboxPolicyType: "dangerFullAccess"
        )

        XCTAssertEqual(params["approvalPolicy"]?.value as? String, "never")
        XCTAssertEqual(params["sandbox"]?.value as? String, "danger-full-access")
    }

    func testThreadResumeCanSubscribeWithoutLoadingTurns() {
        let params = CodexAppServerProtocol.threadResumeParams(
            threadId: "T1",
            excludeTurns: true
        )

        XCTAssertEqual(params["excludeTurns"]?.value as? Bool, true)
    }

    func testThreadUnsubscribeParamsCarryThreadId() {
        let params = CodexAppServerProtocol.threadUnsubscribeParams(threadId: "T1")

        XCTAssertEqual(params["threadId"]?.value as? String, "T1")
        XCTAssertEqual(CodexAppServerProtocol.Method.threadLoadedList, "thread/loaded/list")
    }

    func testInitializedIsANotificationWithNoId() throws {
        let note = CodexRPCNotificationOut(method: CodexAppServerProtocol.Method.initialized)
        let obj = json(try CodexAppServerProtocol.encodeLine(note))
        XCTAssertEqual(obj["method"] as? String, "initialized")
        XCTAssertNil(obj["id"])
    }

    func testResponseOutCarriesIdAndResult() throws {
        let resp = CodexRPCResponseOut(id: .string("req-9"), result: ["decision": AnyCodable("accept")])
        let obj = json(try CodexAppServerProtocol.encodeLine(resp))
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["id"] as? String, "req-9")
        XCTAssertEqual((obj["result"] as? [String: Any])?["decision"] as? String, "accept")
    }

    func testRPCIDRoundTripsBothForms() throws {
        for id in [CodexRPCID.int(42), CodexRPCID.string("abc")] {
            let data = try JSONEncoder().encode(id)
            let back = try JSONDecoder().decode(CodexRPCID.self, from: data)
            XCTAssertEqual(id, back)
        }
    }

    // MARK: - Inbound classification

    func testClassifyResponseToOurRequest() {
        let line = #"{"id":1,"result":{"userAgent":"agent-visor/0.135.0"}}"#.data(using: .utf8)!
        guard case let .response(id, box) = CodexAppServerProtocol.classify(line) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, .int(1))
        XCTAssertEqual(box.string("userAgent"), "agent-visor/0.135.0")
    }

    func testClassifyServerRequestNeedingReply() {
        // An approval request: has BOTH id and method.
        let line = #"""
        {"id":"abc-1","method":"item/commandExecution/requestApproval","params":{"threadId":"T1","turnId":"U1","command":"rm -rf build","itemId":"I1"}}
        """#.data(using: .utf8)!
        guard case let .serverRequest(id, method, params) = CodexAppServerProtocol.classify(line) else {
            return XCTFail("expected serverRequest")
        }
        XCTAssertEqual(id, .string("abc-1"))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
        XCTAssertEqual(params.string("command"), "rm -rf build")
        XCTAssertTrue(CodexAppServerProtocol.ServerRequestMethod.isHandledApproval(method))
        XCTAssertEqual(CodexAppServerProtocol.ServerRequestMethod.kind(method), .approval)
    }

    func testPermissionsApprovalIsHandled() {
        XCTAssertTrue(CodexAppServerProtocol.ServerRequestMethod.isHandledApproval(
            CodexAppServerProtocol.ServerRequestMethod.permissionsApproval
        ))
    }

    func testRequestUserInputIsHandledAsUserInputNotApproval() {
        let method = CodexAppServerProtocol.ServerRequestMethod.requestUserInput

        XCTAssertEqual(CodexAppServerProtocol.ServerRequestMethod.kind(method), .userInput)
        XCTAssertTrue(CodexAppServerProtocol.ServerRequestMethod.isHandledServerRequest(method))
        XCTAssertFalse(CodexAppServerProtocol.ServerRequestMethod.isHandledApproval(method))
    }

    func testUnknownServerRequestIsUnsupported() {
        let method = "mcpServer/elicitation/request"

        XCTAssertEqual(CodexAppServerProtocol.ServerRequestMethod.kind(method), .unsupported)
        XCTAssertFalse(CodexAppServerProtocol.ServerRequestMethod.isHandledServerRequest(method))
        XCTAssertFalse(CodexAppServerProtocol.ServerRequestMethod.isHandledApproval(method))
    }

    func testClassifyNotification() {
        let line = #"{"method":"item/agentMessage/delta","params":{"threadId":"T1","turnId":"U1","delta":"Hel"}}"#
            .data(using: .utf8)!
        guard case let .notification(method, params) = CodexAppServerProtocol.classify(line) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(method, "item/agentMessage/delta")
        XCTAssertEqual(params.string("delta"), "Hel")
    }

    func testAssistantDeltaNotificationParsesSyntheticItemId() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turnId": "U1",
            "itemId": "I1",
            "delta": "Hel",
        ])
        let delta = CodexAssistantDeltaNotification(
            method: CodexAppServerProtocol.NotificationMethod.agentMessageDelta,
            params: params
        )
        XCTAssertEqual(delta?.threadId, "T1")
        XCTAssertEqual(delta?.turnId, "U1")
        XCTAssertEqual(delta?.itemId, "I1")
        XCTAssertEqual(delta?.delta, "Hel")
        XCTAssertEqual(delta?.syntheticItemId, "codex-stream-I1")
    }

    func testAssistantDeltaNotificationFallsBackToTurnIdWhenItemIdMissing() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turnId": "U1",
            "delta": "Hel",
        ])
        let delta = CodexAssistantDeltaNotification(
            method: CodexAppServerProtocol.NotificationMethod.agentMessageDelta,
            params: params
        )
        XCTAssertEqual(delta?.itemId, "U1")
        XCTAssertEqual(delta?.syntheticItemId, "codex-stream-U1")
    }

    func testTurnStartedNotificationParsesUserMessage() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turn": [
                "id": "turn-1",
                "status": "running",
                "items": [
                    [
                        "id": "item-user-1",
                        "type": "userMessage",
                        "content": [
                            ["type": "text", "text": "Please inspect this bug"],
                        ],
                    ],
                ],
            ],
        ])

        let userMessage = CodexTurnUserMessageNotification(
            method: CodexAppServerProtocol.NotificationMethod.turnStarted,
            params: params
        )

        XCTAssertEqual(userMessage?.threadId, "T1")
        XCTAssertEqual(userMessage?.turnId, "turn-1")
        XCTAssertEqual(userMessage?.itemId, "item-user-1")
        XCTAssertEqual(userMessage?.text, "Please inspect this bug")
        XCTAssertEqual(userMessage?.images, [])
        XCTAssertEqual(userMessage?.syntheticItemId, "codex-stream-user-item-user-1")
    }

    func testTurnStartedNotificationStripsCodexAttachmentPreamble() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turn": [
                "id": "turn-1",
                "status": "running",
                "items": [
                    [
                        "id": "item-user-1",
                        "type": "userMessage",
                        "content": [
                            [
                                "type": "text",
                                "text": "Files mentioned by the user:\n\ncodex-clipboard-a.png: /tmp/codex-clipboard-a.png\n\nMy request for Codex:\n\nShe has the access. Do you think it is fine for us to ask permission from her?",
                            ],
                            ["type": "localImage", "path": "/tmp/codex-clipboard-a.png"],
                        ],
                    ],
                ],
            ],
        ])

        let userMessage = CodexTurnUserMessageNotification(
            method: CodexAppServerProtocol.NotificationMethod.turnStarted,
            params: params
        )

        XCTAssertEqual(userMessage?.text, "She has the access. Do you think it is fine for us to ask permission from her?")
        XCTAssertEqual(userMessage?.images, [
            CodexParsedImage(source: .localPath, value: "/tmp/codex-clipboard-a.png")
        ])
    }

    func testTurnStartedNotificationPreservesImageOnlyContentWithoutPlaceholderText() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turn": [
                "id": "turn-1",
                "status": "running",
                "items": [
                    [
                        "id": "item-user-1",
                        "type": "userMessage",
                        "content": [
                            ["type": "localImage", "path": "/tmp/a.png"],
                        ],
                    ],
                ],
            ],
        ])

        let userMessage = CodexTurnUserMessageNotification(
            method: CodexAppServerProtocol.NotificationMethod.turnStarted,
            params: params
        )

        XCTAssertEqual(userMessage?.text, "")
        XCTAssertEqual(userMessage?.images, [
            CodexParsedImage(source: .localPath, value: "/tmp/a.png")
        ])
    }

    func testTurnStartedNotificationRejectsMissingUserMessage() {
        let params = AnyCodableEquatableBox([
            "threadId": "T1",
            "turn": [
                "id": "turn-1",
                "status": "running",
                "items": [],
            ],
        ])

        XCTAssertNil(CodexTurnUserMessageNotification(
            method: CodexAppServerProtocol.NotificationMethod.turnStarted,
            params: params
        ))
    }

    func testClassifyErrorResponse() {
        let line = #"{"id":3,"error":{"code":-32601,"message":"method not found"}}"#.data(using: .utf8)!
        guard case let .error(id, code, message) = CodexAppServerProtocol.classify(line) else {
            return XCTFail("expected error")
        }
        XCTAssertEqual(id, .int(3))
        XCTAssertEqual(code, -32601)
        XCTAssertEqual(message, "method not found")
    }

    func testClassifyUnrecognizedLine() {
        let line = "not json at all".data(using: .utf8)!
        guard case .unrecognized = CodexAppServerProtocol.classify(line) else {
            return XCTFail("expected unrecognized")
        }
    }

    func testNotificationVsServerRequestDistinguishedByIdPresence() {
        // Same method string, but the one WITHOUT an id is a notification,
        // and the one WITH an id is a request needing a reply. This is the
        // crux of the dispatch logic.
        let noteObj: [String: Any] = ["method": "x/y", "params": [:]]
        let reqObj: [String: Any] = ["id": 5, "method": "x/y", "params": [:]]
        if case .notification = CodexAppServerProtocol.classify(object: noteObj) {} else {
            XCTFail("no-id → notification")
        }
        if case .serverRequest = CodexAppServerProtocol.classify(object: reqObj) {} else {
            XCTFail("id+method → serverRequest")
        }
    }
}
