//
//  CodexMemoryCitationStripper.swift
//  AgentVisorCore
//
//  Removes Codex's internal `<oai-mem-citation>…</oai-mem-citation>`
//  memory-citation trailer from assistant message text.
//
//  Codex's memory system instructs the model to append this block to
//  the END of its final reply (citation_entries + rollout_ids it found
//  useful). Codex's own UI parses and strips it before display; our
//  transcript reader gets the raw text, so without this strip the
//  markup leaks into the rendered chat (user-reported: a literal
//  `<oai-mem-citation>…` block under the final answer).
//
//  Pure / value-in-value-out so it's unit-testable.
//

import Foundation

public enum CodexMemoryCitationStripper {
    /// Remove every `<oai-mem-citation>…</oai-mem-citation>` block from
    /// `text` and trim the whitespace the removal leaves behind. The
    /// block is normally a suffix, but we strip it wherever it appears
    /// (defensive — model output ordering isn't guaranteed). Plain
    /// angle-bracket content in the body (e.g. `Vec<String>`) is
    /// untouched because we match the specific tag pair only.
    public static func strip(_ text: String) -> String {
        guard text.contains(openTag) else { return text }

        var result = text
        while let range = blockRange(in: result) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let openTag = "<oai-mem-citation>"
    private static let closeTag = "</oai-mem-citation>"

    /// Range covering one full `<oai-mem-citation>…</oai-mem-citation>`
    /// block (tags inclusive), plus any whitespace immediately preceding
    /// the open tag — so removing a block sitting between two body
    /// paragraphs collapses their separator instead of leaving a double
    /// blank line. Returns nil if no block remains.
    private static func blockRange(in text: String) -> Range<String.Index>? {
        guard let open = text.range(of: openTag) else { return nil }
        // Walk the lower bound back over leading whitespace/newlines.
        var lower = open.lowerBound
        while lower > text.startIndex {
            let prev = text.index(before: lower)
            guard text[prev].isWhitespace else { break }
            lower = prev
        }
        guard let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) else {
            // Unterminated open tag: drop from the open tag to the end so
            // a truncated trailer can't leak either.
            return lower..<text.endIndex
        }
        return lower..<close.upperBound
    }
}
