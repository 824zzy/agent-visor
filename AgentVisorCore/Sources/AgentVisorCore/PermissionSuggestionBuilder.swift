import Foundation

public struct PermissionRuleValue: Codable, Equatable, Sendable {
    public let toolName: String
    public let ruleContent: String?

    public init(toolName: String, ruleContent: String?) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

/// Mirrors claude-code's `permissionUpdateSchema` discriminated union.
/// We emit two variants in practice: `addRules` (for "always allow" /
/// classifier suggestions) and `setMode` (for plan-mode follow-up
/// transitions to `acceptEdits` / `default`). Optional fields cover both
/// shapes; encoder skips nils so the wire payload matches upstream.
public struct PermissionUpdate: Codable, Equatable, Sendable {
    public let type: String
    public let rules: [PermissionRuleValue]?
    public let behavior: String?
    public let destination: String
    /// `setMode` payload carries the target permission mode here
    /// (`acceptEdits` / `default` / ...). Nil for non-setMode types.
    public let mode: String?

    public init(
        type: String,
        rules: [PermissionRuleValue]? = nil,
        behavior: String? = nil,
        destination: String,
        mode: String? = nil
    ) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.destination = destination
        self.mode = mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(destination, forKey: .destination)
        try container.encodeIfPresent(rules, forKey: .rules)
        try container.encodeIfPresent(behavior, forKey: .behavior)
        try container.encodeIfPresent(mode, forKey: .mode)
    }

    private enum CodingKeys: String, CodingKey {
        case type, rules, behavior, destination, mode
    }
}

public struct PermissionSuggestion: Equatable, Sendable {
    public let label: String
    public let updates: [PermissionUpdate]

    public init(label: String, updates: [PermissionUpdate]) {
        self.label = label
        self.updates = updates
    }
}

public enum PermissionSuggestionBuilder {
    /// Upstream cap (bashPermissions.ts:110, MAX_SUGGESTED_RULES_FOR_COMPOUND).
    private static let maxRulesPerCompound = 5

    public static func suggestion(
        tool: String,
        input: [String: Any],
        cwd: String
    ) -> PermissionSuggestion? {
        switch tool {
        case "Bash":
            return bashSuggestion(input: input, cwd: cwd)
        case "Read", "Edit", "Write":
            guard let filePath = input["file_path"] as? String,
                  let parent = parentDirectory(of: filePath) else { return nil }
            let dirName = (parent as NSString).lastPathComponent
            let ruleContent = readDirectoryRuleContent(for: parent)
            return PermissionSuggestion(
                label: "Yes, and always allow access to \(dirName)/ from this project",
                updates: [
                    PermissionUpdate(
                        type: "addRules",
                        rules: [PermissionRuleValue(toolName: tool, ruleContent: ruleContent)],
                        behavior: "allow",
                        destination: "localSettings"
                    )
                ]
            )
        default:
            // Universal fallback: any other tool (MCP servers, WebFetch,
            // Task, NotebookEdit, Skill, etc.) gets an entire-tool rule
            // — `{ toolName: "<tool>" }` with no `ruleContent`. Mirrors
            // upstream's FallbackPermissionRequest emit shape
            // (FallbackPermissionRequest.tsx:81-88); claude-code's
            // matcher (permissions.ts:236) treats a rule with no
            // ruleContent as matching the entire tool.
            return PermissionSuggestion(
                label: "Yes, and don't ask again for `\(toolDisplayName(for: tool))` commands in \(cwd)",
                updates: [
                    PermissionUpdate(
                        type: "addRules",
                        rules: [PermissionRuleValue(toolName: tool, ruleContent: nil)],
                        behavior: "allow",
                        destination: "localSettings"
                    )
                ]
            )
        }
    }

    // MARK: - Bash pipeline

    /// Per-segment record. Internal to the builder; carries enough info
    /// to assemble both the rule and the label.
    private struct PerSegmentResult {
        let update: PermissionUpdate
        /// The "display name" the label uses for this segment — e.g.
        /// `cat`, `git diff`, `bash /path/to/foo.sh`. For Read rules
        /// this is the directory's last path component (e.g. `src/`).
        let displayName: String
        /// Single-segment label override. When the script has only one
        /// safe segment, we render the existing per-shape labels
        /// (Read: "Yes, allow reading from dir/", interpreter +
        /// multi-verb + simple: "Yes, and don't ask again for ..."
        /// commands in cwd"). When there are multiple safe segments,
        /// the aggregator builds a "similar commands" label instead.
        let singleSegmentLabel: String
    }

