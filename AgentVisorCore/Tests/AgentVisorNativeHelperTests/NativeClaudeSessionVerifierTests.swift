import AgentVisorCore
import AgentVisorNativeHelper
import XCTest

final class NativeClaudeSessionVerifierTests: XCTestCase {
    private let sessionId = "11111111-2222-4333-8444-555555555555"
    private let processToken = TerminalProcessIdentityToken.make(pid: 42, startTime: Date(timeIntervalSince1970: 1_700_000_000))
    private var home: URL!
    private var file: URL!
    private var target: NativeHelperTerminalTarget {
        .init(application: .ghostty, pid: 42, processStartToken: processToken, tty: "ttys001",
              cwd: "/project", claudeSessionId: sessionId)
    }
    private var record: [String: Any] {
        ["sessionId": sessionId, "cwd": "/project", "kind": "interactive", "status": "idle"]
    }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("av-claude-\(UUID().uuidString)")
        let directory = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("42.json")
    }
    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
    }
    private func write(_ record: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }

    func testOnlyTheExactCurrentInteractiveConversationIsVerified() throws {
        let verifier = NativeClaudeSessionVerifier(homeDirectory: home)
        for status in ["idle", "busy", "blocked", "waiting_for_input"] {
            try write(record.merging(["status": status]) { _, new in new })
            XCTAssertTrue(verifier.verify(target), status)
        }
        let changes: [[String: Any]] = [
            ["sessionId": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"], ["cwd": "/other"], ["kind": "bg"],
            ["parkedJobId": "aabbccdd"], ["parkedJobId": NSNull()], ["spare": true], ["entrypoint": "sdk-cli"],
        ] + ["ended", "exited", "closed", "deactivated", "inactive", "stopped", "terminated"]
            .map { ["status": $0] }
        for change in changes {
            try write(record.merging(change) { _, new in new })
            XCTAssertFalse(verifier.verify(target), "Rejected identity fields: \(change.keys.sorted())")
        }
    }

    func testMissingMalformedOrOversizedRecordsDoNotVerify() throws {
        let verifier = NativeClaudeSessionVerifier(homeDirectory: home)
        XCTAssertFalse(verifier.verify(target))
        for data in [Data(), Data("not-json".utf8), Data("[]".utf8), Data("{}".utf8), Data(repeating: 32, count: 256 * 1_024 + 1)] {
            try data.write(to: file)
            XCTAssertFalse(verifier.verify(target))
        }
        try write(record)
        XCTAssertFalse(verifier.verify(.init(application: .ghostty, pid: 43, processStartToken: "other",
            tty: "ttys001", cwd: "/project", claudeSessionId: sessionId)), "Never read another PID's file")
        XCTAssertFalse(verifier.verify(.init(application: .ghostty, pid: 42, processStartToken: "process-one",
            tty: "ttys001", cwd: "/project")), "Missing expected identity cannot authorize a conversation")
    }

    func testSessionUUIDCaseDoesNotChangeItsIdentity() throws {
        let id = "abcdef01-2345-4678-9abc-def012345678"
        try write(record.merging(["sessionId": id.uppercased()]) { _, new in new })
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: processToken, tty: "ttys001", cwd: "/project", claudeSessionId: id)
        XCTAssertTrue(NativeClaudeSessionVerifier(homeDirectory: home).verify(target))
    }

    func testRecordFromAnEarlierProcessCannotAuthenticateAReusedPID() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let target = NativeHelperTerminalTarget(application: .ghostty, pid: 42,
            processStartToken: TerminalProcessIdentityToken.make(pid: 42, startTime: start),
            tty: "ttys001", cwd: "/project", claudeSessionId: sessionId)
        try write(record)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-60)], ofItemAtPath: file.path)
        XCTAssertFalse(NativeClaudeSessionVerifier(homeDirectory: home).verify(target))
    }
}
