//
//  ToolResultData.swift
//  AgentVisor
//
//  Structured models for all Claude Code tool results
//

import Foundation

// MARK: - Tool Result Wrapper

/// Structured tool result data - parsed from JSONL tool_result blocks
public enum ToolResultData: Equatable, Sendable, Codable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case askUserQuestion(AskUserQuestionResult)
    case bashOutput(BashOutputResult)
    case killShell(KillShellResult)
    case exitPlanMode(ExitPlanModeResult)
    case mcp(MCPResult)
    case generic(GenericResult)
}

// MARK: - Read Tool Result

public struct ReadResult: Equatable, Sendable, Codable {

    public init(
        filePath: String,
        content: String,
        numLines: Int,
        startLine: Int,
        totalLines: Int
    ) {
        self.filePath = filePath
        self.content = content
        self.numLines = numLines
        self.startLine = startLine
        self.totalLines = totalLines
    }
    public let filePath: String
    public let content: String
    public let numLines: Int
    public let startLine: Int
    public let totalLines: Int

    public var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Edit Tool Result

public struct EditResult: Equatable, Sendable, Codable {

    public init(
        filePath: String,
        oldString: String,
        newString: String,
        replaceAll: Bool,
        userModified: Bool,
        structuredPatch: [PatchHunk]? = nil
    ) {
        self.filePath = filePath
        self.oldString = oldString
        self.newString = newString
        self.replaceAll = replaceAll
        self.userModified = userModified
        self.structuredPatch = structuredPatch
    }
    public let filePath: String
    public let oldString: String
    public let newString: String
    public let replaceAll: Bool
    public let userModified: Bool
    public let structuredPatch: [PatchHunk]?

    public var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

public struct PatchHunk: Equatable, Sendable, Codable {

    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        lines: [String]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [String]
}

// MARK: - Write Tool Result

public struct WriteResult: Equatable, Sendable, Codable {

    public init(
        type: WriteType,
        filePath: String,
        content: String,
        structuredPatch: [PatchHunk]? = nil
    ) {
        self.type = type
        self.filePath = filePath
        self.content = content
        self.structuredPatch = structuredPatch
    }
    public enum WriteType: String, Equatable, Sendable, Codable {
        case create
        case overwrite
    }

    public let type: WriteType
    public let filePath: String
    public let content: String
    public let structuredPatch: [PatchHunk]?

    public var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - Bash Tool Result

public struct BashResult: Equatable, Sendable, Codable {

    public init(
        stdout: String,
        stderr: String,
        interrupted: Bool,
        isImage: Bool,
        returnCodeInterpretation: String? = nil,
        backgroundTaskId: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.interrupted = interrupted
        self.isImage = isImage
        self.returnCodeInterpretation = returnCodeInterpretation
        self.backgroundTaskId = backgroundTaskId
    }
    public let stdout: String
    public let stderr: String
    public let interrupted: Bool
    public let isImage: Bool
    public let returnCodeInterpretation: String?
    public let backgroundTaskId: String?

    public var hasOutput: Bool {
        !stdout.isEmpty || !stderr.isEmpty
    }

    public var displayOutput: String {
        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return "(No content)"
    }
}

// MARK: - Grep Tool Result

public struct GrepResult: Equatable, Sendable, Codable {

    public init(
        mode: Mode,
        filenames: [String],
        numFiles: Int,
        content: String? = nil,
        numLines: Int? = nil,
        appliedLimit: Int? = nil
    ) {
        self.mode = mode
        self.filenames = filenames
        self.numFiles = numFiles
        self.content = content
        self.numLines = numLines
        self.appliedLimit = appliedLimit
    }
    public enum Mode: String, Equatable, Sendable, Codable {
        case filesWithMatches = "files_with_matches"
        case content
        case count
    }

    public let mode: Mode
    public let filenames: [String]
    public let numFiles: Int
    public let content: String?
    public let numLines: Int?
    public let appliedLimit: Int?
}

// MARK: - Glob Tool Result

public struct GlobResult: Equatable, Sendable, Codable {

