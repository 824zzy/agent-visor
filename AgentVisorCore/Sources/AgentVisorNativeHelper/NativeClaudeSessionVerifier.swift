import AgentVisorCore
import Darwin
import Foundation

/// Current frontend identity from Claude's own per-process record. A parked
/// host does not identify the conversation it used to display. No TUI text,
/// terminal input, or process argument matching is used here.
public struct NativeClaudeSessionVerifier {
    private let homeDirectory: URL
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func verify(_ target: NativeHelperTerminalTarget) -> Bool {
        guard target.application == .ghostty, let pid = target.pid, pid > 0,
              let sessionId = target.claudeSessionId, let expected = UUID(uuidString: sessionId),
              let token = target.processStartToken else { return false }
        let parts = token.split(separator: ":")
        guard parts.count == 4, parts[0] == "v1", parts[1] == String(pid),
              let startMillis = Int64(parts[2]), startMillis >= 0,
              TerminalProcessIdentityToken.make(pid: Int(pid),
                startTime: Date(timeIntervalSince1970: TimeInterval(startMillis) / 1_000)) == token else { return false }
        let file = homeDirectory.appendingPathComponent(".claude/sessions/\(pid).json")
        guard let input = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? input.close() }
        // Check the opened file, not a second path lookup: a stale record from
        // an earlier process must not authenticate a reused PID.
        var info = stat()
        guard fstat(input.fileDescriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              Int64(info.st_mtimespec.tv_sec) * 1_000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000 >= startMillis else { return false }
        guard let data = try? input.read(upToCount: 256 * 1_024 + 1), data.count <= 256 * 1_024,
              let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let currentId = metadata["sessionId"] as? String, UUID(uuidString: currentId) == expected,
              metadata["cwd"] as? String == target.cwd,
              metadata["kind"] as? String == "interactive",
              metadata["parkedJobId"] == nil, metadata["spare"] as? Bool != true else { return false }
        let status = (metadata["status"] as? String ?? "").lowercased()
        let terminal = ["ended", "exited", "closed", "deactivated", "inactive", "stopped", "terminated"]
        return !terminal.contains(status)
            && !(metadata["entrypoint"] as? String ?? "").lowercased().hasPrefix("sdk")
    }
}
