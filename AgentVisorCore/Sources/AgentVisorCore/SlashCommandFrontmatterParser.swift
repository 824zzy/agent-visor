import Foundation

/// Parses a markdown file with optional YAML-ish frontmatter into a
/// `SlashCommand`. Matches claude-code-main's `loadSkillsDir` parser
/// closely enough to handle every real-world skill file the user has
/// installed, without pulling in a full YAML dependency.
///
/// Supported frontmatter shape:
///
///     ---
///     name: my-cmd                 # required-ish — falls back to filename
///     description: One-liner       # optional; falls back to first body paragraph
///     aliases: [a, b]              # optional inline array
///     argNames: [arg1, arg2]       # optional inline array
///     argumentHint: N              # optional scalar
///     isHidden: true|false         # optional bool
///     ---
///
/// Strings may be unquoted, single-quoted, or double-quoted. Inline
/// arrays use bracketed comma-separated form. Block-style arrays
/// (multi-line dashes) are not supported — no real claude-code skill
/// uses them.
public enum SlashCommandFrontmatterParser {

    /// Parse a markdown source into a `SlashCommand`. Returns nil for
    /// structurally broken frontmatter (e.g., opened but not closed) so
    /// the caller can drop the file silently rather than crash.
    /// `fallbackName` is used when frontmatter omits `name`; callers
    /// derive it from the file basename minus extension.
    public static func parse(markdown: String, fallbackName: String) -> SlashCommand? {
        let frontmatter: [String: String]
        let body: String

        if markdown.hasPrefix("---") {
            switch extractFrontmatter(from: markdown) {
            case .some(let extracted):
                frontmatter = extracted.fields
                body = extracted.body
            case .none:
                return nil
            }
        } else {
            frontmatter = [:]
            body = markdown
        }

        let name = stringValue(frontmatter["name"]) ?? fallbackName
        let aliases = arrayValue(frontmatter["aliases"]) ?? []
        let argNames = arrayValue(frontmatter["argNames"]) ?? []
        let argumentHint = stringValue(frontmatter["argumentHint"])
        let isHidden = boolValue(frontmatter["isHidden"]) ?? false
        let description: String = {
            if let d = stringValue(frontmatter["description"]), !d.isEmpty { return d }
            return firstBodyParagraph(body)
        }()

        return SlashCommand(
            name: name,
            aliases: aliases,
            description: description,
            argumentHint: argumentHint,
            argNames: argNames,
            source: .builtin,  // overwritten by caller; the parser doesn't know
            isHidden: isHidden
        )
    }

    private struct ExtractedFrontmatter {
        let fields: [String: String]
        let body: String
    }

    /// Splits a `---`-delimited frontmatter block off the front of the
    /// markdown. Returns nil when the closing `---` is missing.
    private static func extractFrontmatter(from markdown: String) -> ExtractedFrontmatter? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return nil }

        guard let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            return nil  // Opened but never closed.
        }

        let fieldLines = Array(lines[1..<closeIdx])
        var fields: [String: String] = [:]
        for line in fieldLines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            fields[key] = value
        }

        let bodyLines = Array(lines[(closeIdx + 1)...])
        return ExtractedFrontmatter(fields: fields, body: bodyLines.joined(separator: "\n"))
    }

    /// Strip surrounding quotes if present. An unquoted YAML scalar is
    /// returned as-is. Empty strings collapse to nil so the caller can
    /// distinguish "field absent" from "field present but empty."
    private static func stringValue(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var s = raw
        if s.count >= 2 {
            let first = s.first!
            let last = s.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                s = String(s.dropFirst().dropLast())
            }
        }
        return s.isEmpty ? nil : s
    }

    /// Parse `[a, b, c]` style inline arrays. Returns nil for "not
    /// present" and an empty array for `[]`.
    private static func arrayValue(_ raw: String?) -> [String]? {
        guard let raw = raw else { return nil }
        guard raw.hasPrefix("[") && raw.hasSuffix("]") else { return nil }
        let inner = String(raw.dropFirst().dropLast())
        if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return inner
            .split(separator: ",")
            .map { stringValue(String($0).trimmingCharacters(in: .whitespaces)) ?? "" }
            .filter { !$0.isEmpty }
    }

    private static func boolValue(_ raw: String?) -> Bool? {
        guard let raw = raw?.lowercased() else { return nil }
        if raw == "true" || raw == "yes" { return true }
        if raw == "false" || raw == "no" { return false }
        return nil
    }

    /// First non-blank paragraph of the body, joined into a single line.
    /// Skips leading blank lines. Stops at the next blank line.
    private static func firstBodyParagraph(_ body: String) -> String {
        var paragraphLines: [String] = []
        var seenContent = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if seenContent { break }
                continue
            }
            seenContent = true
            paragraphLines.append(trimmed)
        }
        return paragraphLines.joined(separator: " ")
    }
}