    public init(
        filenames: [String],
        durationMs: Int,
        numFiles: Int,
        truncated: Bool
    ) {
        self.filenames = filenames
        self.durationMs = durationMs
        self.numFiles = numFiles
        self.truncated = truncated
    }
    public let filenames: [String]
    public let durationMs: Int
    public let numFiles: Int
    public let truncated: Bool
}

// MARK: - TodoWrite Tool Result

public struct TodoWriteResult: Equatable, Sendable, Codable {

    public init(
        oldTodos: [TodoItem],
        newTodos: [TodoItem]
    ) {
        self.oldTodos = oldTodos
        self.newTodos = newTodos
    }
    public let oldTodos: [TodoItem]
    public let newTodos: [TodoItem]
}

public struct TodoItem: Equatable, Sendable, Codable {

    public init(
        content: String,
        status: String,
        activeForm: String? = nil
    ) {
        self.content = content
        self.status = status
        self.activeForm = activeForm
    }
    public let content: String
    public let status: String // "pending", "in_progress", "completed"
    public let activeForm: String?
}

// MARK: - Task (Agent) Tool Result

public struct TaskResult: Equatable, Sendable, Codable {

    public init(
        agentId: String,
        status: String,
        content: String,
        prompt: String? = nil,
        totalDurationMs: Int? = nil,
        totalTokens: Int? = nil,
        totalToolUseCount: Int? = nil
    ) {
        self.agentId = agentId
        self.status = status
        self.content = content
        self.prompt = prompt
        self.totalDurationMs = totalDurationMs
        self.totalTokens = totalTokens
        self.totalToolUseCount = totalToolUseCount
    }
    public let agentId: String
    public let status: String
    public let content: String
    public let prompt: String?
    public let totalDurationMs: Int?
    public let totalTokens: Int?
    public let totalToolUseCount: Int?
}

// MARK: - WebFetch Tool Result

public struct WebFetchResult: Equatable, Sendable, Codable {

    public init(
        url: String,
        code: Int,
        codeText: String,
        bytes: Int,
        durationMs: Int,
        result: String
    ) {
        self.url = url
        self.code = code
        self.codeText = codeText
        self.bytes = bytes
        self.durationMs = durationMs
        self.result = result
    }
    public let url: String
    public let code: Int
    public let codeText: String
    public let bytes: Int
    public let durationMs: Int
    public let result: String
}

// MARK: - WebSearch Tool Result

public struct WebSearchResult: Equatable, Sendable, Codable {

    public init(
        query: String,
        durationSeconds: Double,
        results: [SearchResultItem]
    ) {
        self.query = query
        self.durationSeconds = durationSeconds
        self.results = results
    }
    public let query: String
    public let durationSeconds: Double
    public let results: [SearchResultItem]
}

public struct SearchResultItem: Equatable, Sendable, Codable {

    public init(
        title: String,
        url: String,
        snippet: String
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
    public let title: String
    public let url: String
    public let snippet: String
}

// MARK: - AskUserQuestion Tool Result

public struct AskUserQuestionResult: Equatable, Sendable, Codable {

    public init(
        questions: [QuestionItem],
        answers: [String: String]
    ) {
        self.questions = questions
        self.answers = answers
    }
    public let questions: [QuestionItem]
    public let answers: [String: String]
}

public struct QuestionItem: Equatable, Sendable, Codable {

    public init(
        question: String,
        header: String? = nil,
        options: [QuestionOption]
    ) {
        self.question = question
        self.header = header
        self.options = options
    }
    public let question: String
    public let header: String?
    public let options: [QuestionOption]
}

public struct QuestionOption: Equatable, Sendable, Codable {

    public init(
        label: String,
        description: String? = nil
    ) {
        self.label = label
        self.description = description
    }
    public let label: String
    public let description: String?
}

// MARK: - BashOutput Tool Result

public struct BashOutputResult: Equatable, Sendable, Codable {

