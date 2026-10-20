import AgentVisorNativeHelper
import Darwin
import Foundation
import XCTest

final class NativeProcessIdentityProbeTests: XCTestCase {
    func testReadsCurrentProcessIdentityAndDirectoryWithoutSpawningCommands() throws {
        let identity = try XCTUnwrap(NativeProcessIdentityProbe.read(pid: getpid()))
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.cwd, FileManager.default.currentDirectoryPath)
        XCTAssertTrue(identity.token.hasPrefix("v1:\(getpid()):"))
        XCTAssertTrue(identity.startedAt.timeIntervalSinceNow <= 0)
        XCTAssertEqual(identity.startedAt.timeIntervalSince1970.rounded(.down), identity.startedAt.timeIntervalSince1970)
    }
}