    private static func bashSuggestion(input: [String: Any], cwd: String) -> PermissionSuggestion? {
        guard let raw = input["command"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Quote-aware top-level segmentation.
        let segments = BashSegmenter.segments(trimmed)

        // 2. Per-segment, derive a result. Unsafe segments (real $()
        //    or backtick) are skipped silently — we can't allowlist
        //    a command whose effective text depends on substitution.
        //
        //    The read-classifier is gated to single-segment scripts.
        //    Upstream emits Read rules ONLY when a path is blocked by
        //    its working-directory state — info we don't have over the
        //    hook protocol. For multi-statement scripts upstream's
        //    typical TUI output is the all-Bash "don't ask again for
        //    similar commands" branch. Forcing every multi-segment
        //    script through the prefix path mirrors that behavior and
        //    avoids the awkward mixed Read+Bash label.
        let allowReadClassifier = segments.count == 1
        var results: [PerSegmentResult] = []
        for seg in segments {
            if seg.isUnsafe { continue }
            let cleaned = strippedReadOnlyRedirections(seg.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            // Stdout redirection to a file (`> path`) didn't get
            // stripped above and indicates a write — we don't have
            // enough context to scope it safely, so skip.
            if containsStdoutFileRedirect(cleaned) { continue }
            if let r = perSegmentResult(for: cleaned, cwd: cwd, allowReadClassifier: allowReadClassifier) {
                results.append(r)
            }
        }

        // 3. Dedupe by rule shape, then cap at 5 (upstream parity).
        let deduped = dedupeByRule(results)
        let capped = Array(deduped.prefix(maxRulesPerCompound))
        guard !capped.isEmpty else { return nil }

        // 4. Single → existing per-shape labels. Multi → aggregator.
        if capped.count == 1 {
            return PermissionSuggestion(
                label: capped[0].singleSegmentLabel,
                updates: [capped[0].update]
            )
        }
        return aggregateLabel(results: capped, cwd: cwd)
    }

    /// Build the per-segment update + label for a single safe Bash
    /// segment. Branches on (a) is it a read [single-segment only]?
    /// (b) is it an interpreter+script? (c) does it have a 2-word
    /// multi-verb prefix? (d) else: simple-command prefix or exact.
    private static func perSegmentResult(for cleaned: String, cwd: String, allowReadClassifier: Bool) -> PerSegmentResult? {
        // (a) Read classifier — Read rule, session destination.
        //     Skipped for multi-segment scripts to avoid the mixed
        //     Read+Bash label (see bashSuggestion).
        if allowReadClassifier,
           let target = BashReadClassifier.readTarget(
            command: cleaned,
            cwd: cwd,
            homeDirectory: NSHomeDirectory()
           ),
           let parent = readSuggestionParent(for: target) {
            let dirName = (parent as NSString).lastPathComponent
            let ruleContent = readDirectoryRuleContent(for: parent)
            return PerSegmentResult(
                update: PermissionUpdate(
                    type: "addRules",
                    rules: [PermissionRuleValue(toolName: "Read", ruleContent: ruleContent)],
                    behavior: "allow",
                    destination: "session"
                ),
                displayName: "\(dirName)/",
                singleSegmentLabel: "Yes, allow reading from \(dirName)/ from this project"
            )
        }

        // (b/c/d) Bash command prefix or exact-match.
        let ruleContent: String
        let displayName: String
        if let prefix = bashCommandPrefix(cleaned) {
            ruleContent = "\(prefix):*"
            displayName = prefix
        } else {
            // No safe two-word prefix → exact-match (verbatim).
            ruleContent = cleaned
            displayName = cleaned
        }
        return PerSegmentResult(
            update: PermissionUpdate(
                type: "addRules",
                rules: [PermissionRuleValue(toolName: "Bash", ruleContent: ruleContent)],
                behavior: "allow",
                destination: "localSettings"
            ),
            displayName: displayName,
            singleSegmentLabel: "Yes, and don't ask again for `\(displayName)` commands in \(cwd)"
        )
    }

    /// Build the aggregated label for multi-segment scripts. Mirrors
    /// upstream's `generateShellSuggestionsLabel`
    /// (shellPermissionHelpers.tsx:65-145):
    /// - All-Read rules → "Yes, allow reading from <dirs> from this project"
    ///   (or "similar dirs" when joined names exceed 50 chars).
    /// - All-Bash rules → "Yes, and don't ask again for <cmds> commands in <cwd>"
    ///   (or "similar commands" when joined > 50 chars).
    /// - Mixed → "Yes, and always allow access to <paths> from this project".
    private static func aggregateLabel(results: [PerSegmentResult], cwd: String) -> PermissionSuggestion {
        let updates = results.map { $0.update }

        let isAllRead = results.allSatisfy { ($0.update.rules?.first?.toolName ?? "") == "Read" }
        let isAllBash = results.allSatisfy { ($0.update.rules?.first?.toolName ?? "") == "Bash" }

        let names = results.map { $0.displayName }
        let label: String
        if isAllRead {
            let phrase = displayPhrase(names)
            label = "Yes, allow reading from \(phrase) from this project"
        } else if isAllBash {
            let phrase = displayPhrase(names)
            label = "Yes, and don't ask again for \(phrase) commands in \(cwd)"
        } else {
            // Mixed read + bash — fall back to upstream's combined
            // "always allow access to" wording.
            let phrase = displayPhrase(names)
            label = "Yes, and always allow access to \(phrase) from this project"
        }
        return PermissionSuggestion(label: label, updates: updates)
    }

    /// Mirrors upstream's `commandListDisplayTruncated`
    /// (shellPermissionHelpers.tsx:24-31): when the comma-joined
    /// representation exceeds 50 chars, replace with the literal word
    /// "similar". Otherwise format with Oxford comma + "and".
    private static let similarThreshold = 50

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

    /// Drop duplicate updates by their rule content. Preserves first-seen
    /// order. Mirrors upstream's Map<string, PermissionRuleValue>
    /// dedup at bashPermissions.ts:2473.
    private static func dedupeByRule(_ results: [PerSegmentResult]) -> [PerSegmentResult] {
        var seen = Set<String>()
        var out: [PerSegmentResult] = []
        for r in results {
            let key = r.update.rules?.first.map { "\($0.toolName)|\($0.ruleContent ?? "")" } ?? ""
            if seen.insert(key).inserted {
                out.append(r)
            }
        }
        return out
    }

    /// Cheap heuristic: detect either:
    ///   - a `>` / `>>` to a file path (stdout write side-effect), or
    ///   - a `<` from a file path (input redirection, which inverts
    ///     argument shape — `cat < foo` reads stdin, not the literal
    ///     command we'd otherwise allowlist).
    /// We can't safely allowlist either by command-prefix.
    private static func containsStdoutFileRedirect(_ command: String) -> Bool {
        // Find unescaped `>` or `>>` outside quotes.
        // We've already passed the segmenter so quote handling is done;
        // a quick re-scan suffices.
        let chars = Array(command)
        var inSingle = false
        var inDouble = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDouble { inSingle.toggle(); i += 1; continue }
            if c == "\"" && !inSingle { inDouble.toggle(); i += 1; continue }
            if !inSingle && !inDouble && c == "<" {
                return true
            }
            if !inSingle && !inDouble && c == ">" {
                // Skip duplicate `>` for `>>`.
                var j = i + 1
                if j < chars.count && chars[j] == ">" { j += 1 }
                // Skip whitespace.
                while j < chars.count && chars[j] == " " { j += 1 }
                // If next non-space is `&` or a digit, it's an fd
                // redirect (`>&2`, `>2`), which is read-only side
                // and was already stripped by `strippedReadOnlyRedirections`
                // for the harmless cases — anything left is dubious.
                if j < chars.count, chars[j] == "&" {
                    i = j + 1
                    continue
                }
                return true
            }
            // `2>file` → file write to stderr target. Treat the same.
            if !inSingle && !inDouble && c.isASCII && c.isWholeNumber {
                if i + 1 < chars.count && chars[i + 1] == ">" {
                    var j = i + 2
                    if j < chars.count && chars[j] == ">" { j += 1 }
                    while j < chars.count && chars[j] == " " { j += 1 }
                    if j < chars.count, chars[j] == "&" || chars[j..<chars.endIndex].starts(with: "/dev/null") {
                        i = j
                        continue
                    }
                    return true
                }
            }
            i += 1
        }
        return false
    }

    // MARK: - Existing helpers (unchanged behavior)

    /// Pretty-print a tool name for the option-2 label. MCP tools come
    /// over the wire as `mcp__server__tool` — render them as
    /// `server: tool` so the user can read them. Other tools render
    /// verbatim.
    private static func toolDisplayName(for tool: String) -> String {
        let parts = tool.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty {
            let server = parts[1]
            let toolName = parts.dropFirst(2).joined(separator: "__")
            return "\(server): \(toolName)"
        }
        return tool
    }

    /// Mirrors claude-code's `createReadRuleSuggestion` formatting: for an
    /// absolute path the rule gets a leading-slash-doubled `/path/**` to
    /// distinguish it from a relative pattern.
    private static func readDirectoryRuleContent(for parentPath: String) -> String {
        if parentPath.hasPrefix("/") {
            return "/\(parentPath)/**"
        }
        return "\(parentPath)/**"
    }

    /// Returns the directory the Read rule should scope to. For a file
    /// the rule scopes to the parent dir; for a directory the rule
    /// scopes to that dir directly. Mirrors upstream's
    /// `getDirectoryForPath` behavior.
    private static func readSuggestionParent(for target: BashReadTarget) -> String? {
        if target.isDirectory {
            var trimmed = target.path
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            return trimmed == "/" ? nil : trimmed
        }
        return parentDirectory(of: target.path)
    }

    private static func parentDirectory(of filePath: String) -> String? {
        let parent = (filePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent
    }

    /// Tools whose first positional argument is a verb (subcommand) and whose
    /// permission rule should bind both tokens — `git diff:*` rather than
    /// `git:*`. Mirrors claude-code's typical extraction for these CLIs.
    private static let multiVerbTools: Set<String> = [
        "git", "npm", "pnpm", "yarn", "bun", "uv",
        "gh", "docker", "kubectl", "cargo", "pip", "pipx", "brew", "go"
    ]

    /// Interpreter commands whose meaningful prefix is `interpreter
    /// <script-path>`. Without binding to the script path, an option-2
    /// pick would allowlist `bash *` (every future bash invocation) —
    /// way too broad. Matches upstream's TUI behavior.
    private static let interpreters: Set<String> = [
        "bash", "sh", "zsh", "fish", "ksh", "dash",
        "python", "python3", "python2",
        "node", "deno", "bun",
        "ruby", "perl", "php",
        "pytest", "rspec", "go"
    ]

    /// Mirrors claude-code's TUI widen at BashPermissionRequest.tsx:219-232:
    /// when upstream's `permission_suggestions` arrives with an exact-match
    /// rule (no `:*` suffix), the TUI re-derives a two-word or first-word
    /// prefix locally so the persisted rule and the displayed label widen
    /// to something reusable. The hook payload itself doesn't carry the
    /// widened form, so the adapter calls this to recover it.
    ///
    /// Returns `(displayName, ruleContent)`. `ruleContent` is the wildcard
    /// rule (e.g. `git:*`); `displayName` is the bare prefix (e.g. `git`).
    /// When no safe prefix exists (no first token, or first token has
    /// non-alphanumerics), falls back to the verbatim command.
    public static func widenedBashRule(content: String) -> (displayName: String, ruleContent: String) {
        // bashCommandPrefix has a `return head` fallback that's appropriate
        // for the local builder's `command` input (already-segmented, head is
        // a real verb), but not for upstream's exact-match payload, where the
        // head can be an absolute path / bare-shell prefix that upstream's
        // own getFirstWordPrefix would reject. Apply the same regex+blocklist
        // gate so paths fall back to the verbatim literal.
        guard let prefix = bashCommandPrefix(content),
              isFirstWordPrefixSafe(prefix) else {
            return (content, content)
        }
        return (prefix, "\(prefix):*")
    }

    /// Mirrors upstream `getFirstWordPrefix`'s acceptance regex
    /// (bashPermissions.ts:261) plus the BARE_SHELL_PREFIXES blocklist
    /// (bash, sh, env, sudo, …). For two-word prefixes we only validate
    /// the first token; the verb-token already passed the alphanumeric
    /// check inside bashCommandPrefix.
    private static func isFirstWordPrefixSafe(_ prefix: String) -> Bool {
        let head = prefix.split(separator: " ").first.map(String.init) ?? prefix
        guard head.range(of: "^[a-z][a-z0-9]*(-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            return false
        }
        return !bareShellPrefixes.contains(head)
    }

    /// Bare-prefix heads upstream refuses to widen to (see
    /// BARE_SHELL_PREFIXES in bashPermissions.ts:196). Allowlisting `bash:*`
    /// would let `bash -c "evil"` survive.
    private static let bareShellPrefixes: Set<String> = [
        "sh", "bash", "zsh", "fish", "csh", "tcsh", "ksh", "dash",
        "cmd", "powershell", "pwsh",
        "env", "xargs",
        "nice", "stdbuf", "nohup", "timeout", "time",
        "sudo", "doas", "pkexec",
    ]

    private static func bashCommandPrefix(_ command: String) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let head = tokens.first else { return nil }

        if multiVerbTools.contains(head),
           tokens.count >= 2,
           isAlphanumericVerb(tokens[1]) {
            return "\(head) \(tokens[1])"
        }

        // Interpreter binds to the script path so option-2 doesn't
        // allowlist every future invocation of the interpreter itself.
        if interpreters.contains(head),
           tokens.count >= 2,
           !tokens[1].hasPrefix("-") {
            return "\(head) \(tokens[1])"
        }

        return head
    }

    /// Strip "harmless" output redirections (stderr → /dev/null, stderr
    /// → fd) so a command like `find ... 2>/dev/null` doesn't trip
    /// the stdout-to-file detector. Mirrors upstream's
    /// `extractOutputRedirections` (bashPermissions.ts:789-797).
    static func strippedReadOnlyRedirections(_ command: String) -> String {
        var result = command
        let patterns = [
            #"\s*2>\s*/dev/null"#,
            #"\s*2>\s*&\s*\d+"#,
            #"\s*&>\s*/dev/null"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAlphanumericVerb(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