    public init(
        shellId: String,
        status: String,
        stdout: String,
        stderr: String,
        stdoutLines: Int,
        stderrLines: Int,
        exitCode: Int? = nil,
        command: String? = nil,
        timestamp: String? = nil
    ) {
        self.shellId = shellId
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutLines = stdoutLines
        self.stderrLines = stderrLines
        self.exitCode = exitCode
        self.command = command
        self.timestamp = timestamp
    }
    public let shellId: String
    public let status: String
    public let stdout: String
    public let stderr: String
    public let stdoutLines: Int
    public let stderrLines: Int
    public let exitCode: Int?
    public let command: String?
    public let timestamp: String?
}

// MARK: - KillShell Tool Result

public struct KillShellResult: Equatable, Sendable, Codable {

    public init(
        shellId: String,
        message: String
    ) {
        self.shellId = shellId
        self.message = message
    }
    public let shellId: String
    public let message: String
}

// MARK: - ExitPlanMode Tool Result

public struct ExitPlanModeResult: Equatable, Sendable, Codable {

    public init(
        filePath: String? = nil,
        plan: String? = nil,
        isAgent: Bool
    ) {
        self.filePath = filePath
        self.plan = plan
        self.isAgent = isAgent
    }
    public let filePath: String?
    public let plan: String?
    public let isAgent: Bool
}

// MARK: - MCP Tool Result (Generic)

public nonisolated struct MCPResult: Equatable, @unchecked Sendable, Codable {
    public let serverName: String
    public let toolName: String
    public let rawResult: [String: Any]

    public nonisolated init(serverName: String, toolName: String, rawResult: [String: Any]) {
        self.serverName = serverName
        self.toolName = toolName
        self.rawResult = rawResult
    }

    public static func == (lhs: MCPResult, rhs: MCPResult) -> Bool {
        lhs.serverName == rhs.serverName &&
        lhs.toolName == rhs.toolName &&
        NSDictionary(dictionary: lhs.rawResult).isEqual(to: rhs.rawResult)
    }

    // Custom Codable: `rawResult` is `[String: Any]` which Swift can't
    // synthesize Codable for. Persist it as a JSON string instead.
    private enum CodingKeys: String, CodingKey {
        case serverName, toolName, rawResultJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try container.decode(String.self, forKey: .serverName)
        toolName = try container.decode(String.self, forKey: .toolName)
        let json = try container.decode(String.self, forKey: .rawResultJSON)
        let data = json.data(using: .utf8) ?? Data()
        rawResult = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(toolName, forKey: .toolName)
        let data = (try? JSONSerialization.data(withJSONObject: rawResult)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try container.encode(json, forKey: .rawResultJSON)
    }
}

// MARK: - Generic Tool Result (Fallback)

public nonisolated struct GenericResult: Equatable, @unchecked Sendable, Codable {
    public let rawContent: String?
    public let rawData: [String: Any]?

    public nonisolated init(rawContent: String?, rawData: [String: Any]?) {
        self.rawContent = rawContent
        self.rawData = rawData
    }

    public static func == (lhs: GenericResult, rhs: GenericResult) -> Bool {
        lhs.rawContent == rhs.rawContent
    }

    private enum CodingKeys: String, CodingKey {
        case rawContent, rawDataJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawContent = try container.decodeIfPresent(String.self, forKey: .rawContent)
        if let json = try container.decodeIfPresent(String.self, forKey: .rawDataJSON) {
            let data = json.data(using: .utf8) ?? Data()
            rawData = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        } else {
            rawData = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rawContent, forKey: .rawContent)
        if let dict = rawData,
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            try container.encode(json, forKey: .rawDataJSON)
        }
    }
}

// MARK: - Tool Status Display

public struct ToolStatusDisplay {

    public init(
        text: String,
        isRunning: Bool
    ) {
        self.text = text
        self.isRunning = isRunning
    }
    public let text: String
    public let isRunning: Bool

