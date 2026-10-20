import XCTest
@testable import AgentVisorNativeFocusProof

final class NativeFocusProofTests: XCTestCase {
    func testFailedSetupRetainsAnAttemptAndExplicitHumanRecoveryRecord() async throws {
        try await MainActor.run {
            let host = FixtureHost(); host.failSetup = true
            let model = ProofModel(host: host)
            model.perform(.prepare)
            let last = try XCTUnwrap(model.report.split(separator: "\n").last?.data(using: .utf8))
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: last) as? [String: Any])
            let attempt = try XCTUnwrap(record["attempt"] as? String)
            XCTAssertNotNil(UUID(uuidString: attempt))
            XCTAssertEqual(record["recoveryBanner"] as? String, "AV Focus Proof " + attempt)
            XCTAssertEqual(record["manualCleanupRequired"] as? Bool, true)
            XCTAssertTrue(model.attempted)
            XCTAssertFalse(model.prepared)
        }
    }
    func testAlreadyForegroundCannotPassWithoutBringingAnotherAppForward() throws {
        let host = FixtureHost()
        host.alreadyFrontmost = true
        let proof = NativeFocusProof(host: host)
        try proof.prepare()
        XCTAssertEqual(try proof.focus(index: 2).status, "rejected")
        XCTAssertEqual(host.focusActions, 0)
    }
    func testFailedSetupCannotCreateAnotherBatchOfWindows() throws {
        let host = FixtureHost()
        host.failSetup = true
        let proof = NativeFocusProof(host: host)
        XCTAssertThrowsError(try proof.prepare())
        XCTAssertThrowsError(try proof.prepare())
        XCTAssertEqual(host.created, 1)
    }
    func testManualRunnerStartsQuietlyAndOnlyExplicitActionsCreateFixtures() async throws {
        await MainActor.run {
            let host = FixtureHost()
            let model = ProofModel(host: host)
            XCTAssertEqual(host.created, 0)
            model.perform(.prepare)
            model.perform(.focusB)
            XCTAssertEqual(host.created, 1)
            XCTAssertTrue(model.report.contains("verified"))
            model.perform(.prepare)
            XCTAssertEqual(host.created, 1)
            XCTAssertTrue(model.report.contains("error"))
        }
    }
    func testPreparationIsSingleUseAndRejectsDuplicateNativeIDs() throws {
        let host = FixtureHost()
        let proof = NativeFocusProof(host: host)
        try proof.prepare()
        XCTAssertThrowsError(try proof.prepare())
        host.duplicateIDs = true
        XCTAssertThrowsError(try NativeFocusProof(host: host).prepare())
    }
    func testReplacedAppOrUnownedSurfaceBlocksBothFocusAndCleanup() throws {
        for replaced in [true, false] {
            let host = FixtureHost()
            let proof = NativeFocusProof(host: host)
            try proof.prepare()
            if replaced { host.liveProcess = ProofProcess(pid: 123, start: "new-start") }
            else { host.extra = [ProofSurface(window: "b-window", tab: "user-tab", terminal: "user-terminal")] }
            XCTAssertEqual(try proof.focus(index: 2).status, "rejected")
            XCTAssertEqual(host.focusActions, 0)
            XCTAssertThrowsError(try proof.cleanup())
            XCTAssertTrue(host.closed.isEmpty)
        }
    }
    func testClosedTargetIsRejectedBeforeAnyFocusAndCleanupIsOwned() throws {
        let host = FixtureHost()
        let proof = NativeFocusProof(host: host)
        try proof.prepare()
        try proof.close(index: 2)
        XCTAssertEqual(try proof.focus(index: 2).status, "rejected")
        XCTAssertEqual(host.focusActions, 0)
        XCTAssertTrue(try proof.cleanup().surfaces.isEmpty)
        XCTAssertEqual(Set(host.closed), Set([host.a, host.decoy, host.b]))
    }
    func testReadbackRequiresSameProcessFrontmostAppAndUntouchedOtherWindow() throws {
        for fault in ["process", "background", "other-window", "gone"] {
            let host = FixtureHost()
            host.fault = fault
            let proof = NativeFocusProof(host: host)
            try proof.prepare()
            XCTAssertEqual(try proof.focus(index: 2).status, "rejected", fault)
        }
    }
    func testAcceptedCommandWithWrongWindowTabOrSurfaceDoesNotPass() throws {
        for wrong in [ProofSurface(window: "other", tab: "b-tab", terminal: "b-terminal"),
                      ProofSurface(window: "b-window", tab: "other", terminal: "b-terminal"),
                      ProofSurface(window: "b-window", tab: "b-tab", terminal: "other")] {
            let host = FixtureHost()
            host.redirect = wrong
            let proof = NativeFocusProof(host: host)
            try proof.prepare()
            XCTAssertEqual(try proof.focus(index: 2).status, "rejected")
        }
    }
    func testHumanFocusActionRequiresExactNativeReadback() throws {
        let host = FixtureHost()
        let proof = NativeFocusProof(host: host)
        try proof.prepare()
        let receipt = try proof.focus(index: 2)
        XCTAssertEqual(receipt.status, "verified")
        XCTAssertEqual(receipt.expected, host.b)
        XCTAssertEqual(receipt.observed.focused, host.b)
        XCTAssertEqual(receipt.observed.selected.filter { $0.window == "a-window" }, [host.a])
    }
}

private final class FixtureHost: NativeFocusHost {
    let app = ProofProcess(pid: 123, start: "fixture-start")
    let a = ProofSurface(window: "a-window", tab: "a-tab", terminal: "a-terminal")
    let decoy = ProofSurface(window: "b-window", tab: "b-decoy", terminal: "b-decoy-terminal")
    let b = ProofSurface(window: "b-window", tab: "b-tab", terminal: "b-terminal")
    var selected: [ProofSurface] = []
    var focused: ProofSurface?
    var redirect: ProofSurface?
    var fault = ""
    var focusActions = 0
    var closed: [ProofSurface] = []
    var liveProcess: ProofProcess?
    var extra: [ProofSurface] = []
    var duplicateIDs = false
    var created = 0
    var failSetup = false
    var alreadyFrontmost = false
    func create(attempt: String) throws -> ProofFixtures {
        created += 1
        if failSetup { throw ProofError.message("Fixture setup failed after partial creation") }
        selected = [a, decoy]
        focused = decoy
        return ProofFixtures(attempt: attempt, process: app, surfaces: duplicateIDs ? [a, a, b] : [a, decoy, b])
    }
    func observe(_ fixtures: ProofFixtures) throws -> ProofObservation {
        ProofObservation(process: liveProcess ?? (fault == "process" && focusActions > 0 ? ProofProcess(pid: 123, start: "replacement") : app),
                         frontmost: fault != "background" && (alreadyFrontmost || focusActions > 0), focused: focused,
                         surfaces: [a, decoy, b].filter { !closed.contains($0) && !(fault == "gone" && focusActions > 0 && $0 == b) } + extra,
                         selected: selected.filter { !closed.contains($0) })
    }
    func focus(_ surface: ProofSurface, fixtures: ProofFixtures) throws {
        focusActions += 1
        focused = redirect ?? surface
        selected.removeAll { $0.window == surface.window }
        selected.append(surface)
        if fault == "other-window" { selected.removeAll { $0.window == "a-window" } }
    }
    func close(_ surface: ProofSurface, fixtures: ProofFixtures) throws { closed.append(surface) }
}
