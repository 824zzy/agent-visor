//
//  TranscriptTagScanner.swift
//  AgentVisorCore
//
//  Shared scanner for the pseudo-XML tags claude-code writes into
//  transcript rows (`<command-name>`, `<local-command-stdout>`, …).
//  Tags match literally: exact name, no attributes, no nesting.
//  `InjectionTagParser` (user rows) and `ClaudeLocalCommandParser`
//  (system/local_command rows) both build on it so the two never drift.
//

import Foundation

struct TranscriptTagBlock: Equatable {
    /// Text between the open and close tag, untrimmed.
    let content: String
    /// Range covering the open tag, the content, and the close tag.
    let range: Range<String.Index>
}

enum TranscriptTagScanner {
    /// Find the first `<name>…</name>` block in `text`. Non-greedy on
    /// content (uses the first close after the open). Returns nil when
    /// the open tag is missing or has no matching close.
    static func locateBlock(named tag: String, in text: String) -> TranscriptTagBlock? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let openRange = text.range(of: openTag) else { return nil }
        guard let closeRange = text.range(
            of: closeTag,
            range: openRange.upperBound..<text.endIndex
        ) else { return nil }
        return TranscriptTagBlock(
            content: String(text[openRange.upperBound..<closeRange.lowerBound]),
            range: openRange.lowerBound..<closeRange.upperBound
        )
    }

    /// Pull the trimmed body of the FIRST `<tag>…</tag>` block out of
    /// `text`, removing the whole block from the string. Returns nil when
    /// the tag is absent or its body is blank.
    static func extractAndRemoveBody(named tag: String, in text: inout String) -> String? {
        guard let block = locateBlock(named: tag, in: text) else { return nil }
        let body = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        text.removeSubrange(block.range)
        return body.isEmpty ? nil : body
    }

    /// Remove every `<tag>…</tag>` block from `text`.
    static func stripAllOccurrences(of tag: String, in text: inout String) {
        while let block = locateBlock(named: tag, in: text) {
            text.removeSubrange(block.range)
        }
    }
}
