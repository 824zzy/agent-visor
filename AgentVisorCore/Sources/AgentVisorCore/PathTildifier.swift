import Foundation

/// Replace the home directory prefix with `~` in display paths,
/// matching the notch's chat status bar tildification. Pure
/// function on the input strings so it stays unit-testable
/// independent of the runtime user's home dir.
public enum PathTildifier {
    public static func tildify(_ path: String, homeDirectory: String) -> String {
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") {
            return "~" + path.dropFirst(homeDirectory.count)
        }
        return path
    }
}
