import Foundation
import XCTest
@testable import AgentVisorCore

final class PiTtyBackfillWiringAuditTests: XCTestCase {
    func testHookResolvesAMissingPiTtyFromTheLivePidBeforeOrigin() throws {
        let source = try String(contentsOf: repoRoot()
            .appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))
        guard let start = source.range(of: "private func processHookEvent")?.lowerBound,
              let end = source.range(of: "private func codexBackedHookEvent")?.lowerBound else {
            return XCTFail("Could not isolate processHookEvent.")
        }
        let hookPath = String(source[start..<end])

        guard let merge = hookPath.range(
                of: "HookProcessMetadataPolicy.merge("
              )?.lowerBound,
              let shouldResolve = hookPath.range(
                of: "PiTtyBackfillPolicy.shouldResolveTTY("
              )?.lowerBound,
              let origin = hookPath.range(
                of: "SessionStore.originForHostedSession("
              )?.lowerBound else {
            return XCTFail("The Pi controlling-TTY backfill is missing from the hook path.")
        }

        XCTAssertLessThan(
            merge,
            shouldResolve,
            "TTY backfill must run after the PID/TTY merge produces the reported metadata."
        )
        XCTAssertLessThan(
            shouldResolve,
            origin,
            "A resolved TTY must be applied before terminal origin is computed so the row is promoted to terminal ownership."
        )
        XCTAssertTrue(
            hookPath.contains("resolvePiControllingTTY("),
            "The hook path must resolve the controlling TTY from the live process."
        )
        XCTAssertTrue(
            hookPath.contains("agentID: event.agentID"),
            "The backfill decision must use the event provider."
        )
        // Origin and the derived-metadata refresh must consume the resolved
        // TTY, not the raw merged value, or a backfilled TTY would not
        // promote the session out of the observed origin.
        XCTAssertTrue(hookPath.contains("tty: resolvedTTY"))
        XCTAssertTrue(hookPath.contains("ttyBeforeHookMerge != resolvedTTY"))
    }

    func testBackfillPolicyNormalizesSuccessfulProcessReadAndFailsClosed() {
        // The app-side resolver deliberately keeps process execution behind
        // ProcessExecutor. The Core contract is the observable boundary: a
        // successful bounded local read yields one normalized TTY, while a
        // timeout, non-zero exit, empty response, or malformed response is
        // indistinguishable from no identity evidence.
        XCTAssertEqual(
            PiTtyBackfillPolicy.tty(from: " ttys012\n", succeeded: true),
            "ttys012"
        )

        let failedReads: [(String?, Bool)] = [
            (" ttys012\n", false),
            (nil, true),
            ("", true),
            ("??\n", true),
        ]
        for (output, succeeded) in failedReads {
            XCTAssertNil(
                PiTtyBackfillPolicy.tty(from: output, succeeded: succeeded),
                "A failed or unparseable local process read must fail closed."
            )
        }

        // Pi backfill is a local identity probe, not an unbounded action.
        XCTAssertGreaterThan(SubprocessDeadlinePolicy.localRead, 0)
        XCTAssertLessThanOrEqual(SubprocessDeadlinePolicy.localRead, 10)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
