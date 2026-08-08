import Foundation

/// Attempts to reuse Ghostty's own post-login saved-state surfaces. A surface
/// is eligible only when its captured stable terminal identity still exists
/// and Ghostty reports the same working directory. Positional indices are not
/// safe here because inserting a window renumbers every later window.
public enum PiGhosttyExistingSurfaceScript {
    public static func make(
        sessions: [PiRestorableSession],
        piExecutable: String
    ) -> String {
        let candidates = sessions.compactMap { session -> PiRestorableSession? in
            guard let terminalID = session.layout?.terminalID,
                  !terminalID.isEmpty else { return nil }
            return session
        }.sorted { $0.sessionId < $1.sessionId }
        guard !candidates.isEmpty else { return "" }

        var lines = [
            "tell application \"Ghostty\"",
            "    set restoredOutput to \"\"",
        ]
        for session in candidates {
            guard let terminalID = session.layout?.terminalID else { continue }
            let command = "\(shellQuote(piExecutable)) --session \(shellQuote(session.sessionFile))"
            lines.append(contentsOf: [
                "    try",
                "        set targetTerminal to terminal id \"\(AppleScriptEscaper.escape(terminalID))\"",
                "        if working directory of targetTerminal is \"\(AppleScriptEscaper.escape(session.cwd))\" then",
                "            input text \"\(AppleScriptEscaper.escape(command))\" to targetTerminal",
                "            send key \"enter\" to targetTerminal",
                "            set restoredOutput to restoredOutput & \"\(AppleScriptEscaper.escape(session.sessionId))\" & linefeed",
                "        end if",
                "    end try",
            ])
        }
        lines.append("    return restoredOutput")
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    public static func restoredSessionIDs(
        from output: String,
        candidates: Set<String>
    ) -> [String] {
        Array(Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespaces)
            return candidates.contains(value) ? value : nil
        })).sorted()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
