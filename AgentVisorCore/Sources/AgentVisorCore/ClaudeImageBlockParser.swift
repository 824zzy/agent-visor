import Foundation

/// Parses the image forms Claude stores inside a user message content array.
/// The transcript record UUID remains the row identity; this value supplies
/// the stable image reference used by PendingEchoStore reconciliation.
public enum ClaudeImageBlockParser {
    public static func attachment(from block: [String: Any]) -> ChatImageAttachment? {
        guard block["type"] as? String == "image" else { return nil }

        if let source = block["source"] as? [String: Any] {
            let sourceType = (source["type"] as? String)?.lowercased()
            if let path = localPath(
                source["path"] as? String
                    ?? source["file_path"] as? String
                    ?? source["url"] as? String
            ) {
                return ChatImageAttachment(source: .localPath, value: path)
            }
            if sourceType == "base64",
               let data = source["data"] as? String,
               let mediaType = mediaType(
                   source["media_type"] as? String ?? source["mimeType"] as? String
               ) {
                return ChatImageAttachment(
                    source: .dataURI,
                    value: "data:\(mediaType);base64,\(data)"
                )
            }
            if sourceType == "url",
               let value = source["url"] as? String,
               value.hasPrefix("data:") {
                return ChatImageAttachment(source: .dataURI, value: value)
            }
        }

        if let path = localPath(
            block["path"] as? String
                ?? block["file_path"] as? String
                ?? block["url"] as? String
        ) {
            return ChatImageAttachment(source: .localPath, value: path)
        }
        if let data = block["data"] as? String,
           let mediaType = mediaType(
               block["media_type"] as? String ?? block["mimeType"] as? String
           ) {
            return ChatImageAttachment(
                source: .dataURI,
                value: "data:\(mediaType);base64,\(data)"
            )
        }
        return nil
    }

    /// Stable provider-visible identity for matching an optimistic image.
    /// Local paths remain paths; embedded images use their canonical data URI.
    public static func reference(from block: [String: Any]) -> String? {
        attachment(from: block)?.value
    }

    private static func mediaType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.hasPrefix("image/"), value.count <= 128 else { return nil }
        return value
    }

    private static func localPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            return url.path
        }
        guard value.hasPrefix("/") else { return nil }
        return value
    }
}
