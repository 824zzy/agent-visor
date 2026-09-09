public enum NativeMenuSessionOrder {
    /// The daemon owns priority. Interaction stability belongs to the layout transition,
    /// not a second ordering policy that can retain an obsolete completion order.
    /// The wire priority is the daemon's final ordinal, not a phase or attention tier.
    public static func orderedPills(_ pills: [NativeHelperPill]) -> [NativeHelperPill] {
        var seenIDs = Set<String>()
        return pills.sorted { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
        }.filter { seenIDs.insert($0.id).inserted }
    }
}
