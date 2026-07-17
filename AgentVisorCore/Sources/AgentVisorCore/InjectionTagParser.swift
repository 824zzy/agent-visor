//
//  InjectionTagParser.swift
//  AgentVisorCore
//
//  Strips claude-code's pseudo-XML injection tags out of user message
//  text, surfacing structured attachments and hidden plumbing
//  separately. claude-code wraps IDE/system context into the user's
//  content payload using tags like <ide_opened_file>, <system-reminder>,
//  <command-message>, etc. Cursor's webview post-processes these into
//  attachment chips; agent-visor needs the same step or the raw tags
//  show up as ugly message bubbles.
//
//  Two categories of tags:
//    1. Attachment tags — surface metadata to the UI as chips
//       (e.g. <ide_opened_file> becomes a file-name chip)
//    2. Hidden tags — pure plumbing, never user-facing
//       (e.g. <system-reminder>, <command-message>)
//

import Foundation

public struct ParsedUserMessage: Equatable, Sendable {
    public let plainText: String
    public let attachments: [Attachment]

    public init(plainText: String, attachments: [Attachment] = []) {
        self.plainText = plainText
        self.attachments = attachments
    }

    /// Structured representation of an injection tag worth showing to
    /// the user. Each case knows what to render (filename, line range,
    /// etc.) — the UI maps it to a chip.
    public enum Attachment: Equatable, Sendable {
        case openedFile(path: String)
        case selection(path: String, startLine: Int?, endLine: Int?)
    }
}

public enum InjectionTagParser {
    /// Tag names whose contents are pure plumbing. Stripped wholesale
    /// (open tag, content, close tag — all gone).
    private static let hiddenTags: [String] = [
        "system-reminder",
        "command-message",
        "local-command-stdout",
        "local-command-stderr",
        "bash-stdout",
        "bash-stderr",
        "user-prompt-submit-hook",
    ]

    public static func parse(_ text: String) -> ParsedUserMessage {
        var working = text
        var attachments: [ParsedUserMessage.Attachment] = []

        // Pass 1: extract attachment tags in document order. Each loop
        // pulls one occurrence; preserves the order they appeared in.
        while let occurrence = findFirstAttachmentTag(in: working) {
            attachments.append(occurrence.attachment)
            working.removeSubrange(occurrence.range)
        }

        // Pass 2: pull out the slash-command name and args. Their bodies
        // ARE the user's prompt — claude-code wraps `/foo bar baz` as
        // `<command-name>/foo</command-name>\n<command-args>bar baz</command-args>`.
        // Stripping them wholesale (as we used to) hid the user's own
        // message; render `<name> <args>` joined with a space, with any
        // remaining free-form text appended after a newline.
        let commandName = extractAndRemoveTagBody(named: "command-name", in: &working)
        let commandArgs = extractAndRemoveTagBody(named: "command-args", in: &working)

        // Pass 3: strip hidden tags. Order within hidden doesn't matter
        // because nothing is surfaced.
        for tag in hiddenTags {
            stripAllOccurrences(of: tag, in: &working)
        }

        let remainder = working.trimmingCharacters(in: .whitespacesAndNewlines)

        var commandLine = ""
        if let n = commandName, !n.isEmpty {
            commandLine = n
            if let a = commandArgs, !a.isEmpty {
                commandLine += " " + a
            }
        } else if let a = commandArgs, !a.isEmpty {
            commandLine = a
        }

        let cleaned: String
        if commandLine.isEmpty {
            cleaned = remainder
        } else if remainder.isEmpty {
            cleaned = commandLine
        } else {
            cleaned = commandLine + "\n" + remainder
        }

        return ParsedUserMessage(plainText: cleaned, attachments: attachments)
    }

    /// Pull the inner body of the FIRST `<tag>…</tag>` block out of
    /// `text`, removing the wrapper from the string. Returns nil if no
    /// such tag exists. Trims whitespace from the body.
    private static func extractAndRemoveTagBody(named tag: String, in text: inout String) -> String? {
        guard let block = locateTagBlock(named: tag, in: text) else { return nil }
        let body = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
        text.removeSubrange(block.range)
        return body.isEmpty ? nil : body
    }

    // MARK: - Attachment extraction

    private struct AttachmentMatch {
        let attachment: ParsedUserMessage.Attachment
        let range: Range<String.Index>
    }

