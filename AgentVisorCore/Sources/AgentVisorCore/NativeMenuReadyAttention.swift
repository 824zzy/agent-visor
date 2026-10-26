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
        let presentedUnopenedIDs = Set(pills.filter(isUnopenedCompletion).map(\.id))
        acknowledgedReadyIDs = Set(acknowledgedReadyIDs.filter { readyIDs.contains($0) })
        // An unavailable row can retain an explicit completion cue even while
        // its placement phase is History. Keep that cue's timing alongside
        // Ready rows; confirmed closed rows are excluded by the predicate.
        phaseChangedAtByID = phaseChangedAtByID.filter {
            readyIDs.contains($0.key) || presentedUnopenedIDs.contains($0.key)
        }
        unopenedIDs = presentedUnopenedIDs
        for pill in pills where unopenedIDs.contains(pill.id) {
            // Shared completion attention survives a helper restart. Its date
            // is the completion date, not this presentation or a settings write.
            phaseChangedAtByID[pill.id] = min(now, pill.inspector.flatMap {
                NativeHelperTimestamp.parse($0.activityAt)
            } ?? phaseChangedAtByID[pill.id] ?? now)
        }

        for pill in pills where pill.phase == .ready {
            // Modern pills carry authoritative completion attention. Placement
            // changes (for example inactive History -> Ready) are not turns.
            if pill.attentionTier != nil {
                if !unopenedIDs.contains(pill.id) { phaseChangedAtByID.removeValue(forKey: pill.id) }
                continue
            }
            guard let previousPhase = previousPhases[pill.id],
                  previousPhase == .working || previousPhase == .needsYou else {
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

    public func isUnopened(_ pill: NativeHelperPill) -> Bool {
        unopenedIDs.contains(pill.id) && !isAcknowledged(pill)
    }

    /// Blend green into the background; the outline and status dot stay steady.
    /// Reduce Motion leaves only the outline, without acknowledging the result.
    public func backgroundPulse(
        for pill: NativeHelperPill,
        now: Date,
        reduceMotion: Bool = false
    ) -> Double {
        guard !reduceMotion, isUnopened(pill),
              let completedAt = phaseChangedAtByID[pill.id] else { return 0 }
        return 0.30 * ReadyAttentionPolicy.pulseOpacity(
            isReady: true, phaseChangedAt: completedAt, acknowledgedAt: nil,
            now: now, pulseWindow: .infinity, pulsePeriod: 3, minimumOpacity: 0.4
        )
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
        guard !unopenedIDs.contains(id) else { return 1 }
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return 1 }
        return ReadyAttentionPolicy.pulseOpacity(
            isReady: phase == .ready,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now,
            pulseWindow: ReadyAttentionPolicy.defaultPulseWindow
        )
    }

    private func shouldPulse(id: String, phase: NativeHelperPillPhase, now: Date) -> Bool {
        guard let phaseChangedAt = phaseChangedAtByID[id] else { return false }
        let unopened = unopenedIDs.contains(id)
        return ReadyAttentionPolicy.shouldPulse(
            // An explicit unopened completion is attention-bearing even when
            // an unavailable row is retained in History placement. Legacy
            // rows still require the normal Ready phase transition.
            isReady: phase == .ready || unopened,
            phaseChangedAt: phaseChangedAt,
            acknowledgedAt: acknowledgedReadyIDs.contains(id) ? phaseChangedAt : nil,
            now: now,
            pulseWindow: unopened ? .infinity : ReadyAttentionPolicy.defaultPulseWindow
        )
    }

    /// Completion attention is an explicit modern signal, independent of
    /// placement. A confirmed closed row keeps its History mark but cannot
    /// produce a live unopened cue.
    private func isUnopenedCompletion(_ pill: NativeHelperPill) -> Bool {
        pill.attentionTier == .ready
            && pill.completionUnseen == true
            && pill.lifecycleStatus != .closed
    }
}
