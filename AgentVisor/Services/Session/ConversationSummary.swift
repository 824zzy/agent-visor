//
//  ConversationSummary.swift
//  AgentVisor
//
//  Lightweight head+tail JSONL parser for the sessions-list.
//
//  Lives on its own actor (separate from ConversationParser) so the
//  bootstrap fan-out — N concurrent parses, one per recently-modified
//  session — can't queue ahead of the chat panel's
//  `parseFullConversation` call. With both on the same actor, opening a
//  huge session's chat panel waited for every other session's summary
//  to finish first; on a 458 MB transcript that meant 20+ s of "Loading
//  messages…" before the parse even started. See task #232 for the
//  bisect that pinned this.
//
//  Summary state is read-only after construction (cache by mtime), so
//  there's no shared state to coordinate with ConversationParser.
//
//  Public API mirrors the previous `ConversationParser.parse(...)`
//  signature exactly so call-site migration is a rename.
//

import AgentVisorCore
import Foundation
import os.log

actor ConversationSummary {
    static let shared = ConversationSummary()

    nonisolated static let logger = Logger(subsystem: AppBranding.loggerSubsystem, category: "Summary")

    /// Cache of parsed conversation info, keyed by session file path.
    /// Cache hit is gated on the file's modification date — if the
    /// JSONL grew, we re-read head+tail on next call.
    private var cache: [String: CachedInfo] = [:]

    private struct CachedInfo {
        let modificationDate: Date
        let info: ConversationInfo
    }

    private init() {}

    /// Files larger than this read just the head and tail. The summary
    /// fields (`firstUserMessage` near the top, `lastMessage` / `lastCwd` /
    /// `lastUserMessageDate` near the bottom) live at the file's edges and
    /// the middle isn't useful for `ConversationInfo`. For files at or below
    /// the threshold we still read the whole file so behavior matches the
    /// pre-tail-parse implementation.
    ///
    /// Head needs to be generous: Zed's claude-acp prepends lots of
    /// `system` / `attachment` / `hook_progress` rows before the first
    /// user turn, and a 32 KB head missed `firstUserMessage` on Zed
    /// transcripts past ~5 turns of attachments. 256 KB head reliably
    /// reaches the first user message across the sessions we see in
    /// practice; pair it with a 512 KB threshold so head + tail never
    /// overlap.
    private static let smallFileThreshold: UInt64 = 512 * 1024
    private static let headBytes: UInt64 = 256 * 1024
    private static let tailBytes: UInt64 = 128 * 1024
    /// Flip this to `false` to fall back to whole-file reads if tail-parse
    /// causes any session-list regression. Single-flag kill switch.
    private static let tailParseEnabled = true

    func parse(sessionId: String, cwd: String) -> ConversationInfo {
        let projectDir = ClaudeProjectPathEncoder.projectDirName(forCwd: cwd)
        let sessionFile = NSHomeDirectory() + "/.claude/projects/" + projectDir + "/" + sessionId + ".jsonl"

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionFile),
              let attrs = try? fileManager.attributesOfItem(atPath: sessionFile),
              let modDate = attrs[.modificationDate] as? Date else {
            return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil, lastCwd: nil, lastModelName: nil, lastContextTokens: nil, lastPermissionMode: nil)
        }

        if let cached = cache[sessionFile], cached.modificationDate == modDate {
            return cached.info
        }

        let fileSize = (attrs[.size] as? UInt64) ?? 0
        let content: String
        if Self.tailParseEnabled && fileSize > Self.smallFileThreshold {
            guard let s = readHeadAndTail(filePath: sessionFile, fileSize: fileSize) else {
                return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil, lastCwd: nil, lastModelName: nil, lastContextTokens: nil, lastPermissionMode: nil)
            }
            content = s
            Self.logger.debug("tail-parse: \(sessionId.prefix(8), privacy: .public) size=\(fileSize) read=\(s.utf8.count)")
        } else {
            guard let data = fileManager.contents(atPath: sessionFile),
                  let s = String(data: data, encoding: .utf8) else {
                return ConversationInfo(summary: nil, lastMessage: nil, lastMessageRole: nil, lastToolName: nil, firstUserMessage: nil, lastUserMessageDate: nil, lastCwd: nil, lastModelName: nil, lastContextTokens: nil, lastPermissionMode: nil)
            }
            content = s
        }

        let info = parseContent(content)
        cache[sessionFile] = CachedInfo(modificationDate: modDate, info: info)

        return info
    }

    /// Read just the head (first `headBytes`) and tail (last `tailBytes`) of
    /// a JSONL file, joined with a newline. Drops the partial line that
    /// straddles each seek boundary so the per-line JSON parser in
    /// `parseContent` never sees a truncated line.
    private func readHeadAndTail(filePath: String, fileSize: UInt64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }

        let headData: Data
        do {
            try handle.seek(toOffset: 0)
            headData = (try handle.read(upToCount: Int(Self.headBytes))) ?? Data()
        } catch {
            return nil
        }

        let tailStart = fileSize > Self.tailBytes ? fileSize - Self.tailBytes : 0
        let tailData: Data
        do {
            try handle.seek(toOffset: tailStart)
            tailData = (try handle.readToEnd()) ?? Data()
        } catch {
            return nil
        }

        let headStr = String(data: headData, encoding: .utf8) ?? ""
        let tailStr = String(data: tailData, encoding: .utf8) ?? ""

        // Head: keep up to the last newline so we don't end on a partial line.
        let cleanHead: String
        if let idx = headStr.lastIndex(of: "\n") {
            cleanHead = String(headStr[..<idx])
        } else {
            cleanHead = headStr
        }

        // Tail: drop everything before the first newline so we don't start
        // on a partial line whose prefix was lost to the seek.
        let cleanTail: String
        if let idx = tailStr.firstIndex(of: "\n") {
            cleanTail = String(tailStr[tailStr.index(after: idx)...])
        } else {
            cleanTail = tailStr
        }

        return cleanHead + "\n" + cleanTail
    }

    /// Parse JSONL content into a ConversationInfo summary.
    private func parseContent(_ content: String) -> ConversationInfo {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        var summary: String?
        var lastMessage: String?
        var lastMessageRole: String?
        var lastToolName: String?
        var firstUserMessage: String?
        var lastCwd: String?
        var lastUserMessageDate: Date?

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let isMeta = json["isMeta"] as? Bool ?? false

            if type == "user" && !isMeta {
                if let message = json["message"] as? [String: Any] {
                    // String shape: vanilla CLI turn. Skip the prefixes
                    // that mark synthetic "command" entries Claude Code
                    // appends for slash-commands / clear / etc.
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>")
                            && !msgContent.hasPrefix("<local-command")
                            && !msgContent.hasPrefix("Caveat:") {
                            firstUserMessage = Self.truncateMessage(msgContent, maxLength: 50)
                            break
                        }
                    } else if let contentArray = message["content"] as? [[String: Any]] {
                        // Blocks shape: Zed / Cursor / claude-acp wrap
                        // first turns as content blocks (text + image
                        // attachments). Walk the blocks for the first
                        // text block — that's what the human typed.
                        // Without this branch, sessions whose first
                        // user message has any image/tool block fall
                        // through to "New session" forever, which
                        // looks broken.
                        for block in contentArray {
                            if block["type"] as? String == "text",
                               let text = block["text"] as? String,
                               !text.isEmpty {
                                firstUserMessage = Self.truncateMessage(text, maxLength: 50)
                                break
                            }
                        }
                        if firstUserMessage != nil { break }
                    }
                }
            }
        }

        var foundLastUserMessage = false
        var lastActivityDate: Date?
        var lastModelName: String?
        var lastContextTokens: Int?
        var lastPermissionMode: String?

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            // Track the most recent cwd (first one found in reverse = latest)
            if lastCwd == nil, let cwd = json["cwd"] as? String, !cwd.isEmpty {
                lastCwd = cwd
            }

            // Extract model + context tokens from the most recent assistant message
            if lastModelName == nil, type == "assistant" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let model = message["model"] as? String, !model.isEmpty, !model.hasPrefix("<") {
                        lastModelName = model
                    }
                    if lastContextTokens == nil, let usage = message["usage"] as? [String: Any] {
                        let input = usage["input_tokens"] as? Int ?? 0
                        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                        let total = input + cacheRead + cacheCreation
                        if total > 0 {
                            lastContextTokens = total
                        }
                    }
                }
            }

            // Extract permission mode from side-channel lines
            if lastPermissionMode == nil, type == "permission-mode" {
                if let mode = json["permissionMode"] as? String {
                    lastPermissionMode = mode
                }
            }

            if lastMessage == nil {
                if type == "user" || type == "assistant" {
                    let isMeta = json["isMeta"] as? Bool ?? false
                    if !isMeta, let message = json["message"] as? [String: Any] {
                        if let msgContent = message["content"] as? String {
                            if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                                lastMessage = msgContent
                                lastMessageRole = type
                            }
                        } else if let contentArray = message["content"] as? [[String: Any]] {
                            for block in contentArray.reversed() {
                                let blockType = block["type"] as? String
                                if blockType == "tool_use" {
                                    let toolName = block["name"] as? String ?? "Tool"
                                    let toolInput = Self.formatToolInput(block["input"] as? [String: Any], toolName: toolName)
                                    lastMessage = toolInput
                                    lastMessageRole = "tool"
                                    lastToolName = toolName
                                    break
                                } else if blockType == "text", let text = block["text"] as? String {
                                    if !text.hasPrefix("[Request interrupted by user") {
                                        lastMessage = text
                                        lastMessageRole = type
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // The first content-bearing user/assistant line we hit while
            // walking backwards IS the last real conversational turn. Stamp
            // its timestamp as lastActivityDate (drives the status-color fade
            // — see ConversationInfo.lastActivityDate for why mtime is wrong).
            if lastActivityDate == nil, lastMessage != nil,
               let timestampStr = json["timestamp"] as? String {
                lastActivityDate = formatter.date(from: timestampStr)
            }

            if !foundLastUserMessage && type == "user" {
                let isMeta = json["isMeta"] as? Bool ?? false
                if !isMeta, let message = json["message"] as? [String: Any] {
                    if let msgContent = message["content"] as? String {
                        if !msgContent.hasPrefix("<command-name>") && !msgContent.hasPrefix("<local-command") && !msgContent.hasPrefix("Caveat:") {
                            if let timestampStr = json["timestamp"] as? String {
                                lastUserMessageDate = formatter.date(from: timestampStr)
                            }
                            foundLastUserMessage = true
                        }
                    }
                }
            }

            if summary == nil, type == "summary", let summaryText = json["summary"] as? String {
                summary = summaryText
            }

            if summary != nil && lastMessage != nil && foundLastUserMessage
                && lastModelName != nil && lastPermissionMode != nil {
                break
            }
        }

        // Surface Zed's user-set thread title — claude-acp writes
        // `{"type":"custom-title",...}` rows into the JSONL alongside
        // the regular CLI transcript. See [[ClaudeCustomTitleExtractor]].
        let customTitle = ClaudeCustomTitleExtractor.extractTitle(jsonl: content)

        return ConversationInfo(
            summary: summary,
            lastMessage: Self.truncateMessage(lastMessage, maxLength: 80),
            lastMessageRole: lastMessageRole,
            lastToolName: lastToolName,
            firstUserMessage: firstUserMessage,
            lastUserMessageDate: lastUserMessageDate,
            lastActivityDate: lastActivityDate,
            lastCwd: lastCwd,
            customTitle: customTitle,
            lastModelName: lastModelName,
            lastContextTokens: lastContextTokens,
            lastPermissionMode: lastPermissionMode
        )
    }

    /// Format tool input for display in instance list.
    private static func formatToolInput(_ input: [String: Any]?, toolName: String) -> String {
        guard let input = input else { return "" }

        switch toolName {
        case "Read", "Write", "Edit":
            if let filePath = input["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
        case "Bash":
            if let command = input["command"] as? String {
                return command
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Task":
            if let description = input["description"] as? String {
                return description
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return url
            }
        case "WebSearch":
            if let query = input["query"] as? String {
                return query
            }
        default:
            for (_, value) in input {
                if let str = value as? String, !str.isEmpty {
                    return str
                }
            }
        }
        return ""
    }

    /// Truncate message for display.
    private static func truncateMessage(_ message: String?, maxLength: Int = 80) -> String? {
        guard let msg = message else { return nil }
        let cleaned = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.count > maxLength {
            return String(cleaned.prefix(maxLength - 3)) + "..."
        }
        return cleaned
    }
}
