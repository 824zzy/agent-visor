import Foundation
import XCTest

final class PiRebootRestorationWiringAuditTests: XCTestCase {
    func testAppLifecycleStartsRestorationOnlyAfterTheHookSocketCanObserveLiveOwners() throws {
        let root = repoRoot()
        let appDelegate = try String(contentsOf: root.appendingPathComponent("AgentVisor/App/AppDelegate.swift"))
        let monitor = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/ClaudeSessionMonitor.swift"
        ))

        XCTAssertTrue(appDelegate.contains("NSWorkspace.willPowerOffNotification"))
        XCTAssertFalse(appDelegate.contains("PiRebootRestorationManager.shared.start"))
        XCTAssertTrue(appDelegate.contains("PiRebootRestorationManager.shared.freezeForSystemPowerOff"))
        XCTAssertTrue(appDelegate.contains("PiRebootRestorationManager.shared.invalidateForCleanAppTermination"))
        XCTAssertTrue(
            appDelegate.contains("sessionMonitor?.startMonitoring()"),
            "The hook listener and restoration preflight must start even when session pills are hidden."
        )
        XCTAssertTrue(monitor.contains("guard !isMonitoring else { return }"))

        guard let socketStart = monitor.range(of: "HookSocketServer.shared.start(")?.lowerBound,
              let restorationStart = monitor.range(
                of: "PiRebootRestorationManager.shared.start()",
                range: socketStart..<monitor.endIndex
              )?.lowerBound else {
            return XCTFail("Restoration must start after the hook socket is listening.")
        }
        XCTAssertLessThan(socketStart, restorationStart)
    }

    func testPriorBootClaimExcludesExactOwnersObservedDuringPreflight() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"
        ))

        guard let start = manager.range(of: "func start(")?.lowerBound,
              let claim = manager.range(
                of: "claimRestorePlan",
                range: start..<manager.endIndex
              )?.lowerBound else {
            return XCTFail("Expected restoration startup and claim.")
        }
        let preclaim = String(manager[start..<claim])
        XCTAssertTrue(preclaim.contains("priorBootPreflightInterval"))
        XCTAssertTrue(preclaim.contains("Task.sleep"))

        XCTAssertTrue(
            manager.contains("liveSessionIDs: liveSessionIDs.union(exactLiveSessionIDs)")
        )
        XCTAssertTrue(
            manager.contains("plan.removeAll { exactLiveSessionIDs.contains($0.sessionId) }")
        )
        let piProvider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"))
        XCTAssertTrue(piProvider.contains("noteExactLiveSession(sessionID: sessionId)"))
        XCTAssertTrue(piProvider.contains("noteExactSessionEnded(sessionID: sessionId)"))
        XCTAssertTrue(store.contains("noteHookEvent(event, session: session)"))
    }

    /// An exact SessionStart is the one hook event allowed to set the phase of a
    /// row whose phase is otherwise read from the transcript. The store must read
    /// that from the named evidence, not from its own agent-and-event test, and it
    /// must read it once: the same evidence decides resurrection.
    func testTranscriptAuthorityIsOverriddenByNamedEvidence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/State/SessionStore.swift"))
        XCTAssertTrue(
            store.contains("let overridesTranscriptAuthority = rebindEvidence == .exactSessionStart"),
            "The override must come from SessionRebindCandidatePolicy evidence, which is already tested."
        )
        XCTAssertFalse(
            store.contains("event.agentID == .pi && event.event == \"SessionStart\""),
            "That test is what the evidence already names, and repeating it lets the two drift apart."
        )
    }

    func testAcceptedPiLifecycleFeedsTheRestorationCoordinator() throws {
        let root = repoRoot()
        let store = try String(contentsOf: root.appendingPathComponent("AgentVisor/Services/State/SessionStore.swift"))
        let hook = try String(contentsOf: root.appendingPathComponent("AgentVisor/Services/Hooks/HookSocketServer.swift"))

        XCTAssertTrue(hook.contains("let sessionFile: String?"))
        XCTAssertTrue(hook.contains("case sessionFile = \"session_file\""))
        let piProvider = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Agents/PiAgentProvider.swift"))
        XCTAssertTrue(piProvider.contains("PiRebootRestorationManager.shared.recordAcceptedSession"))
        XCTAssertTrue(piProvider.contains("PiRebootRestorationManager.shared.end"))
        XCTAssertTrue(piProvider.contains("PiRebootRestorationManager.shared.removeRestorationCandidate"))
        XCTAssertTrue(store.contains("noteHookEvent(event, session: session)"))
        XCTAssertTrue(store.contains("noteSessionGone(sessionId:"))
        XCTAssertTrue(store.contains("runtimeOwnershipDisposition == .ignoreCompetingRuntime"))

        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        XCTAssertTrue(manager.contains(
            "PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile)"
        ))
    }

    func testInvalidAcceptedSessionPathRemovesTheCandidateWithoutEndingTheExactOwner() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let functionStart = manager.range(of: "func recordAcceptedSession")?.lowerBound,
              let functionEnd = manager.range(
                of: "func end(sessionID: String)",
                range: functionStart..<manager.endIndex
              )?.lowerBound else {
            return XCTFail("Expected recordAcceptedSession implementation")
        }

        let implementation = manager[functionStart..<functionEnd]
        guard let validation = implementation.range(
            of: "guard PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: sessionFile) else {"
        )?.lowerBound,
        let nextGuard = implementation.range(
            of: "guard !sessionFile.isEmpty",
            range: validation..<implementation.endIndex
        )?.lowerBound else {
            return XCTFail("Expected isolated invalid-file branch")
        }
        let invalidFileBranch = implementation[validation..<nextGuard]
        guard let removal = invalidFileBranch.range(
            of: "removeRestorationCandidate(sessionID: sessionID)"
        )?.lowerBound,
        let returned = invalidFileBranch.range(
            of: "return",
            range: removal..<invalidFileBranch.endIndex
        )?.lowerBound else {
            return XCTFail("Expected candidate removal before return")
        }

        XCTAssertLessThan(removal, returned)
    }

    func testSnapshotLoadSanitizesAndPersistsBeforeReturning() throws {
        let root = repoRoot()
        let store = try String(contentsOf: root.appendingPathComponent(
            "AgentVisorCore/Sources/AgentVisorCore/PiRestorationSnapshotStore.swift"
        ))
        guard let functionStart = store.range(of: "public func load() throws")?.lowerBound,
              let functionEnd = store.range(
                of: "public func save(",
                range: functionStart..<store.endIndex
              )?.lowerBound else {
            return XCTFail("Expected snapshot load implementation")
        }
        let implementation = store[functionStart..<functionEnd]
        guard let schemaCheck = implementation.range(of: "snapshot.schemaVersion ==")?.lowerBound,
              let bootIDValidation = implementation.range(
                of: "MacBootIdentity.canonicalize(snapshot.bootID)",
                range: schemaCheck..<implementation.endIndex
              )?.lowerBound,
              let invalidBootIDRemoval = implementation.range(
                of: "try remove()",
                range: bootIDValidation..<implementation.endIndex
              )?.lowerBound,
              let sanitize = implementation.range(
                of: "PiRestorationSessionFilePolicy.sanitizing(authorized)",
                range: invalidBootIDRemoval..<implementation.endIndex
              )?.lowerBound,
              let conditionalSave = implementation.range(
                of: "if sanitized != snapshot",
                range: sanitize..<implementation.endIndex
              )?.lowerBound,
              let save = implementation.range(
                of: "try save(sanitized)",
                range: conditionalSave..<implementation.endIndex
              )?.lowerBound,
              let returned = implementation.range(
                of: "return sanitized",
                range: save..<implementation.endIndex
              )?.lowerBound else {
            return XCTFail("Expected schema check -> sanitize -> save -> return ordering")
        }

        XCTAssertLessThan(schemaCheck, bootIDValidation)
        XCTAssertLessThan(bootIDValidation, invalidBootIDRemoval)
        XCTAssertLessThan(invalidBootIDRemoval, sanitize)
        XCTAssertLessThan(sanitize, conditionalSave)
        XCTAssertLessThan(conditionalSave, save)
        XCTAssertLessThan(save, returned)
        XCTAssertFalse(implementation.contains("return snapshot"))
    }

    func testManagerLoadFailureLogsAndConstructsAnEmptyCoordinator() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let initializerStart = manager.range(of: "private init()")?.lowerBound,
              let initializerEnd = manager.range(
                of: "func start(",
                range: initializerStart..<manager.endIndex
              )?.lowerBound else {
            return XCTFail("Expected restoration manager initializer")
        }
        let initializer = manager[initializerStart..<initializerEnd]
        guard let load = initializer.range(of: "try snapshotStore.load()")?.lowerBound,
              let caught = initializer.range(
                of: "} catch {",
                range: load..<initializer.endIndex
              )?.lowerBound else {
            return XCTFail("Expected explicit snapshot load error handling")
        }
        let catchBody = initializer[caught..<initializer.endIndex]

        XCTAssertFalse(initializer.contains("try? snapshotStore.load()"))
        XCTAssertTrue(catchBody.contains("coordinator = PiRebootRestorationCoordinator("))
        XCTAssertTrue(catchBody.contains("bootID: currentBootID"))
        XCTAssertTrue(catchBody.contains(
            "Could not load or sanitize Pi restoration snapshot"
        ))
    }

    func testManagerUsesBootSessionUUIDAndNeverTimestampApproximation() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        let identity = try String(contentsOf: root.appendingPathComponent(
            "AgentVisorCore/Sources/AgentVisorCore/MacBootIdentity.swift"
        ))

        XCTAssertTrue(manager.contains("currentBootID = MacBootIdentity.current()"))
        XCTAssertTrue(identity.contains("let name = \"kern.bootsessionuuid\""))
        XCTAssertTrue(identity.contains("sysctlbyname(name, nil, &size, nil, 0)"))
        XCTAssertTrue(identity.contains("withUnsafeMutableBytes"))
        XCTAssertTrue(identity.contains("UUID(uuidString: rawValue)"))
        XCTAssertTrue(identity.contains("return canonicalize(rawValue)"))
        XCTAssertTrue(manager.contains("try snapshotStore.load()"))
        XCTAssertFalse(identity.contains("kern.boottime"))
        XCTAssertFalse(identity.contains("systemUptime"))
        XCTAssertFalse(identity.contains("Date().timeIntervalSince1970"))
        XCTAssertFalse(manager.contains("systemUptime"))
        XCTAssertFalse(manager.contains("normalizeBootIdentityIfEquivalent"))
    }

    func testIdentityFailureDisablesLifecycleAndDurablyRemovesAuthority() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let startupStart = manager.range(of: "started = true")?.lowerBound,
              let failure = manager.range(
                of: "guard let currentBootID else {",
                range: startupStart..<manager.endIndex
              )?.lowerBound,
              let claim = manager.range(
                of: "var plan = coordinator.claimRestorePlan",
                range: failure..<manager.endIndex
              )?.lowerBound else {
            return XCTFail("Expected identity failure before restore claim")
        }
        let startup = manager[startupStart..<claim]

        XCTAssertTrue(startup.contains("started = true"))
        XCTAssertTrue(startup.contains("disabled = true"))
        XCTAssertTrue(startup.contains("coordinator = nil"))
        XCTAssertTrue(startup.contains("try snapshotStore.remove()"))
        XCTAssertTrue(startup.contains("macOS boot identity unavailable"))
        XCTAssertTrue(startup.contains(
            "Could not remove Pi restoration snapshot after boot identity failure"
        ))
        XCTAssertTrue(startup.contains("return"))
        XCTAssertTrue(manager.contains("!disabled,"))
        XCTAssertFalse(startup.contains("PiGhosttyRestorationScript"))
    }

    func testUnavailableIdentityHasNoCoordinatorOrSentinelAuthority() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))

        XCTAssertTrue(manager.contains(
            "private var coordinator: PiRebootRestorationCoordinator?"
        ))
        XCTAssertFalse(manager.contains("boot-identity-unavailable"))
        XCTAssertTrue(manager.contains("guard var coordinator else"))
    }

    func testFreshSchemaThreeBaselineFailureDisablesBeforeAnyRestoreClaim() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let persistGate = manager.range(
            of: "if needsInitialSnapshotPersistence",
        )?.lowerBound,
        let claim = manager.range(
            of: "claimRestorePlan",
            range: persistGate..<manager.endIndex
        )?.lowerBound else {
            return XCTFail("Expected fresh snapshot gate before claim")
        }
        let startupGate = manager[persistGate..<claim]

        XCTAssertTrue(startupGate.contains("PiRestorationStartupState("))
        XCTAssertTrue(startupGate.contains("try snapshotStore.save(snapshot)"))
        XCTAssertTrue(startupGate.contains("disabled = true"))
        XCTAssertTrue(startupGate.contains("self.coordinator = nil"))
        XCTAssertTrue(startupGate.contains("needsInitialSnapshotPersistence ="))
        XCTAssertTrue(startupGate.contains("Could not persist initial Pi restoration baseline"))
        XCTAssertTrue(startupGate.contains("return"))
    }

    func testEveryLifecycleMutationRequiresStartedEnabledCoordinator() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        let functions = [
            ("func recordAcceptedSession(", "func removeRestorationCandidate(sessionID: String)"),
            ("func removeRestorationCandidate(sessionID: String)", "func end(sessionID: String)"),
            ("func freezeForSystemPowerOff()", "func invalidateForCleanAppTermination()"),
            ("func invalidateForCleanAppTermination()", "private func captureTopologyIfNeeded"),
        ]

        for (startMarker, endMarker) in functions {
            guard let start = manager.range(of: startMarker)?.lowerBound,
                  let end = manager.range(
                    of: endMarker,
                    range: manager.index(after: start)..<manager.endIndex
                  )?.lowerBound else {
                return XCTFail("Expected lifecycle function \(startMarker)")
            }
            let implementation = manager[start..<end]
            XCTAssertTrue(implementation.contains("started"), startMarker)
            XCTAssertTrue(implementation.contains("!disabled"), startMarker)
            XCTAssertTrue(implementation.contains("var coordinator"), startMarker)
            XCTAssertTrue(
                implementation.contains("guard") && implementation.contains("else { return }"),
                startMarker
            )
        }
    }

    func testManagerEndClearsExactLivenessAndDelegatesCandidateRemoval() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let functionStart = manager.range(of: "func removeRestorationCandidate(sessionID: String)")?.lowerBound,
              let functionEnd = manager.range(
                of: "func end(sessionID: String)",
                range: functionStart..<manager.endIndex
              )?.lowerBound,
              let endStart = manager.range(of: "func end(sessionID: String)")?.lowerBound,
              let endEnd = manager.range(
                of: "func freezeForSystemPowerOff",
                range: endStart..<manager.endIndex
              )?.lowerBound else {
            return XCTFail("Expected restoration candidate removal and exact end implementations")
        }
        let removal = manager[functionStart..<functionEnd]
        let end = manager[endStart..<endEnd]

        XCTAssertTrue(removal.contains("coordinator.end(sessionID: sessionID)"))
        XCTAssertTrue(removal.contains("ttyBySessionID.removeValue(forKey: sessionID)"))
        XCTAssertTrue(removal.contains("topologyCaptureInFlight.remove(sessionID)"))
        XCTAssertTrue(removal.contains("lastTopologyCaptureAt.removeValue(forKey: sessionID)"))
        XCTAssertTrue(removal.contains(
            "if existed && coordinator.snapshot.sessionsByID[sessionID] == nil"
        ))
        XCTAssertTrue(removal.contains("persistSnapshot()"))
        XCTAssertFalse(removal.contains("noteExactSessionEnded"))
        XCTAssertTrue(end.contains("noteExactSessionEnded(sessionID: sessionID)"))
        XCTAssertTrue(end.contains("removeRestorationCandidate(sessionID: sessionID)"))
    }

    func testRestoreCandidateRequiresARegularPersistedSessionFile() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))
        guard let functionStart = manager.range(
            of: "private static func isValidRestoreCandidate"
        )?.lowerBound,
        let functionEnd = manager.range(
            of: "private nonisolated static func captureTopology",
            range: functionStart..<manager.endIndex
        )?.lowerBound else {
            return XCTFail("Expected isValidRestoreCandidate implementation")
        }

        let implementation = manager[functionStart..<functionEnd]
        XCTAssertTrue(implementation.contains(
            "PiRestorationSessionFilePolicy.isPersistedRegularFile(atPath: session.sessionFile)"
        ))
        XCTAssertTrue(implementation.contains(
            "FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory)"
        ))
        XCTAssertFalse(implementation.contains(
            "FileManager.default.fileExists(atPath: session.sessionFile)"
        ))
    }

    func testHostManagerClaimsBeforeRunningGhosttyAutomation() throws {
        let root = repoRoot()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "AgentVisor/Services/Session/PiRebootRestorationManager.swift"
        ))

        guard let claim = manager.range(of: "claimRestorePlan")?.lowerBound,
              let save = manager.range(of: "try snapshotStore.save", range: claim..<manager.endIndex)?.lowerBound,
              let automate = manager.range(of: "PiGhosttyRestorationScript.make", range: save..<manager.endIndex)?.lowerBound else {
            return XCTFail("Expected claim → durable save → Ghostty automation ordering")
        }
        XCTAssertLessThan(claim, save)
        XCTAssertLessThan(save, automate)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
