import Foundation

public enum SessionActivityMarkdownNormalizer {
    private static let absoluteFileLink = try! NSRegularExpression(
        pattern: #"\]\((/[^)\r\n]+)\)"#
    )

    public static func normalize(_ source: String) -> String {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = absoluteFileLink.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return source }

        let original = source as NSString
        var normalized = source
        for match in matches.reversed() {
            let pathRange = match.range(at: 1)
            let path = original.substring(with: pathRange)
            guard let replacementRange = Range(pathRange, in: normalized) else { continue }
            normalized.replaceSubrange(
                replacementRange,
                with: URL(fileURLWithPath: path).absoluteString
            )
        }
        return normalized
    }
}
