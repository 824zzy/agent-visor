import Foundation

/// One segment of a Bash command source string. A segment is the text
/// between top-level statement / pipeline operators (`\n`, `;`, `&&`,
/// `||`, `|`). Quote- and escape-aware: separators inside `'...'`,
/// `"..."`, or after `\` do not split.
public struct BashSegment: Equatable, Sendable {
    /// Segment text, exactly as it appeared in the source. Surrounding
    /// whitespace is NOT trimmed (callers usually trim before per-
    /// segment classification).
    public let text: String
    /// True if this segment contains an unescaped `$()` command
    /// substitution or backtick substitution outside of single-quotes.
    /// Callers should skip unsafe segments rather than emit rules — we
    /// can't safely allowlist a command whose effective text depends
    /// on the substitution result.
    public let isUnsafe: Bool

    public init(text: String, isUnsafe: Bool) {
        self.text = text
        self.isUnsafe = isUnsafe
    }
}

/// Splits a Bash command source string into top-level segments.
/// Matches the spirit of upstream `splitCommandWithOperators`
/// (claude-code-main commands.ts:85-249) with a tiny state machine —
/// no tree-sitter or shell-quote dependency.
public enum BashSegmenter {
    public static func segments(_ source: String) -> [BashSegment] {
        var result: [BashSegment] = []
        var buf = ""
        var unsafeFlag = false
        var state: State = .normal
        var parenDepth = 0

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

            switch state {
            case .normal:
                switch c {
                case "'":
                    state = .singleQuote
                    buf.append(c)
                case "\"":
                    state = .doubleQuote
                    buf.append(c)
                case "\\":
                    state = .escape(returnTo: .normal)
                    buf.append(c)
                case "`":
                    unsafeFlag = true
                    buf.append(c)
                case "$" where next == "(":
                    state = .dollarParen
                    parenDepth = 1
                    unsafeFlag = true
                    buf.append("$(")
                    i += 2
                    continue
                case "\n", ";":
                    flush(&buf, &unsafeFlag, into: &result)
                    i += 1
                    continue
                case "&" where next == "&":
                    flush(&buf, &unsafeFlag, into: &result)
                    i += 2
                    continue
                case "|" where next == "|":
                    flush(&buf, &unsafeFlag, into: &result)
                    i += 2
                    continue
                case "|":
                    flush(&buf, &unsafeFlag, into: &result)
                    i += 1
                    continue
                default:
                    buf.append(c)
                }
            case .singleQuote:
                buf.append(c)
                if c == "'" { state = .normal }
            case .doubleQuote:
                switch c {
                case "\\":
                    state = .escape(returnTo: .doubleQuote)
                    buf.append(c)
                case "$" where next == "(":
                    unsafeFlag = true
                    buf.append("$(")
                    parenDepth += 1
                    state = .dollarParen
                    i += 2
                    continue
                case "`":
                    unsafeFlag = true
                    buf.append(c)
                case "\"":
                    state = .normal
                    buf.append(c)
                default:
                    buf.append(c)
                }
            case .escape(let returnTo):
                buf.append(c)
                state = returnTo
            case .dollarParen:
                buf.append(c)
                if c == "(" { parenDepth += 1 }
                if c == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 { state = .normal }
                }
            }

            i += 1
        }

        // Drain final segment.
        flush(&buf, &unsafeFlag, into: &result, force: true)
        return result
    }

    private static func flush(
        _ buf: inout String,
        _ unsafeFlag: inout Bool,
        into result: inout [BashSegment],
        force: Bool = false
    ) {
        let trimmed = buf.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result.append(BashSegment(text: trimmed, isUnsafe: unsafeFlag))
        } else if force && !buf.isEmpty {
            // empty-after-trim final flush — drop silently.
        }
        buf = ""
        unsafeFlag = false
    }

    private indirect enum State {
        case normal
        case singleQuote
        case doubleQuote
        case escape(returnTo: State)
        case dollarParen
    }
}
