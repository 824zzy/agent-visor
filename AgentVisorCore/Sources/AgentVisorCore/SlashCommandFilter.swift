import Foundation

/// Ranks the catalog by a query string. Score weighting mirrors
/// claude-code's prompt-input ranking: exact > prefix > substring >
/// description, with a stable alphabetical tie-breaker.
///
/// Hidden commands are excluded from the default (empty-query) display
/// but remain callable on an exact-name query, matching claude-code's
/// hidden-but-discoverable semantics.
public enum SlashCommandFilter {

    public static func filter(query rawQuery: String, catalog: SlashCommandCatalog) -> [SlashCommand] {
        let query = rawQuery.lowercased()

        // Empty query: just list every visible command in alphabetical
        // order. Hidden and dialog-only commands stay out of the
        // browsing list — dialog-only because they open a TUI modal
        // the user can't see from agent-visor, which is confusing.
        // Users who explicitly type the name still get them via the
        // exact-match path below.
        if query.isEmpty {
            return catalog.commands
                .filter { !$0.isHidden && !$0.opensInTerminalDialog }
                .sorted { $0.name < $1.name }
        }

        var scored: [(SlashCommand, Int)] = []
        for cmd in catalog.commands {
            let score = scoreCommand(cmd, query: query)
            guard score > 0 else { continue }
            scored.append((cmd, score))
        }

        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name < rhs.0.name
        }
        return scored.map { $0.0 }
    }

    /// Returns 0 when nothing matches; positive otherwise. Higher is
    /// better. Weighting buckets are spaced wide enough that ties only
    /// occur within the same bucket and the alphabetical tie-breaker
    /// can settle them deterministically.
    private static func scoreCommand(_ cmd: SlashCommand, query: String) -> Int {
        let name = cmd.name.lowercased()
        let aliases = cmd.aliases.map { $0.lowercased() }
        let description = cmd.description.lowercased()

        // Dialog-only commands are hidden from the popover ENTIRELY —
        // empty-browse, prefix, substring, description. They still
        // execute when typed manually (Enter sends the line to the
        // TUI) but they never appear as a suggestion. Cleanest user
        // experience for commands whose UI lives in the terminal.
        if cmd.opensInTerminalDialog { return 0 }

        if name == query { return 100 }
        if aliases.contains(query) { return 90 }
        if name.hasPrefix(query) { return 60 }
        if aliases.contains(where: { $0.hasPrefix(query) }) { return 50 }
        // Hidden commands surface ONLY on exact-name / exact-alias matches
        // above. They drop out of substring/description scoring so the
        // empty-list filter at the call site (or just exclusion here)
        // keeps them invisible during browsing.
        if cmd.isHidden { return 0 }
        if name.contains(query) { return 30 }
        if aliases.contains(where: { $0.contains(query) }) { return 20 }
        if description.contains(query) { return 10 }
        return 0
    }
}