    /// Get running status text for a tool
    public static func running(for toolName: String, input: [String: String]) -> ToolStatusDisplay {
        switch toolName {
        case "Read":
            return ToolStatusDisplay(text: "Reading...", isRunning: true)
        case "Edit":
            return ToolStatusDisplay(text: "Editing...", isRunning: true)
        case "Write":
            return ToolStatusDisplay(text: "Writing...", isRunning: true)
        case "Bash":
            if let desc = input["description"], !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            return ToolStatusDisplay(text: "Running...", isRunning: true)
        case "Grep", "Glob":
            if let pattern = input["pattern"] {
                return ToolStatusDisplay(text: "Searching: \(pattern)", isRunning: true)
            }
            return ToolStatusDisplay(text: "Searching...", isRunning: true)
        case "WebSearch":
            if let query = input["query"] {
                return ToolStatusDisplay(text: "Searching: \(query)", isRunning: true)
            }
            return ToolStatusDisplay(text: "Searching...", isRunning: true)
        case "WebFetch":
            return ToolStatusDisplay(text: "Fetching...", isRunning: true)
        case "Task":
            if let desc = input["description"], !desc.isEmpty {
                return ToolStatusDisplay(text: desc, isRunning: true)
            }
            return ToolStatusDisplay(text: "Running agent...", isRunning: true)
        case "TodoWrite":
            return ToolStatusDisplay(text: "Updating todos...", isRunning: true)
        case "EnterPlanMode":
            return ToolStatusDisplay(text: "Entering plan mode...", isRunning: true)
        case "ExitPlanMode":
            return ToolStatusDisplay(text: "Exiting plan mode...", isRunning: true)
        default:
            return ToolStatusDisplay(text: "Running...", isRunning: true)
        }
    }

    /// Get completed status text for a tool result
    public static func completed(for toolName: String, result: ToolResultData?) -> ToolStatusDisplay {
        guard let result = result else {
            return ToolStatusDisplay(text: "Completed", isRunning: false)
        }

        switch result {
        case .read(let r):
            let lineText = r.totalLines > r.numLines ? "\(r.numLines)+ lines" : "\(r.numLines) lines"
            return ToolStatusDisplay(text: "Read \(r.filename) (\(lineText))", isRunning: false)

        case .edit(let r):
            return ToolStatusDisplay(text: "Edited \(r.filename)", isRunning: false)

        case .write(let r):
            let action = r.type == .create ? "Created" : "Wrote"
            return ToolStatusDisplay(text: "\(action) \(r.filename)", isRunning: false)

        case .bash(let r):
            if let bgId = r.backgroundTaskId {
                return ToolStatusDisplay(text: "Running in background (\(bgId))", isRunning: false)
            }
            if let interpretation = r.returnCodeInterpretation {
                return ToolStatusDisplay(text: interpretation, isRunning: false)
            }
            return ToolStatusDisplay(text: "Completed", isRunning: false)

        case .grep(let r):
            let fileWord = r.numFiles == 1 ? "file" : "files"
            return ToolStatusDisplay(text: "Found \(r.numFiles) \(fileWord)", isRunning: false)

        case .glob(let r):
            let fileWord = r.numFiles == 1 ? "file" : "files"
            if r.numFiles == 0 {
                return ToolStatusDisplay(text: "No files found", isRunning: false)
            }
            return ToolStatusDisplay(text: "Found \(r.numFiles) \(fileWord)", isRunning: false)

        case .todoWrite:
            return ToolStatusDisplay(text: "Updated todos", isRunning: false)

        case .task(let r):
            return ToolStatusDisplay(text: r.status.capitalized, isRunning: false)

        case .webFetch(let r):
            return ToolStatusDisplay(text: "\(r.code) \(r.codeText)", isRunning: false)

        case .webSearch(let r):
            let time = r.durationSeconds >= 1 ?
                "\(Int(r.durationSeconds))s" :
                "\(Int(r.durationSeconds * 1000))ms"
            let searchWord = r.results.count == 1 ? "search" : "searches"
            return ToolStatusDisplay(text: "Did 1 \(searchWord) in \(time)", isRunning: false)

        case .askUserQuestion:
            return ToolStatusDisplay(text: "Answered", isRunning: false)

        case .bashOutput(let r):
            return ToolStatusDisplay(text: "Status: \(r.status)", isRunning: false)

        case .killShell:
            return ToolStatusDisplay(text: "Terminated", isRunning: false)

        case .exitPlanMode:
            return ToolStatusDisplay(text: "Plan ready", isRunning: false)

        case .mcp:
            return ToolStatusDisplay(text: "Completed", isRunning: false)

        case .generic:
            return ToolStatusDisplay(text: "Completed", isRunning: false)
        }
    }
}
