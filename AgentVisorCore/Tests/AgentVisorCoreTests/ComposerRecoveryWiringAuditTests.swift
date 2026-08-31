import XCTest

final class ComposerRecoveryWiringAuditTests: XCTestCase {
    func testWindowComposerForwardsExplicitUncertainRetryAuthorization() throws {
        let root = repositoryRoot(from: URL(fileURLWithPath: #filePath))
        let source = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/UI/Window/WindowComposer.swift"
        ))
        guard let callStart = source.range(of: "recoveryScope.beginRetry(") else {
            return XCTFail("WindowComposer must use the app-owned retry seam.")
        }
        let callTail = source[callStart.lowerBound...]
        guard let callEnd = callTail.firstIndex(of: ")") else {
            return XCTFail("WindowComposer retry call must be complete.")
        }
        let call = callTail[..<callEnd]
        XCTAssertTrue(
            call.contains("allowUncertain: allowUncertain"),
            "Retry Anyway must carry its explicit risk authorization into the recovery store."
        )
    }
}

private extension ComposerRecoveryWiringAuditTests {
    func repositoryRoot(from testFile: URL) -> URL {
        testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
