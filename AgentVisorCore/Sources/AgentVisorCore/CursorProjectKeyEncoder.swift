import Foundation

/// Encodes a CWD into the directory key Cursor uses under
/// `~/.cursor/projects/<key>/agent-transcripts/`. Mirrors what
/// cursor-agent does internally so we can locate transcripts
/// deterministically.
///
/// Algorithm (verified empirically against on-disk projects/):
///   `/Users/example/Codes` → `Users-example-Codes`
///   `/Users/x/Personal/agent-visor` → `Users-x-Personal-agent-visor`
///   `/` or "" → `empty-window`
///
/// Lives in Core (not the app target) so the encoder is unit-testable
/// and the `CursorAgentProvider` keeps zero project-key logic of its
/// own — when Cursor changes the encoding scheme (which they have done
/// once already), only the encoder + tests need to move.
public enum CursorProjectKeyEncoder {
    public static func projectKey(forCwd cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "empty-window" }
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }
}