    /// Find the earliest attachment-style tag in the string and return
    /// the parsed attachment + the range to remove. Returns nil if no
    /// known attachment tag is present.
    private static func findFirstAttachmentTag(in text: String) -> AttachmentMatch? {
        var earliest: AttachmentMatch?

        if let m = matchOpenedFile(in: text), earliest == nil || m.range.lowerBound < earliest!.range.lowerBound {
            earliest = m
        }
        if let m = matchSelection(in: text), earliest == nil || m.range.lowerBound < earliest!.range.lowerBound {
            earliest = m
        }
        return earliest
    }

    private static func matchOpenedFile(in text: String) -> AttachmentMatch? {
        guard let tagBlock = locateTagBlock(named: "ide_opened_file", in: text) else { return nil }
        let path = extractOpenedFilePath(from: tagBlock.content)
        // Even if path extraction fails, we still remove the tag block
        // so it doesn't render as garbage; we just skip emitting an
        // attachment in that case.
        guard let path else {
            return AttachmentMatch(
                attachment: .openedFile(path: ""),
                range: tagBlock.range
            )
        }
        return AttachmentMatch(
            attachment: .openedFile(path: path),
            range: tagBlock.range
        )
    }

    private static func matchSelection(in text: String) -> AttachmentMatch? {
        guard let tagBlock = locateTagBlock(named: "ide_selection", in: text) else { return nil }
        let (path, startLine, endLine) = extractSelection(from: tagBlock.content)
        return AttachmentMatch(
            attachment: .selection(path: path ?? "", startLine: startLine, endLine: endLine),
            range: tagBlock.range
        )
    }

    /// "The user opened the file /path/to/file in the IDE. …"
    private static func extractOpenedFilePath(from content: String) -> String? {
        let openPhrase = "opened the file "
        let closePhrase = " in the IDE"
        guard let start = content.range(of: openPhrase)?.upperBound,
              let end = content.range(of: closePhrase, range: start..<content.endIndex)?.lowerBound
        else { return nil }
        let raw = String(content[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// "The user selected the lines 12 to 34 of file /path/to/file …"
    /// or "The user selected line 12 of file /path/to/file …".
    /// Best-effort — claude-code formats may vary across versions; we
    /// extract whatever's recognizable.
    private static func extractSelection(from content: String) -> (String?, Int?, Int?) {
        var startLine: Int?
        var endLine: Int?
        var path: String?

        // Try "lines N to M"
        if let r = content.range(of: #"lines (\d+) to (\d+)"#, options: .regularExpression) {
            let match = String(content[r])
            let nums = match.split(separator: " ").compactMap { Int($0) }
            if nums.count == 2 {
                startLine = nums[0]
                endLine = nums[1]
            }
        } else if let r = content.range(of: #"line (\d+)"#, options: .regularExpression) {
            let match = String(content[r])
            let nums = match.split(separator: " ").compactMap { Int($0) }
            if let first = nums.first {
                startLine = first
                endLine = first
            }
        }

        // Try "of file /path/to/file …". The path stops at a sentinel
        // phrase (" in the IDE", " in IDE", "\n") or end-of-string —
        // NOT at any `.` or `,` because paths contain those.
        if let start = content.range(of: "of file ")?.upperBound {
            let tail = String(content[start...])
            let sentinels = [" in the IDE", " in IDE", "\n"]
            var stopIdx: String.Index? = nil
            for sentinel in sentinels {
                if let r = tail.range(of: sentinel),
                   stopIdx == nil || r.lowerBound < stopIdx! {
                    stopIdx = r.lowerBound
                }
            }
            let end = stopIdx ?? tail.endIndex
            let raw = String(tail[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Trim a trailing period if the tail ends with one (single-
            // sentence selections without a sentinel phrase).
            let cleaned = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
            path = cleaned.isEmpty ? nil : cleaned
        }

        return (path, startLine, endLine)
    }

    // MARK: - Hidden-tag stripping

    private static func stripAllOccurrences(of tag: String, in text: inout String) {
        while let block = locateTagBlock(named: tag, in: text) {
            text.removeSubrange(block.range)
        }
    }

    // MARK: - Tag finder

    private struct TagBlock {
        let content: String
        let range: Range<String.Index>
    }

    /// Find the first `<name>…</name>` block in the text. Match is
    /// non-greedy on content (uses the first close after the open).
    /// Tag names match case-sensitively and exactly — no attribute
    /// support, no nesting.
    private static func locateTagBlock(named tag: String, in text: String) -> TagBlock? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        guard let openRange = text.range(of: openTag) else { return nil }
        guard let closeRange = text.range(
            of: closeTag,
            range: openRange.upperBound..<text.endIndex
        ) else { return nil }
        let content = String(text[openRange.upperBound..<closeRange.lowerBound])
        return TagBlock(
            content: content,
            range: openRange.lowerBound..<closeRange.upperBound
        )
    }
}
