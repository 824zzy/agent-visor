import Foundation

/// Converts upstream claude-code's `permission_suggestions` array
/// (delivered in the PermissionRequest hook payload) into the
/// `PermissionSuggestion` shape agent-visor renders as option 2.
///
/// The whole point of this module is to *trust upstream* instead of
/// re-deriving safety verdicts locally. When upstream returns no
/// rule-bearing updates (e.g. `find -exec`, dangerous patterns),
/// `adapt` returns nil and ChatView hides option 2 — exactly matching
/// upstream's TUI behavior of showing only Yes/No.
public enum UpstreamSuggestionAdapter {
    /// Mirrors PermissionSuggestionBuilder's "similar" threshold so a
    /// long list of rules collapses to "similar commands" the same way
    /// upstream's `commandListDisplayTruncated` does.
    private static let similarThreshold = 50

    public static func adapt(
        updates: [PermissionUpdate],
        cwd: String
    ) -> PermissionSuggestion? {
        // Filter to rule-bearing updates. setMode and other variants
        // can't underwrite an "always allow" option; ignore them.
        let rawRuleUpdates = updates.filter { update in
            update.type == "addRules" && (update.rules?.isEmpty == false)
        }
        guard !rawRuleUpdates.isEmpty else { return nil }

        // Widen Bash exact-match rules to TUI parity (see widenIfNeeded).
        // For non-Bash rules this is a no-op; the original update passes
        // through unchanged.
        let ruleUpdates = rawRuleUpdates.map(widenIfNeeded)

        let names = ruleUpdates.compactMap { displayName(for: $0) }
        guard !names.isEmpty else { return nil }

        let isAllRead = ruleUpdates.allSatisfy { ruleToolName(of: $0) == "Read" }
        let isAllBash = ruleUpdates.allSatisfy { ruleToolName(of: $0) == "Bash" }

        let label: String
        if isAllRead {
            label = "Yes, allow reading from \(displayPhrase(names)) from this project"
        } else if isAllBash {
            // Match the local builder's single vs aggregate distinction:
            // backticks around a lone command name, no backticks for the
            // joined / "similar" phrase.
            if names.count == 1 {
                label = "Yes, and don't ask again for `\(names[0])` commands in \(cwd)"
            } else {
                label = "Yes, and don't ask again for \(displayPhrase(names)) commands in \(cwd)"
            }
        } else {
            label = "Yes, and always allow access to \(displayPhrase(names)) from this project"
        }
        return PermissionSuggestion(label: label, updates: ruleUpdates)
    }

    /// Mirror claude-code's TUI widen (BashPermissionRequest.tsx:219-232):
    /// when upstream sends a Bash exact-match (no `:*` suffix), re-derive
    /// a reusable prefix so the persisted rule isn't a one-shot literal
    /// that never matches future invocations. Non-Bash and already-widened
    /// rules pass through unchanged.
    private static func widenIfNeeded(_ update: PermissionUpdate) -> PermissionUpdate {
        guard let rule = update.rules?.first,
              rule.toolName == "Bash",
              let content = rule.ruleContent,
              !content.hasSuffix(":*") else {
            return update
        }
        let widened = PermissionSuggestionBuilder.widenedBashRule(content: content)
        guard widened.ruleContent != content else { return update }
        let newRule = PermissionRuleValue(toolName: "Bash", ruleContent: widened.ruleContent)
        return PermissionUpdate(
            type: update.type,
            rules: [newRule],
            behavior: update.behavior,
            destination: update.destination,
            mode: update.mode
        )
    }

    // MARK: - Per-rule display name

    private static func ruleToolName(of update: PermissionUpdate) -> String? {
        update.rules?.first?.toolName
    }

    /// Display name for a single rule:
    /// - Bash with `prefix:*` → `prefix` (drop the `:*` glob).
    /// - Bash with verbatim command → use the command as-is.
    /// - Read with `path/**` → last path component + `/`.
    private static func displayName(for update: PermissionUpdate) -> String? {
        guard let rule = update.rules?.first,
              let content = rule.ruleContent else { return nil }
        switch rule.toolName {
        case "Bash":
            if content.hasSuffix(":*") {
                return String(content.dropLast(2))
            }
            return content
        case "Read":
            return readDirectoryDisplayName(from: content)
        default:
            // Unknown tool — use raw content; this lets the mixed
            // path produce *something* readable rather than nothing.
            return content
        }
    }

    /// Strip upstream's glob suffix (`/**`) and the leading-slash-doubled
    /// absolute prefix to recover the last path component for display.
    /// Mirrors what PermissionSuggestionBuilder does for its locally
    /// emitted Read rules so labels look identical regardless of source.
    private static func readDirectoryDisplayName(from ruleContent: String) -> String {
        var path = ruleContent
        if path.hasSuffix("/**") {
            path = String(path.dropLast(3))
        } else if path.hasSuffix("**") {
            path = String(path.dropLast(2))
        }
        // Upstream encodes absolute paths with a leading-slash doubled
        // (`//Users/...`); collapse the duplicate so we can take the
        // last path component without it being empty.
        if path.hasPrefix("//") {
            path = String(path.dropFirst())
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : "\(last)/"
    }

    // MARK: - Phrasing helpers (mirror local builder)

    private static func displayPhrase(_ items: [String]) -> String {
        let joined = items.joined(separator: ", ")
        if joined.count > similarThreshold {
            return "similar"
        }
        return commaListWithAnd(items)
    }

    private static func commaListWithAnd(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            guard let last = items.last else { return "" }
            return "\(head), and \(last)"
        }
    }
}
