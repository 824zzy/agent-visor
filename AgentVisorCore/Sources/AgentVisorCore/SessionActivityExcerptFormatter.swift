import Foundation

public enum SessionActivityExcerptFormatter {
    public static func singleLine(_ source: String) -> String {
        plainText(source)
            .split(separator: "\n")
            .map { line in
                line.hasPrefix("• ") ? String(line.dropFirst(2)) : String(line)
            }
            .joined(separator: " · ")
    }

    public static func plainText(_ source: String) -> String {
        String(attributedText(source).characters)
    }

    public static func attributedText(_ source: String) -> AttributedString {
        let prepared = unwrapEmbeddedMarkdownFences(unwrapOuterMarkdownFence(source))
        let normalized = SessionActivityMarkdownNormalizer.normalize(prepared)
        guard let attributed = try? AttributedString(markdown: normalized) else {
            return AttributedString(prepared.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var result = AttributedString()
        var previousBlockIdentity: Int?

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let blockIdentity = components.first?.identity
            if blockIdentity != previousBlockIdentity {
                if !result.characters.isEmpty { result.append(AttributedString("\n")) }
                result.append(AttributedString(listPrefix(for: components)))
                previousBlockIdentity = blockIdentity
            }
            result.append(AttributedString(attributed[run.range]))
        }

        return result
    }

    private static func unwrapOuterMarkdownFence(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
              lines[0].hasPrefix("```"),
              lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else {
            return source
        }
        let language = lines[0]
            .dropFirst(3)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard language.isEmpty || language == "markdown" || language == "md" || language == "text" else {
            return source
        }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func unwrapEmbeddedMarkdownFences(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard isMarkdownDocumentFence(String(line)) else {
                result.append(String(line))
                index += 1
                continue
            }

            let closingIndex = ((index + 1)..<lines.count).first {
                lines[$0].trimmingCharacters(in: .whitespaces) == "```"
            }
            guard let closingIndex else {
                result.append(String(line))
                index += 1
                continue
            }

            result.append(contentsOf: lines[(index + 1)..<closingIndex].map(String.init))
            index = closingIndex + 1
        }

        return result.joined(separator: "\n")
    }

    private static func isMarkdownDocumentFence(_ line: String) -> Bool {
        let language = line
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return language == "```markdown" || language == "```md" || language == "```text"
    }

    private static func listPrefix(
        for components: [PresentationIntent.IntentType]
    ) -> String {
        var ordinal: Int?
        var ordered = false
        for component in components {
            switch component.kind {
            case .listItem(let value): ordinal = value
            case .orderedList: ordered = true
            default: break
            }
        }
        guard let ordinal else { return "" }
        return ordered ? "\(ordinal). " : "• "
    }
}
