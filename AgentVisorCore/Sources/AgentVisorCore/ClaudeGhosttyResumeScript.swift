import Foundation

/// Builds the one structured Claude resume launch accepted by the native
/// helper. The caller supplies validated fields; this type never accepts an
/// arbitrary shell command or provider environment.
public enum ClaudeGhosttyResumeScript {
    public static func make(
        target: NativeHelperGhosttyResumeTarget,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let sources = target.settingSources?.joined(separator: ",")
        var commandParts = [
            "/usr/bin/env", "-i",
            "HOME=\(GhosttyResumeScriptSupport.shellQuote(homeDirectory))",
            "PATH=/usr/bin:/bin",
            "TERM=xterm-256color",
            "AGENT_VISOR_RESUME_NONCE=\(GhosttyResumeScriptSupport.shellQuote(target.nonce))",
        ]
        if let configRoot = target.configRoot {
            commandParts.append("CLAUDE_CONFIG_DIR=\(GhosttyResumeScriptSupport.shellQuote(configRoot))")
        }
        commandParts.append(GhosttyResumeScriptSupport.shellQuote(target.executable))
        if let settingsFile = target.settingsFile {
            commandParts.append("--settings")
            commandParts.append(GhosttyResumeScriptSupport.shellQuote(settingsFile))
        }
        if let sources {
            commandParts.append("--setting-sources")
            commandParts.append(GhosttyResumeScriptSupport.shellQuote(sources))
        }
        commandParts.append("--resume")
        commandParts.append(GhosttyResumeScriptSupport.shellQuote(target.sessionId))
        let command = commandParts.joined(separator: " ")

        return GhosttyResumeScriptSupport.make(command: command, workingDirectory: target.cwd)
    }
}
