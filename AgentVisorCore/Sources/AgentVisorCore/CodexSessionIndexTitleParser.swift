import Foundation

public enum CodexSessionIndexTitleParser {
    public static func titlesByThreadId(from jsonl: String) -> [String: String] {
        var titles: [String: String] = [:]
        for line in jsonl.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let row = try? JSONDecoder().decode(Row.self, from: data),
                  !row.id.isEmpty,
                  !row.threadName.isEmpty else {
                continue
            }
            titles[row.id] = row.threadName
        }
        return titles
    }

    private struct Row: Decodable {
        let id: String
        let threadName: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }
}
