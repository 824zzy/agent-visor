import Foundation

/// Mirrors Pi's native clipboard-image convention: image files remain local
/// and their paths become ordered prompt text submitted in one operation.
public enum PiImagePromptComposer {
    public static func compose(
        text: String,
        imagePaths: [String]
    ) -> String? {
        var components = imagePaths.compactMap { path -> String? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            components.append(trimmedText)
        }

        guard !components.isEmpty else { return nil }
        return components.joined(separator: " ")
    }
}
