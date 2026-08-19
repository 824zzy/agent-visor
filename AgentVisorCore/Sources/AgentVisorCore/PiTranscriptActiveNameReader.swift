import Foundation

/// Reads only the record links and session names needed to recover Pi's name.
///
/// A bounded head-and-tail conversation summary can omit the records connecting
/// an early `session_info` rename to the active tail. Parsing the whole transcript
/// would recover the name, but large tool output makes that too expensive during
/// discovery. This reader scans the file once, retains only a short prefix of each
/// line, and indexes `id -> parentId`. Memory therefore follows the record count,
/// not transcript size.
public enum PiTranscriptActiveNameReader {
    private static let chunkBytes = 256 * 1024
    private static let linePrefixBytes = 64 * 1024

    public static func read(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        var parents: [String: String] = [:]
        var names: [String: String] = [:]
        var lastEntryID: String?
        var linePrefix = Data()

        func appendPrefix(_ bytes: Data.SubSequence) {
            let remaining = linePrefixBytes - linePrefix.count
            guard remaining > 0 else { return }
            linePrefix.append(contentsOf: bytes.prefix(remaining))
        }

        func acceptLine() {
            defer { linePrefix.removeAll(keepingCapacity: true) }
            guard !linePrefix.isEmpty,
                  let text = String(data: linePrefix, encoding: .utf8),
                  let type = stringField("type", in: text),
                  type != "session",
                  let id = stringField("id", in: text) else { return }

            if let parentID = stringField("parentId", in: text) {
                parents[id] = parentID
            }
            if type == "session_info",
               let object = try? JSONSerialization.jsonObject(with: linePrefix) as? [String: Any],
               let name = object["name"] as? String,
               !name.isEmpty {
                names[id] = name
            }
            lastEntryID = id
        }

        while let chunk = try? handle.read(upToCount: chunkBytes),
              !chunk.isEmpty {
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let remaining = chunk[cursor...]
                guard let newline = remaining.firstIndex(of: 0x0A) else {
                    appendPrefix(remaining)
                    break
                }
                appendPrefix(chunk[cursor..<newline])
                acceptLine()
                cursor = chunk.index(after: newline)
            }
        }
        if !linePrefix.isEmpty {
            acceptLine()
        }

        var current = lastEntryID
        var visited: Set<String> = []
        while let id = current, visited.insert(id).inserted {
            if let name = names[id] { return name }
            current = parents[id]
        }
        return nil
    }

    /// Pi writes these top-level fields before message content. Values are UUIDs
    /// or fixed record names, so escaped strings are not valid at this boundary.
    private static func stringField(_ key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == ":" else { return nil }
        index = text.index(after: index)
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        let start = text.index(after: index)
        guard let end = text[start...].firstIndex(of: "\"") else { return nil }
        return String(text[start..<end])
    }
}
