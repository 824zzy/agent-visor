//
//  ClaudeLocalCommandParser.swift
//  AgentVisorCore
//
//  Splits a claude-code `system` / `local_command` transcript row into
//  the pieces worth showing. A TUI built-in such as `/rename foo` writes
//  up to two rows (claude-code 2.1.268):
//
//    <command-name>/rename</command-name>
//    <command-message>rename</command-message>
//    <command-args>foo</command-args>
//
//    <local-command-stdout>Session renamed to: foo</local-command-stdout>
//
//  The first row is the invocation echo, the second the output mirror.
//  Older releases only wrote the output row (the echo was a user row,
//  which `ConversationParser` drops). Rendering the echo row's raw
//  pseudo-XML leaked `<command-name>…` into the chat; this parser turns
//  it into the `/rename foo` line the user actually typed.
//

import Foundation

public struct ClaudeLocalCommandRecord: Equatable, Sendable {
    /// The slash command as the user typed it, e.g. `/rename foo`.
    /// Rebuilt from `<command-name>` + `<command-args>`; the redundant
    /// `<command-message>` is dropped.
    public let invocation: String?

    /// What the built-in printed, unwrapped from `<local-command-stdout>`
    /// / `<local-command-stderr>`. Blank output collapses to nil.
    public let output: String?

    public init(invocation: String?, output: String?) {
        self.invocation = invocation
        self.output = output
    }

    /// Lines to render, in transcript order: invocation first, then
    /// output. Empty when the row carries nothing user-facing (e.g. the
    /// empty stdout mirror that `/clear` writes).
    public var displayLines: [String] {
        [invocation, output].compactMap { $0 }
    }
}

public enum ClaudeLocalCommandParser {
    private static let outputTags = ["local-command-stdout", "local-command-stderr"]

    public static func parse(_ raw: String) -> ClaudeLocalCommandRecord {
        var working = raw

        // Output mirror(s), in document order. An open tag with no close
        // keeps whatever follows so a truncated or reshaped row still
        // renders something instead of silently vanishing.
        var outputParts: [String] = []
        for tag in outputTags {
            while let block = TranscriptTagScanner.locateBlock(named: tag, in: working) {
                outputParts.append(block.content)
                working.removeSubrange(block.range)
            }
            if let openRange = working.range(of: "<\(tag)>") {
                outputParts.append(String(working[openRange.upperBound...]))
                working.removeSubrange(openRange.lowerBound..<working.endIndex)
            }
        }

        // Invocation echo. `<command-message>` duplicates the name
        // without the leading slash, so it is stripped, not surfaced.
        let name = TranscriptTagScanner.extractAndRemoveBody(named: "command-name", in: &working)
        let args = TranscriptTagScanner.extractAndRemoveBody(named: "command-args", in: &working)
        TranscriptTagScanner.stripAllOccurrences(of: "command-message", in: &working)

        var invocation: String?
        if let name {
            invocation = args.map { "\(name) \($0)" } ?? name
        } else if let args {
            invocation = args
        }

        // Anything left is free text. With no recognised tag the row IS
        // the output (pre-tag shapes); next to tags, keep it rather than
        // dropping it on the floor.
        let leftover = working.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            outputParts.append(leftover)
        }

        let outputLines = outputParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let output = outputLines.isEmpty ? nil : outputLines.joined(separator: "\n")

        return ClaudeLocalCommandRecord(invocation: invocation, output: output)
    }
}
