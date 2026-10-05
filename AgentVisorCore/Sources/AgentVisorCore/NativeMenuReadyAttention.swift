import Foundation

public struct NativeMenuReadyAttention {
    public private(set) var acknowledgedReadyIDs = Set<String>()
    private var phaseChangedAtByID: [String: Date] = [:]
    private var unopenedIDs = Set<String>()

    public init() {}

    public mutating func present(
        previousPhases: [String: NativeHelperPillPhase],
        pills: [NativeHelperPill],
        now: Date
    ) {
        let readyIDs = Set(pills.filter { $0.phase == .ready }.map(\.id))
        acknowledgedReadyIDs = Set(acknowledgedReadyIDs.filter { readyIDs.contains($0) })
        phaseChangedAtByID = phaseChangedAtByID.filter { readyIDs.contains($0.key) }
        unopenedIDs = Set(pills.filter {
            $0.phase == .ready && $0.attentionTier == .ready && $0.completionUnseen == true
        }.map(\.id))
        for pill in pills where unopenedIDs.contains(pill.id) {
            // Shared completion attention survives a helper restart. Its date
            // is the completion date, not this presentation or a settings write.
            phaseChangedAtByID[pill.id] = min(now, pill.inspector.flatMap {
                NativeHelperTimestamp.parse($0.activityAt)
            } ?? phaseChangedAtByID[pill.id] ?? now)
        }

        for pill in pills where pill.phase == .ready {
            guard let previousPhase = previousPhases[pill.id], previousPhase != .ready else {
                continue
            }
            phaseChangedAtByID[pill.id] = now
            acknowledgedReadyIDs.remove(pill.id)
        }

        // The daemon may have seen an activation after this helper last saw Working.
        // Its current acknowledgment wins over the local phase transition.
        for pill in pills where pill.phase == .ready && pill.attentionTier != nil {
            if pill.attentionTier == .acknowledgedReady {
                acknowledgedReadyIDs.insert(pill.id)
            } else {
                acknowledgedReadyIDs.remove(pill.id)
            }
        }
    }

    public mutating func acknowledgeReady(id: String) {
        acknowledgedReadyIDs.insert(id)
        unopenedIDs.remove(id)
    }

    public func hasActivePulse(pills: [NativeHelperPill], now: Date, reduceMotion: Bool = false) -> Bool {
        guard !reduceMotion else { return false }
        return pills.contains {
            $0.attentionTier != .history
                && shouldPulse(id: $0.id, phase: $0.phase, now: now)
        }
    }

    public func isAcknowledged(_ pill: NativeHelperPill) -> Bool {
        pill.phase == .ready && acknowledgedReadyIDs.contains(pill.id)
    }

    public func statusStaleness(pill: NativeHelperPill, now: Date) -> Double {
        if unopenedIDs.contains(pill.id) && !isAcknowledged(pill) { return 0 }
        return ReadyAttentionPolicy.statusStaleness(
            isReady: pill.phase == .ready,
            activityAt: pill.inspector.flatMap { NativeHelperTimestamp.parse($0.activityAt) },
            now: now
        )
    }

    public func opacity(
        id: String,
        phase: NativeHelperPillPhase,
        attentionTier: NativeHelperSessionAttentionTier? = nil,
        now: Date,
        reduceMotion: Bool = false
    ) -> Double {
        guard !reduceMotion else { return 1 }
        guard attentionTier != .history else { return 1 }
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return 1 }
        return ReadyAttentionPolicy.pulseOpacity(
            isReady: phase == .ready,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now,
            pulseWindow: unopenedIDs.contains(id) ? .infinity : ReadyAttentionPolicy.defaultPulseWindow,
            pulsePeriod: unopenedIDs.contains(id) ? 3 : ReadyAttentionPolicy.defaultPulsePeriod,
            minimumOpacity: unopenedIDs.contains(id) ? 0.65 : ReadyAttentionPolicy.defaultPulseMinimumOpacity
        )
    }

    private func shouldPulse(id: String, phase: NativeHelperPillPhase, now: Date) -> Bool {
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return false }
        return ReadyAttentionPolicy.shouldPulse(
            isReady: phase == .ready,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now,
            pulseWindow: unopenedIDs.contains(id) ? .infinity : ReadyAttentionPolicy.defaultPulseWindow
        )
    }
}
