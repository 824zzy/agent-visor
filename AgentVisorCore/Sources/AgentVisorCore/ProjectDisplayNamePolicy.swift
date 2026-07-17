import Foundation

public enum ProjectDisplayNamePolicy {
    public static func displayName(forRawProjectName name: String) -> String {
        switch name {
        case "agent-visor":
            return "agent-visor"
        default:
            return name
        }
    }

    public static func displayName(forCwd cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" { return nil }

        var normalized = trimmed
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        let last = (normalized as NSString).lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return displayName(forRawProjectName: last)
    }

    public static func displayPath(forCwd cwd: String, homeDirectory: String) -> String {
        replaceLastPathComponent(
            in: PathTildifier.tildify(cwd, homeDirectory: homeDirectory)
        )
    }

    public static func displayFolderName(forPath path: String) -> String {
        displayName(forRawProjectName: URL(fileURLWithPath: path).lastPathComponent)
    }

    private static func replaceLastPathComponent(in path: String) -> String {
        let hasTrailingSlash = path.count > 1 && path.hasSuffix("/")
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        let last = (normalized as NSString).lastPathComponent
        let display = displayName(forRawProjectName: last)
        guard display != last,
              let range = normalized.range(of: last, options: .backwards) else {
            return path
        }

        var replaced = normalized
        replaced.replaceSubrange(range, with: display)
        return hasTrailingSlash ? replaced + "/" : replaced
    }
}
