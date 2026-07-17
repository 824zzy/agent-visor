import Foundation

/// Detects whether a Bash command is a recognizable file-read invocation
/// and returns the absolute target path. Mirrors claude-code's
/// `PATH_EXTRACTORS` + `COMMAND_OPERATION_TYPE` table-driven approach
/// (`src/tools/BashTool/pathValidation.ts:118-589`).
///
/// Returning `nil` means "not a known read command" — callers should fall
/// back to a Bash command-prefix suggestion.
/// Result of classifying a Bash command as a file-read.
public struct BashReadTarget: Equatable, Sendable {
    /// Absolute path the command reads from.
    public let path: String
    /// Whether the path is known to be a directory (recursing commands
    /// like `find`, `grep -r`, `ls`, or any path the classifier emits
    /// because the command has no positional file arg). The builder
    /// uses this to decide whether the Read rule scopes to `path/**`
    /// directly or to `parent(path)/**`.
    public let isDirectory: Bool

    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum BashReadClassifier {
    public static func readTarget(
        command: String,
        cwd: String,
        homeDirectory: String
    ) -> BashReadTarget? {
        let tokens = command
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard let head = tokens.first else { return nil }
        let args = Array(tokens.dropFirst())

        if simpleReadCommands.contains(head) {
            let positional = args.filter { !$0.hasPrefix("-") }
            guard positional.count == 1 else { return nil }
            return BashReadTarget(
                path: absolutePath(positional[0], cwd: cwd, home: homeDirectory),
                isDirectory: false
            )
        }

        if directoryIteratingReadCommands.contains(head) {
            // Per-command argument shape:
            //   find [paths...] [-name X -type Y ...]    — path FIRST
            //   grep [flags] PATTERN [paths...]          — path LAST
            //   rg   [flags] PATTERN [paths...]          — path LAST
            //   ls   [flags] [path]                      — single path
            //
            // For multi-flag/argument forms `-name "package.json"` the
            // arg-to-flag must be skipped. Without a full Bash AST we
            // approximate: only count positionals that are NOT
            // immediately preceded by a `-` token (i.e. consumed as a
            // flag argument). For `find`, take the first remaining;
            // for the others, take the last.
            //
            // The recursing commands always scope to a directory. The
            // flag-arg-skipping behavior depends on the command's flag
            // model: `find -name X` consumes `X` as a flag argument,
            // but `grep -rn` is a combined short-flag with no arg.
            let positionals: [String]
            if head == "find" {
                positionals = positionalsSkippingFindFlagArgs(args)
            } else {
                positionals = args.filter { !$0.hasPrefix("-") }.map(stripSurroundingQuotes)
            }
            let pickedRaw: String
            switch (head, positionals.count) {
            case (_, 0):
                pickedRaw = cwd
            case ("find", _):
                pickedRaw = positionals[0]
            case ("ls", _):
                pickedRaw = positionals[0]
            case (_, 1):
                // grep "TODO" / rg "TODO" — single positional is a
                // pattern, no path. Reads stdin; cwd is a safe scope.
                pickedRaw = cwd
            default:
                pickedRaw = positionals.last!
            }
            let resolved = absolutePath(pickedRaw, cwd: cwd, home: homeDirectory)
            return BashReadTarget(path: resolved, isDirectory: true)
        }

        if head == "sed" {
            // sed is a read only when invoked with -n (print-only) and no
            // -i (in-place edit). Mirrors upstream's
            // `sedCommandIsAllowedByAllowlist` override at
            // pathValidation.ts:869-872.
            guard args.contains("-n") else { return nil }
            guard !args.contains(where: { $0 == "-i" || $0 == "--in-place" || $0.hasPrefix("-i") }) else { return nil }
            // Skip flags. The first remaining positional is the script,
            // the second is the file (PATH_EXTRACTORS:sed).
            let positional = args.filter { !$0.hasPrefix("-") }
            guard positional.count == 2 else { return nil }
            return BashReadTarget(
                path: absolutePath(positional[1], cwd: cwd, home: homeDirectory),
                isDirectory: false
            )
        }

        return nil
    }

    /// Read commands whose argument shape is "skip flags, take last positional
    /// as a file path". Mirrors the bulk of upstream's `PATH_EXTRACTORS`.
    private static let simpleReadCommands: Set<String> = [
        "cat", "head", "tail"
    ]

    /// Read commands that recurse over a directory (or default to cwd
    /// when no positional is given).
    private static let directoryIteratingReadCommands: Set<String> = [
        "ls", "grep", "rg", "find"
    ]

    /// Positional arguments for `find`. Most `find` flags take an arg
    /// (`-name PATTERN`, `-type f`, `-size +1M`); a few don't (`-print`,
    /// `-delete`, `-empty`, `-readable`). Without porting the full flag
    /// table, we conservatively skip the next token after each `-` flag.
    /// This mis-classifies args after `-print` (treats them as flag
    /// args) but errs toward "fewer positionals" rather than "wrong path."
    private static let findArglessFlags: Set<String> = [
        "-print", "-print0", "-delete", "-empty", "-readable",
        "-writable", "-executable", "-true", "-false", "-quit",
        "-depth", "-mount", "-xdev", "-L", "-H", "-P", "-d", "-s", "-x"
    ]

    private static func positionalsSkippingFindFlagArgs(_ args: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("-") {
                let isArgless = findArglessFlags.contains(token) || token.contains("=")
                i += isArgless ? 1 : 2
                continue
            }
            result.append(stripSurroundingQuotes(token))
            i += 1
        }
        return result
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    private static func absolutePath(_ arg: String, cwd: String, home: String) -> String {
        if arg.hasPrefix("/") {
            return arg
        }
        if arg.hasPrefix("~") {
            let expanded = home + String(arg.dropFirst())
            return (expanded as NSString).standardizingPath
        }
        let joined = (cwd as NSString).appendingPathComponent(arg)
        return (joined as NSString).standardizingPath
    }
}
