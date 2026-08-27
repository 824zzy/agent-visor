import Foundation

public struct NativeMenuReadyAttention {
    public private(set) var acknowledgedReadyIDs = Set<String>()
    private var phaseChangedAtByID: [String: Date] = [:]

    public init() {}

    public mutating func present(
        previousPhases: [String: NativeHelperPillPhase],
        pills: [NativeHelperPill],
        now: Date
    ) {
        let readyIDs = Set(pills.filter { $0.phase == .ready }.map(\.id))
        acknowledgedReadyIDs = Set(acknowledgedReadyIDs.filter { readyIDs.contains($0) })
        phaseChangedAtByID = phaseChangedAtByID.filter { readyIDs.contains($0.key) }

        for pill in pills where pill.phase == .ready {
            guard let previousPhase = previousPhases[pill.id], previousPhase != .ready else {
                continue
            }
            phaseChangedAtByID[pill.id] = now
            acknowledgedReadyIDs.remove(pill.id)
        }
    }

    public mutating func acknowledgeReady(id: String) {
        acknowledgedReadyIDs.insert(id)
    }

    public func hasActivePulse(pills: [NativeHelperPill], now: Date) -> Bool {
        pills.contains { shouldPulse(id: $0.id, phase: $0.phase, now: now) }
    }

    public func statusStaleness(pill: NativeHelperPill, now: Date) -> Double {
        let activityAt = pill.inspector.flatMap {
            try? Date($0.activityAt, strategy: .iso8601)
        }
        return ReadyAttentionPolicy.statusStaleness(
            isReady: pill.phase == .ready,
            activityAt: activityAt,
            now: now
        )
    }

    public func opacity(id: String, phase: NativeHelperPillPhase, now: Date) -> Double {
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return 1 }
        return ReadyAttentionPolicy.pulseOpacity(
            isReady: phase == .ready,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now
        )
    }

    private func shouldPulse(id: String, phase: NativeHelperPillPhase, now: Date) -> Bool {
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return false }
        return ReadyAttentionPolicy.shouldPulse(
            isReady: phase == .ready,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now
        )
    }
}
