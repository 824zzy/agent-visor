import Foundation

public enum PiGhosttyRestorationScript {
    private struct TabGroupKey: Hashable {
        let window: String
        let tab: String
    }

    public static func make(
        sessions: [PiRestorableSession],
        piExecutable: String
    ) -> String {
        guard !sessions.isEmpty else { return "" }
        let groups = Dictionary(grouping: sessions, by: groupKey)
            .values
            .map { $0.sorted(by: terminalOrder) }
            .sorted(by: groupOrder)
        var lines = ["tell application \"Ghostty\"", "    activate"]
        var configurationIndex = 0

        for (groupOffset, group) in groups.enumerated() {
            guard let first = group.first else { continue }
            configurationIndex += 1
            let firstConfiguration = "restoreCfg\(configurationIndex)"
            appendConfiguration(
                to: &lines,
                variable: firstConfiguration,
                session: first,
                piExecutable: piExecutable
            )

            // A captured tab is reconstructed as one window. Ghostty 1.3's
            // preview AppleScript API rejects `new tab` when tabs are hidden,
            // and may create a surface before returning that error. Using one
            // window per tab avoids both failed restoration and duplicates.
            let windowVariable = "restoreWindow\(groupOffset + 1)"
            lines.append("    set \(windowVariable) to new window with configuration \(firstConfiguration)")
            let firstTerminalVariable = "restoreTerminal\(groupOffset + 1)_1"
            lines.append("    set \(firstTerminalVariable) to terminal 1 of selected tab of \(windowVariable)")

            var splitTarget = firstTerminalVariable
            for (offset, session) in group.dropFirst().enumerated() {
                configurationIndex += 1
                let configuration = "restoreCfg\(configurationIndex)"
                appendConfiguration(
                    to: &lines,
                    variable: configuration,
                    session: session,
                    piExecutable: piExecutable
                )
                let terminalVariable = "restoreTerminal\(groupOffset + 1)_\(offset + 2)"
                lines.append("    set \(terminalVariable) to split \(splitTarget) direction right with configuration \(configuration)")
                splitTarget = terminalVariable
            }
        }

        lines.append("end tell")
        return lines.joined(separator: "\n")
    }

    private static func appendConfiguration(
        to lines: inout [String],
        variable: String,
        session: PiRestorableSession,
        piExecutable: String
    ) {
        let command = "\(shellQuote(piExecutable)) --session \(shellQuote(session.sessionFile))"
        lines.append("    set \(variable) to new surface configuration")
        lines.append("    set initial working directory of \(variable) to \"\(AppleScriptEscaper.escape(session.cwd))\"")
        lines.append("    set command of \(variable) to \"\(AppleScriptEscaper.escape(command))\"")
        lines.append("    set wait after command of \(variable) to true")
    }

    private static func groupKey(_ session: PiRestorableSession) -> TabGroupKey {
        if let layout = session.layout,
           let windowID = layout.windowID,
           let tabID = layout.tabID,
           !windowID.isEmpty,
           !tabID.isEmpty {
            return TabGroupKey(window: "id:\(windowID)", tab: "id:\(tabID)")
        }
        if let layout = session.layout,
           layout.windowIndex > 0,
           layout.tabIndex > 0 {
            return TabGroupKey(
                window: "legacy:\(layout.windowIndex)",
                tab: "legacy:\(layout.tabIndex)"
            )
        }
        return TabGroupKey(window: "fallback:\(session.sessionId)", tab: "session")
    }

    private static func groupOrder(_ lhs: [PiRestorableSession], _ rhs: [PiRestorableSession]) -> Bool {
        guard let left = lhs.first, let right = rhs.first else { return !lhs.isEmpty }
        let leftWindow = left.layout?.windowIndex ?? .max
        let rightWindow = right.layout?.windowIndex ?? .max
        if leftWindow != rightWindow { return leftWindow < rightWindow }
        let leftTab = left.layout?.tabIndex ?? .max
        let rightTab = right.layout?.tabIndex ?? .max
        if leftTab != rightTab { return leftTab < rightTab }
        if left.observedAt != right.observedAt { return left.observedAt < right.observedAt }
        return left.sessionId < right.sessionId
    }

    private static func terminalOrder(_ lhs: PiRestorableSession, _ rhs: PiRestorableSession) -> Bool {
        let leftTerminal = lhs.layout?.terminalIndex ?? .max
        let rightTerminal = rhs.layout?.terminalIndex ?? .max
        if leftTerminal != rightTerminal { return leftTerminal < rightTerminal }
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        return lhs.sessionId < rhs.sessionId
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
