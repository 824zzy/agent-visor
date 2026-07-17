import XCTest
@testable import AgentVisorCore

final class CursorMCPConfigBuilderTests: XCTestCase {

    func testReturnsConfigForMatchingLockfile() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        try writeLock(dir: dir, port: 12345, workspaceFolders: ["/Users/me/projectA"], authToken: "abc-123")

        let config = CursorMCPConfigBuilder.build(forCwd: "/Users/me/projectA/src/foo.swift", lockDir: dir)
        let unwrapped = try XCTUnwrap(config)
        XCTAssertTrue(unwrapped.contains("ws://127.0.0.1:12345"), unwrapped)
        XCTAssertTrue(unwrapped.contains("abc-123"), unwrapped)
        XCTAssertTrue(unwrapped.contains("x-claude-code-ide-authorization"), unwrapped)
    }

    func testReturnsNilWhenNoLockfileMatches() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        try writeLock(dir: dir, port: 99999, workspaceFolders: ["/elsewhere"], authToken: "x")

        XCTAssertNil(CursorMCPConfigBuilder.build(forCwd: "/Users/me/projectA", lockDir: dir))
    }

    func testReturnsNilForEmptyLockDir() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }

        XCTAssertNil(CursorMCPConfigBuilder.build(forCwd: "/anything", lockDir: dir))
    }

    func testReturnsNilForMissingLockDir() {
        XCTAssertNil(CursorMCPConfigBuilder.build(forCwd: "/anything", lockDir: "/no/such/dir"))
    }

    func testLongestWorkspacePrefixWins() throws {
        // Cursor user has a monorepo open at /Users/me/mono AND a
        // sub-workspace at /Users/me/mono/sub. cwd inside sub should
        // bind to the sub lock, not the monorepo lock.
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        try writeLock(dir: dir, port: 11111, workspaceFolders: ["/Users/me/mono"], authToken: "mono-token")
        try writeLock(dir: dir, port: 22222, workspaceFolders: ["/Users/me/mono/sub"], authToken: "sub-token")

        let config = CursorMCPConfigBuilder.build(forCwd: "/Users/me/mono/sub/file.swift", lockDir: dir)
        let unwrapped = try XCTUnwrap(config)
        XCTAssertTrue(unwrapped.contains("sub-token"), unwrapped)
        XCTAssertTrue(unwrapped.contains(":22222"), unwrapped)
        XCTAssertFalse(unwrapped.contains("mono-token"), unwrapped)
    }

    func testMalformedLockFileIsSkipped() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        // Garbage file: builder should skip it and still find the valid one.
        let garbageURL = URL(fileURLWithPath: dir).appendingPathComponent("33333.lock")
        try Data("not json {{{".utf8).write(to: garbageURL)
        try writeLock(dir: dir, port: 44444, workspaceFolders: ["/Users/me/projectB"], authToken: "good-token")

        let config = CursorMCPConfigBuilder.build(forCwd: "/Users/me/projectB", lockDir: dir)
        let unwrapped = try XCTUnwrap(config)
        XCTAssertTrue(unwrapped.contains("good-token"), unwrapped)
    }

    func testFileWithoutLockExtensionIgnored() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        // A README that happens to have the right shape: should be ignored
        // because we only consider *.lock files.
        let readme = URL(fileURLWithPath: dir).appendingPathComponent("README.txt")
        let payload = #"{"workspaceFolders":["/Users/me/foo"],"authToken":"wrong"}"#
        try Data(payload.utf8).write(to: readme)
        try writeLock(dir: dir, port: 55555, workspaceFolders: ["/Users/me/foo"], authToken: "right")

        let config = CursorMCPConfigBuilder.build(forCwd: "/Users/me/foo", lockDir: dir)
        let unwrapped = try XCTUnwrap(config)
        XCTAssertTrue(unwrapped.contains("right"), unwrapped)
        XCTAssertFalse(unwrapped.contains("wrong"), unwrapped)
    }

    func testListWorkspacesAcrossLockFiles() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        try writeLock(dir: dir, port: 1, workspaceFolders: ["/Users/me/A"], authToken: "x")
        try writeLock(dir: dir, port: 2, workspaceFolders: ["/Users/me/B", "/Users/me/A"], authToken: "y")

        let folders = CursorMCPConfigBuilder.listWorkspaces(lockDir: dir)
        XCTAssertEqual(folders, ["/Users/me/A", "/Users/me/B"])
    }

    func testListWorkspacesEmptyWhenNoLocks() throws {
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        XCTAssertEqual(CursorMCPConfigBuilder.listWorkspaces(lockDir: dir), [])
    }

    func testListWorkspacesMissingDir() {
        XCTAssertEqual(CursorMCPConfigBuilder.listWorkspaces(lockDir: "/no/such/dir"), [])
    }

    func testMultipleWorkspaceFoldersInOneLock() throws {
        // A single Cursor extension-host can list multiple workspace
        // folders. Any of them prefix-matching the cwd should count.
        let dir = try makeTempLockDir()
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        try writeLock(
            dir: dir, port: 66666,
            workspaceFolders: ["/Users/me/a", "/Users/me/b"],
            authToken: "multi-token"
        )

        let configA = CursorMCPConfigBuilder.build(forCwd: "/Users/me/a/x", lockDir: dir)
        let configB = CursorMCPConfigBuilder.build(forCwd: "/Users/me/b/y", lockDir: dir)
        XCTAssertNotNil(configA)
        XCTAssertNotNil(configB)
        XCTAssertTrue(configA!.contains("multi-token"))
        XCTAssertTrue(configB!.contains("multi-token"))
    }

    // MARK: - helpers

    private func makeTempLockDir() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("av-locks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func writeLock(
        dir: String,
        port: Int,
        workspaceFolders: [String],
        authToken: String,
        ideName: String = "Cursor"
    ) throws {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(port).lock")
        let payload: [String: Any] = [
            "pid": 1,
            "workspaceFolders": workspaceFolders,
            "ideName": ideName,
            "transport": "ws",
            "runningInWindows": false,
            "authToken": authToken
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: url)
    }
}
