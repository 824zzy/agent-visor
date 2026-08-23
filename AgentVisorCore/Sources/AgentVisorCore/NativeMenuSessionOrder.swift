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
}
