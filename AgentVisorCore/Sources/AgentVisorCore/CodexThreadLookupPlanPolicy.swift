import Foundation

/// Which Codex thread ids still need a database read.
///
/// Looking a thread up by id used to cost one `sqlite3` subprocess per id that
/// the cached live list did not hold. A bootstrap of a few hundred discovered
/// sessions therefore forked a few hundred times, each fork blocking the
/// thread that ran it. This rule lets a caller ask once for a whole group and
/// read the database at most one more time.
///
/// Two sets make a read unnecessary. Ids already in the cached snapshot are
/// answered from memory. Ids already proven absent under the same database
/// signature are answered as absent: a repeat read cannot find them, because
/// the signature changes whenever the database changes.
public enum CodexThreadLookupPlanPolicy {
    /// - Parameters:
    ///   - requested: the ids the caller wants.
    ///   - cached: ids the in-memory snapshot can answer.
    ///   - knownMissing: ids already proven absent under this signature.
    /// - Returns: the ids that still need one read, in a stable order, with
    ///   duplicates removed.
    public static func idsNeedingQuery(
        requested: [String],
        cached: Set<String>,
        knownMissing: Set<String>
    ) -> [String] {
        var seen: Set<String> = []
        var needed: [String] = []
        for id in requested {
            guard !id.isEmpty else { continue }
            guard !cached.contains(id), !knownMissing.contains(id) else { continue }
            guard seen.insert(id).inserted else { continue }
            needed.append(id)
        }
        return needed
    }

    /// Ids that a completed read did not return. They are absent for as long
    /// as the database signature holds.
    ///
    /// A read that returns nothing at all is treated as no evidence. An empty
    /// answer is almost always a truncated read while Codex was writing, and
    /// remembering it as absence would hide every thread until the signature
    /// next changed.
    public static func missingIDs(
        queried: [String],
        returned: Set<String>
    ) -> Set<String> {
        guard !returned.isEmpty else { return [] }
        return Set(queried).subtracting(returned)
    }
}
