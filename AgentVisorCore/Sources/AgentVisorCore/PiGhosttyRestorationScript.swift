import Foundation

public enum PiGhosttyRestorationScript {
    private struct PositionedSession {
        let session: PiRestorableSession
        let window: Int
        let tab: Int
        let terminal: Int
    }

    public static func make(
        sessions: [PiRestorableSession],
        piExecutable: String
    ) -> String {
        guard !sessions.isEmpty else { return "" }
        let positioned = position(sessions)
        let windows = Dictionary(grouping: positioned, by: \.window)
        var lines = ["tell application \"Ghostty\"", "    activate"]
        var configurationIndex = 0

        for windowIndex in windows.keys.sorted() {
            guard let windowSessions = windows[windowIndex] else { continue }
            let tabs = Dictionary(grouping: windowSessions, by: \.tab)
            var windowVariable: String?

            for tabIndex in tabs.keys.sorted() {
                guard let tabSessions = tabs[tabIndex]?.sorted(by: terminalOrder),
                      let first = tabSessions.first else { continue }
                configurationIndex += 1
                let firstConfiguration = "restoreCfg\(configurationIndex)"
                appendConfiguration(
                    to: &lines,
                    variable: firstConfiguration,
                    session: first.session,
                    piExecutable: piExecutable
                )

                let firstTerminalVariable: String
                if windowVariable == nil {
                    let variable = "restoreWindow\(windowIndex)"
                    lines.append("    set \(variable) to new window with configuration \(firstConfiguration)")
                    windowVariable = variable
                    firstTerminalVariable = "restoreTerminal\(windowIndex)_\(tabIndex)_1"
                    lines.append("    set \(firstTerminalVariable) to terminal 1 of selected tab of \(variable)")
                } else {
                    let tabVariable = "restoreTab\(windowIndex)_\(tabIndex)"
                    lines.append("    set \(tabVariable) to new tab in \(windowVariable!) with configuration \(firstConfiguration)")
                    firstTerminalVariable = "restoreTerminal\(windowIndex)_\(tabIndex)_1"
                    lines.append("    set \(firstTerminalVariable) to terminal 1 of \(tabVariable)")
                }

                var splitTarget = firstTerminalVariable
                for (offset, positionedSession) in tabSessions.dropFirst().enumerated() {
                    configurationIndex += 1
                    let configuration = "restoreCfg\(configurationIndex)"
                    appendConfiguration(
                        to: &lines,
                        variable: configuration,
                        session: positionedSession.session,
                        piExecutable: piExecutable
                    )
                    let terminalVariable = "restoreTerminal\(windowIndex)_\(tabIndex)_\(offset + 2)"
                    lines.append("    set \(terminalVariable) to split \(splitTarget) direction right with configuration \(configuration)")
                    splitTarget = terminalVariable
                }
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

    private static func position(_ sessions: [PiRestorableSession]) -> [PositionedSession] {
        let ordered = sessions.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.sessionId < $1.sessionId
        }
        let highestKnownWindow = ordered.compactMap(\.layout?.windowIndex).max() ?? 0
        let fallbackWindow = highestKnownWindow + 1
        var fallbackTab = 0

        return ordered.map { session in
            if let layout = session.layout,
               layout.windowIndex > 0,
               layout.tabIndex > 0,
               layout.terminalIndex > 0 {
                return PositionedSession(
                    session: session,
                    window: layout.windowIndex,
                    tab: layout.tabIndex,
                    terminal: layout.terminalIndex
                )
            }
            fallbackTab += 1
            return PositionedSession(
                session: session,
                window: fallbackWindow,
                tab: fallbackTab,
                terminal: 1
            )
        }
    }

    private static func terminalOrder(_ lhs: PositionedSession, _ rhs: PositionedSession) -> Bool {
        if lhs.terminal != rhs.terminal { return lhs.terminal < rhs.terminal }
        return lhs.session.sessionId < rhs.session.sessionId
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
