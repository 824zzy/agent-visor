import Foundation

/// Inverse of `CursorProjectKeyEncoder`: turns a directory name under
/// `~/.cursor/projects/<key>/` back into the absolute CWD it was
/// generated from.
///
/// The encoding is lossy in the general case — `/` and `-` collide, and
/// leading dots on hidden-directory segments are dropped. The decoder
/// resolves the ambiguity by probing the filesystem: it generates
/// candidate paths and returns the first one that actually exists. If
/// none exist, it falls back to the naive decode so the rest of the
/// app still has a CWD to display in chat history.
///
/// The filesystem-existence check is injected so the decoder is
/// unit-testable without touching real disks.
public enum CursorProjectKeyDecoder {
    /// Special sentinel the encoder writes for `/` or empty cwd. We
    /// can't recover the original cwd from the sentinel; `/` is
    /// always a valid directory and is the safest default.
    private static let emptyWindowKey = "empty-window"

    /// - Parameters:
    ///   - projectKey: The directory name under `~/.cursor/projects/`.
    ///   - directoryExists: Closure returning whether the given path
    ///     resolves to a real directory. Inject `FileManager.default`'s
    ///     `fileExists(atPath:isDirectory:)` in production; supply a
    ///     dictionary lookup in tests.
    /// - Returns: The most likely original CWD. Always returns a value;
    ///   when no candidate exists on disk, returns the naive decode.
    public static func decode(
        projectKey: String,
        directoryExists: (String) -> Bool
    ) -> String {
        if projectKey == emptyWindowKey { return "/" }
        let segments = projectKey.split(separator: "-").map(String.init)
        guard !segments.isEmpty else { return "/" }

        let naive = "/" + segments.joined(separator: "/")

        // Enumerate candidates by:
        //   1. choosing which adjacent dash-pairs to MERGE (i.e. treat
        //      the "-" as a literal hyphen rather than a separator), and
        //   2. choosing at most one segment to dot-prefix (hidden dir).
        // The total enumeration is bounded at
        //   2^(n-1) merge masks × (n+1) dot positions  for n = segments.count.
        // For typical 3-6 segment workspaces that's well under a hundred
        // probes; we early-return on the first hit so the cost stays low.
        //
        // Search order matters: the naive (no-merge, no-dot) candidate
        // wins by going first, then merge variants, then dot variants.
        // This biases toward "common" decodings before reaching for the
        // edge cases.
        let n = segments.count
        let mergeMaskCount = n > 1 ? 1 << (n - 1) : 1

        // Pass 1: no dot, every merge mask (mask 0 = no merges = naive).
        for mask in 0..<mergeMaskCount {
            let merged = applyMergeMask(segments, mask: mask)
            let candidate = "/" + merged.joined(separator: "/")
            if directoryExists(candidate) { return candidate }
        }

        // Pass 2: one segment dot-prefixed, every merge mask.
        for mask in 0..<mergeMaskCount {
            let merged = applyMergeMask(segments, mask: mask)
            for dotIdx in 0..<merged.count {
                var withDot = merged
                withDot[dotIdx] = "." + withDot[dotIdx]
                let candidate = "/" + withDot.joined(separator: "/")
                if directoryExists(candidate) { return candidate }
            }
        }

        // No candidate exists. Fall back to naive — the chat-history
        // path can still load (transcripts live under `~/.cursor/projects/`,
        // not under cwd), and `bestProjectName` still produces a usable
        // sidebar label.
        return naive
    }

    /// Apply a merge bitmask to the segments. Bit `i` set means "merge
    /// the gap between segment i and i+1 into a literal '-' rather
    /// than a path separator". For example with segments
    /// `[A, B, C, D]` and mask `0b010` (bit 1 set), the result is
    /// `[A, B-C, D]`.
    private static func applyMergeMask(_ segments: [String], mask: Int) -> [String] {
        var out: [String] = []
        var current = segments[0]
        for i in 1..<segments.count {
            let gapBit = i - 1
            if (mask >> gapBit) & 1 == 1 {
                current += "-" + segments[i]
            } else {
                out.append(current)
                current = segments[i]
            }
        }
        out.append(current)
        return out
    }
}
