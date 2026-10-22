import Foundation

/// Builds the exact Codex CLI resume launch accepted by the native helper.
/// Only validated references cross the wire; provider command text is never
/// supplied by the caller.
public enum CodexGhosttyResumeScript {
    public static func make(
        target: NativeHelperGhosttyResumeTarget,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let configRoot = target.configRoot ?? homeDirectory
        var commandParts = [
            "/usr/bin/env", "-i",
            "HOME=\(GhosttyResumeScriptSupport.shellQuote(homeDirectory))",
            "PATH=/usr/bin:/bin",
            "TERM=xterm-256color",
            "CODEX_HOME=\(GhosttyResumeScriptSupport.shellQuote(configRoot))",
            "AGENT_VISOR_RESUME_NONCE=\(GhosttyResumeScriptSupport.shellQuote(target.nonce))",
            GhosttyResumeScriptSupport.shellQuote(target.executable),
            "resume",
            GhosttyResumeScriptSupport.shellQuote(target.sessionId),
            "--cd",
            GhosttyResumeScriptSupport.shellQuote(target.cwd),
        ]
        if target.profileState == "present", let profile = target.profileRef {
            commandParts.append("--profile")
            commandParts.append(GhosttyResumeScriptSupport.shellQuote(profile))
        }
        let command = commandParts.joined(separator: " ")
        return GhosttyResumeScriptSupport.make(command: command, workingDirectory: target.cwd)
    }
}
