import Foundation

public struct PiGhosttyLayout: Codable, Equatable, Sendable {
    public let windowIndex: Int
    public let tabIndex: Int
    public let terminalIndex: Int

    public init(windowIndex: Int, tabIndex: Int, terminalIndex: Int) {
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.terminalIndex = terminalIndex
    }
}

public struct PiRestorableSession: Codable, Equatable, Sendable, Identifiable {
    public let sessionId: String
    public let sessionFile: String
    public let cwd: String
    public let sessionName: String?
    public var layout: PiGhosttyLayout?
    public let observedAt: Date

    public var id: String { sessionId }

    public init(
        sessionId: String,
        sessionFile: String,
        cwd: String,
        sessionName: String?,
        layout: PiGhosttyLayout?,
        observedAt: Date
    ) {
        self.sessionId = sessionId
        self.sessionFile = sessionFile
        self.cwd = cwd
        self.sessionName = sessionName
        self.layout = layout
        self.observedAt = observedAt
    }
}

public struct PiRestorationSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Equatable, Sendable {
        case active
        case frozen
        case claimed
        case invalidated
    }

    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let bootID: String
    public let generationID: String
    public var state: State
    public var sessionsByID: [String: PiRestorableSession]
    public var attemptedSessionIDs: [String]
    public var frozenAt: Date?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        bootID: String,
        generationID: String,
        state: State = .active,
        sessionsByID: [String: PiRestorableSession] = [:],
        attemptedSessionIDs: [String] = [],
        frozenAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.bootID = bootID
        self.generationID = generationID
        self.state = state
        self.sessionsByID = sessionsByID
        self.attemptedSessionIDs = attemptedSessionIDs
        self.frozenAt = frozenAt
    }
}

/// Boot-scoped state machine for Pi restoration. Host code owns persistence,
/// process inspection, and Ghostty automation; this type decides which exact
/// durable sessions are eligible and guarantees one claim per generation.
public struct PiRebootRestorationCoordinator: Sendable {
    public private(set) var snapshot: PiRestorationSnapshot

    public init(bootID: String, generationID: String) {
        snapshot = PiRestorationSnapshot(bootID: bootID, generationID: generationID)
    }

    public init(snapshot: PiRestorationSnapshot) {
        self.snapshot = snapshot
    }

    public mutating func observe(_ session: PiRestorableSession) {
        guard snapshot.state == .active else { return }
        snapshot.sessionsByID[session.sessionId] = session
    }

    public mutating func updateLayout(
        sessionID: String,
        layout: PiGhosttyLayout?
    ) {
        guard snapshot.state == .active,
              var session = snapshot.sessionsByID[sessionID] else { return }
        session.layout = layout
        snapshot.sessionsByID[sessionID] = session
    }

    public mutating func end(sessionID: String) {
        guard snapshot.state == .active else { return }
        snapshot.sessionsByID.removeValue(forKey: sessionID)
    }

    public mutating func replace(
        sessionID: String,
        with replacement: PiRestorableSession
    ) {
        guard snapshot.state == .active else { return }
        snapshot.sessionsByID.removeValue(forKey: sessionID)
        snapshot.sessionsByID[replacement.sessionId] = replacement
    }

    public mutating func freezeForSystemPowerOff(at date: Date) {
        guard snapshot.state == .active else { return }
        snapshot.state = .frozen
        snapshot.frozenAt = date
    }

    public mutating func invalidateForCleanAppTermination() {
        guard snapshot.state != .frozen else { return }
        snapshot.state = .invalidated
        snapshot.sessionsByID.removeAll()
        snapshot.attemptedSessionIDs.removeAll()
    }

    public mutating func claimRestorePlan(
        currentBootID: String,
        liveSessionIDs: Set<String>
    ) -> [PiRestorableSession] {
        guard snapshot.schemaVersion == PiRestorationSnapshot.currentSchemaVersion,
              snapshot.bootID != currentBootID,
              snapshot.state == .active || snapshot.state == .frozen else {
            return []
        }

        let plan = snapshot.sessionsByID.values
            .filter { !liveSessionIDs.contains($0.sessionId) }
            .sorted {
                if $0.observedAt != $1.observedAt {
                    return $0.observedAt < $1.observedAt
                }
                return $0.sessionId < $1.sessionId
            }

        snapshot.state = .claimed
        snapshot.attemptedSessionIDs = plan.map(\.sessionId)
        return plan
    }
}
