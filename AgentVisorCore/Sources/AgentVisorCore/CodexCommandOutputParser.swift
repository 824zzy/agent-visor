import Foundation

/// A Codex shell/tool output with its envelope stripped.
///
/// Codex wraps `exec_command` / `write_stdin` (and MCP) outputs in a small
/// header envelope:
///
///     Chunk ID: 5e0f6a
///     Wall time: 0.0000 seconds
///     Process exited with code 0           (or: Process running with session ID 6233)
///     Original token count: 10
///     Output:
///     <the real output…>
///
/// We surface only the real output plus the process status so the chat can
/// render a clean terminal block instead of the raw envelope noise.
public struct CodexCommandOutput: Equatable, Sendable {
    public var text: String
    public var exitCode: Int?
    public var sessionID: Int?
    public var isRunning: Bool

    public init(text: String, exitCode: Int? = nil, sessionID: Int? = nil, isRunning: Bool = false) {
        self.text = text
        self.exitCode = exitCode
        self.sessionID = sessionID
        self.isRunning = isRunning
    }
}

public enum CodexCommandOutputParser {
    public static func parse(_ raw: String) -> CodexCommandOutput {
        let (header, payload) = splitEnvelope(raw)

        let exitCode = header.flatMap { firstInt(in: $0, pattern: "exited with code ([0-9]+)") }
        let sessionID = header.flatMap { firstInt(in: $0, pattern: "session ID ([0-9]+)") }
        // A live PTY session reports its id and has not exited yet. Once it
        // exits, the (later) poll output carries an exit code instead.
        let isRunning = sessionID != nil && exitCode == nil

        let unwrapped = unwrapContentBlocks(payload) ?? payload
        let cleaned = stripANSI(unwrapped).trimmingCharacters(in: .whitespacesAndNewlines)

        return CodexCommandOutput(
            text: cleaned,
            exitCode: exitCode,
            sessionID: sessionID,
            isRunning: isRunning
        )
    }

    /// Split on the first standalone `Output:` line. Everything before is the
    /// header (status fields); everything after is the real payload. A later
    /// `Output:` embedded in the body is left intact. When there is no
    /// envelope, the whole string is the payload.
    private static func splitEnvelope(_ raw: String) -> (header: String?, payload: String) {
        let lines = raw.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0 == "Output:" }) else {
            return (nil, raw)
        }
        let header = lines[..<idx].joined(separator: "\n")
        let payload = lines[(idx + 1)...].joined(separator: "\n")
        return (header, payload)
    }

    /// Unwrap an MCP content-block array (`[{"type":"text","text":"…"}]`) to
    /// its joined text. Returns nil when the payload isn't such an array — e.g.
    /// a raw JSON data array like `[{"sha":…}]` is left untouched so we don't
    /// blank out a real result.
    private static func unwrapContentBlocks(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let textTypes: Set<String> = ["text", "input_text", "output_text"]
        let texts = array.compactMap { block -> String? in
            guard let type = block["type"] as? String, textTypes.contains(type),
                  let text = block["text"] as? String else {
                return nil
            }
            return text
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }

    private static func firstInt(in string: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: string) else {
            return nil
        }
        return Int(string[range])
    }

    private static func stripANSI(_ string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[a-zA-Z]") else {
            return string
        }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
    }
}
