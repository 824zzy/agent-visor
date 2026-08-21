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
            guard !linePrefix.isEmpty else { return }
            // A retained prefix can end inside a multibyte value in discarded
            // message content. Replacement decoding keeps the valid top-level
            // id and parent fields at the start of the line.
            let text = String(decoding: linePrefix, as: UTF8.self)
            guard let type = stringField("type", in: text),
                  type != "session" else { return }
            // Pi writes custom data before the record identity. Search backward
            // so a nested goal ID cannot replace the top-level record ID.
            // ponytail: retain a line tail if custom data grows beyond 64 KiB.
            let identityOptions: String.CompareOptions = type == "custom" ? .backwards : []
            guard let id = stringField("id", in: text, options: identityOptions) else { return }

            if let parentID = stringField("parentId", in: text, options: identityOptions) {
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

    /// Pi writes message identity before content and custom identity after data.
    /// Values here cannot contain escaped quotes.
    private static func stringField(
        _ key: String,
        in text: String,
        options: String.CompareOptions = []
    ) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"", options: options) else { return nil }
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
