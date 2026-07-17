import Foundation

/// Segment of a markdown inline run after LaTeX-aware scanning. The
/// markdown pipeline emits one of these per literal-text or formula
/// span; the renderer flattens the run into an AttributedString,
/// rendering math spans as image attachments via a SwiftMath-backed
/// helper.
public enum LaTeXSegment: Equatable, Sendable {
    /// Literal text (with backslash-dollar escapes already resolved).
    case text(String)
    /// Inline math: source between matching single `$` delimiters.
    /// Body text is the LaTeX content (without the dollar signs).
    case inlineMath(String)
    /// Display math: source between matching `$$` delimiters. The
    /// renderer can promote a paragraph that's *just* a single
    /// `displayMath` segment to a centered block.
    case displayMath(String)
}

/// Splits a plain inline string into a run of `LaTeXSegment`s.
///
/// Conventions match the de-facto markdown-LaTeX dialect (GitHub
/// math, Notion, Obsidian, Pandoc default):
///
/// - `$$...$$`  → display math. Greedy: takes precedence over `$..$`.
/// - `$...$`    → inline math. Body must be non-empty.
/// - `\$`       → literal `$` (escape).
/// - Unclosed `$` → literal text (no implicit closing at end-of-string).
/// - Empty math (`$$`, `$$<no body>$$`) → literal text.
///
/// Code-span / code-block exclusion is the *caller's* responsibility:
/// this enum sees only the inline plaintext that swift-markdown has
/// already decided is *not* code. Doing the gating one layer up keeps
/// this type pure and unit-testable in isolation.
public enum LaTeXRangeExtractor {
    public static func segments(in source: String) -> [LaTeXSegment] {
        if source.isEmpty { return [] }

        var result: [LaTeXSegment] = []
        var literal = ""
        let chars = Array(source)
        var i = 0

        func flushLiteral() {
            if !literal.isEmpty {
                result.append(.text(literal))
                literal = ""
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Backslash escape: only `\$` collapses to a literal `$`.
            // Other backslash-prefixed runs are kept verbatim — they're
            // typically LaTeX commands that the math scanner will
            // process inside a math span; outside of one they're just
            // text.
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                literal.append("$")
                i += 2
                continue
            }

            if c == "$" {
                // `$$` → display math attempt. Find the matching `$$`.
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let endRel = findClosingDelimiter(
                        in: chars,
                        startIndex: i + 2,
                        delimiter: "$$"
                    ), endRel > i + 2 {
                        flushLiteral()
                        let body = String(chars[(i + 2)..<endRel])
                        result.append(.displayMath(body))
                        i = endRel + 2
                        continue
                    } else {
                        // No closing `$$` (or empty body) → literal `$$`.
                        literal.append("$$")
                        i += 2
                        continue
                    }
                }

                // Single `$` → inline math attempt.
                if let endRel = findClosingDelimiter(
                    in: chars,
                    startIndex: i + 1,
                    delimiter: "$"
                ), endRel > i + 1 {
                    flushLiteral()
                    let body = String(chars[(i + 1)..<endRel])
                    result.append(.inlineMath(body))
                    i = endRel + 1
                    continue
                } else {
                    // No closing `$` → literal.
                    literal.append("$")
                    i += 1
                    continue
                }
            }

            literal.append(c)
            i += 1
        }

        flushLiteral()
        return result
    }

    /// Find the index of the next unescaped occurrence of `delimiter`
    /// (either `$` or `$$`) starting at `startIndex`. Returns the
    /// index of the FIRST char of the delimiter, or `nil` if none.
    /// Backslash-escaped dollars don't count as delimiters; this
    /// matches the escape rule applied to literal text.
    private static func findClosingDelimiter(
        in chars: [Character],
        startIndex: Int,
        delimiter: String
    ) -> Int? {
        let isDouble = delimiter == "$$"
        var j = startIndex
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count, chars[j + 1] == "$" {
                j += 2
                continue
            }
            if c == "$" {
                let isCurrentDouble = j + 1 < chars.count && chars[j + 1] == "$"
                if isDouble {
                    if isCurrentDouble { return j }
                    // A single `$` inside `$$..$$` is fine — keep
                    // scanning for the closing `$$`.
                    j += 1
                    continue
                } else {
                    if isCurrentDouble {
                        // `$$` while scanning for inline `$` —
                        // ambiguous; bail (caller falls back to literal).
                        return nil
                    }
                    return j
                }
            }
            j += 1
        }
        return nil
    }
}
