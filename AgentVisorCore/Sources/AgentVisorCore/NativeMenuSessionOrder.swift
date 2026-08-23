public enum NativeMenuSessionOrder {
    public static func resolve(
        displayedIDs: [String],
        previousPhases: [String: NativeHelperPillPhase],
        presentedPills: [NativeHelperPill]
    ) -> [String] {
        let presentedIDs = presentedPills.map(\.id)
        guard displayedIDs.count == Set(displayedIDs).count,
              presentedIDs.count == Set(presentedIDs).count,
              Set(displayedIDs) == Set(presentedIDs),
              presentedPills.allSatisfy({ previousPhases[$0.id] == $0.phase }) else {
            return presentedIDs
        }
        return displayedIDs
    }

    public static func applyingReadyAcknowledgments(
        displayedIDs: [String],
        phases: [String: NativeHelperPillPhase],
        acknowledgedReadyIDs: Set<String>
    ) -> [String] {
        displayedIDs.enumerated().sorted { left, right in
            let leftTier = tier(
                id: left.element,
                phase: phases[left.element],
                acknowledgedReadyIDs: acknowledgedReadyIDs
            )
            let rightTier = tier(
                id: right.element,
                phase: phases[right.element],
                acknowledgedReadyIDs: acknowledgedReadyIDs
            )
            return leftTier == rightTier ? left.offset < right.offset : leftTier < rightTier
        }.map(\.element)
    }

    private static func tier(
        id: String,
        phase: NativeHelperPillPhase?,
        acknowledgedReadyIDs: Set<String>
    ) -> Int {
        switch phase {
        case .needsYou: 0
        case .ready: acknowledgedReadyIDs.contains(id) ? 3 : 1
        case .working: 2
        case .history: 4
        case nil: 5
        }
    }
}
